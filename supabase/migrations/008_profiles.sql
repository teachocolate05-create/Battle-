-- =====================================================================
-- 008_profiles.sql : (v2 2단계) 전투 전 플레이어 프로필 + 이름 색상
--   - 참가자: 대기 중에만 본인 프로필(캐릭터 이름, 소개, 외형, 관리자 지정 추가 항목, 이름 색상) 수정
--   - 전투 시작 시 프로필 잠금 (profile_locked_at)
--   - 관리자: 종료 전까지 언제든 수정 가능
--   - 모든 수정 내역은 profile_history 에 기록
--   - 이름 색상은 어두운 배경에서 읽을 수 있는 색만 허용 (명암비 4.5:1 이상)
--   - 전투 능력치(HP·공격력·회피·도주)는 여전히 관리자만 수정
-- 실행 순서: 007 다음. 여러 번 실행해도 안전합니다.
-- =====================================================================

alter table public.players add column if not exists bio text not null default '';
alter table public.players add column if not exists appearance text not null default '';
alter table public.players add column if not exists profile_extra jsonb not null default '{}'::jsonb;
alter table public.players add column if not exists name_color text not null default '#9fc4ff';
alter table public.players add column if not exists profile_locked_at timestamptz;
alter table public.rooms   add column if not exists profile_fields jsonb not null default '[]'::jsonb;

do $$ begin
  alter table public.players add constraint players_bio_len check (char_length(bio) <= 500);
  alter table public.players add constraint players_appearance_len check (char_length(appearance) <= 500);
  alter table public.players add constraint players_name_color_hex check (name_color ~ '^#[0-9a-f]{6}$');
exception when duplicate_object then null; end $$;

create table if not exists public.profile_history (
  id         bigint generated always as identity primary key,
  room_id    uuid not null references public.rooms(id) on delete cascade,
  player_id  uuid not null references public.players(id) on delete cascade,
  changed_by text not null check (changed_by in ('player', 'admin')),
  changes    jsonb not null,            -- { 필드: { before, after } }
  created_at timestamptz not null default now()
);
create index if not exists profile_history_room_idx on public.profile_history (room_id, id);
alter table public.profile_history enable row level security;
drop policy if exists profile_history_select on public.profile_history;
create policy profile_history_select on public.profile_history
  for select to authenticated using (public.is_admin() or public.is_my_player(player_id));
revoke all on public.profile_history from anon;

-- ---------------------------------------------------------------------
-- 이름 색상: 기본 색상 목록 + 가독성 검사
-- ---------------------------------------------------------------------
create or replace function public.name_color_palette()
returns text[] language sql immutable as $$
  select array['#ff8a80', '#ffb74d', '#ffd54f', '#dce775', '#81c784', '#4dd0e1',
               '#64b5f6', '#9fa8da', '#ce93d8', '#f48fb1', '#bcaaa4', '#e0e0e0']
$$;

-- WCAG 상대 휘도
create or replace function public.hex_luminance(p_hex text)
returns numeric language plpgsql immutable as $$
declare
  c numeric[];
  v numeric;
  i int;
  res numeric := 0;
  w numeric[] := array[0.2126, 0.7152, 0.0722];
begin
  for i in 0..2 loop
    v := ('x' || substr(p_hex, 2 + i * 2, 2))::bit(8)::int / 255.0;
    v := case when v <= 0.03928 then v / 12.92 else power((v + 0.055) / 1.055, 2.4) end;
    res := res + w[i + 1] * v;
  end loop;
  return res;
end $$;

-- 화면의 카드 배경(#222838)과의 명암비가 4.5:1 이상이면 읽을 수 있는 색으로 판단
create or replace function public.name_color_readable(p_hex text)
returns boolean language sql immutable as $$
  select p_hex ~ '^#[0-9a-f]{6}$'
     and (public.hex_luminance(p_hex) + 0.05) / (public.hex_luminance('#222838') + 0.05) >= 4.5
$$;

-- 입장 시 색상 자동 배정 (방 안에서 겹치지 않게 순서대로)
create or replace function public.assign_name_color()
returns trigger language plpgsql as $$
declare
  pal text[] := public.name_color_palette();
  n int;
begin
  if new.name_color is null or new.name_color = '#9fc4ff' then
    select count(*) into n from public.players where room_id = new.room_id;
    new.name_color := pal[1 + (n % array_length(pal, 1))];
  end if;
  return new;
end $$;
drop trigger if exists players_assign_color on public.players;
create trigger players_assign_color before insert on public.players
  for each row execute function public.assign_name_color();

-- ---------------------------------------------------------------------
-- 프로필 검증 + 적용 (참가자/관리자 공통) — 바뀐 항목만 기록
-- ---------------------------------------------------------------------
create or replace function public.apply_profile(p_room public.rooms, p_player public.players, p_data jsonb, p_by text)
returns jsonb language plpgsql as $$
declare
  v_name text := public.jtext(p_data, 'display_name', '캐릭터 이름', 1, 20, p_player.display_name);
  v_bio text := public.jtext(p_data, 'bio', '캐릭터 소개', 0, 500, p_player.bio);
  v_look text := public.jtext(p_data, 'appearance', '외형 설명', 0, 500, p_player.appearance);
  v_color text := lower(coalesce(nullif(btrim(p_data ->> 'name_color'), ''), p_player.name_color));
  v_extra jsonb := p_player.profile_extra;
  v_in jsonb := p_data -> 'profile_extra';
  f jsonb;
  v_val text;
  v_changes jsonb := '{}'::jsonb;
begin
  if v_name ~ '[<>]' then raise exception '이름에 < > 문자는 사용할 수 없습니다.' using errcode = 'P0001'; end if;
  if not public.name_color_readable(v_color) then
    raise exception '어두운 배경에서 잘 보이지 않는 색입니다. 더 밝은 색을 고르세요.' using errcode = 'P0001';
  end if;
  if lower(v_name) <> lower(p_player.display_name) and exists (
       select 1 from public.players p join public.room_members m on m.id = p.member_id
        where p.room_id = p_room.id and m.status = 'active' and p.id <> p_player.id
          and lower(p.display_name) = lower(v_name)) then
    raise exception '같은 방에 이미 같은 이름의 캐릭터가 있습니다.' using errcode = 'P0001';
  end if;

  -- 추가 항목: 관리자가 정한 항목만 저장 (그 외 키는 무시)
  if v_in is not null and jsonb_typeof(v_in) = 'object' then
    for f in select * from jsonb_array_elements(p_room.profile_fields) loop
      if v_in ? (f ->> 'key') then
        v_val := btrim(coalesce(v_in ->> (f ->> 'key'), ''));
        if char_length(v_val) > 200 then
          raise exception '%은(는) 200자 이하로 입력하세요.', f ->> 'label' using errcode = 'P0001';
        end if;
        v_extra := jsonb_set(v_extra, array[f ->> 'key'], to_jsonb(v_val));
      end if;
    end loop;
  end if;

  if v_name <> p_player.display_name then v_changes := v_changes || jsonb_build_object('display_name', jsonb_build_object('before', p_player.display_name, 'after', v_name)); end if;
  if v_bio <> p_player.bio then v_changes := v_changes || jsonb_build_object('bio', jsonb_build_object('before', p_player.bio, 'after', v_bio)); end if;
  if v_look <> p_player.appearance then v_changes := v_changes || jsonb_build_object('appearance', jsonb_build_object('before', p_player.appearance, 'after', v_look)); end if;
  if v_color <> p_player.name_color then v_changes := v_changes || jsonb_build_object('name_color', jsonb_build_object('before', p_player.name_color, 'after', v_color)); end if;
  if v_extra <> p_player.profile_extra then v_changes := v_changes || jsonb_build_object('profile_extra', jsonb_build_object('before', p_player.profile_extra, 'after', v_extra)); end if;

  if v_changes = '{}'::jsonb then return v_changes; end if;

  update public.players
     set display_name = v_name, bio = v_bio, appearance = v_look, name_color = v_color,
         profile_extra = v_extra, updated_at = now()
   where id = p_player.id;
  insert into public.profile_history (room_id, player_id, changed_by, changes)
  values (p_room.id, p_player.id, p_by, v_changes);
  return v_changes;
end $$;

-- 참가자: 본인 프로필 수정 (대기 중, 잠기기 전만)
create or replace function public.update_my_profile(p_user_id uuid, p_room_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare
  v_room public.rooms;
  v_player public.players;
begin
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found then raise exception '전투방을 찾을 수 없습니다.' using errcode = 'P0001'; end if;
  select p.* into v_player from public.players p join public.room_members m on m.id = p.member_id
   where p.room_id = p_room_id and m.user_id = p_user_id and m.status = 'active'
   for update of p;
  if not found then raise exception '이 전투방의 참가자가 아닙니다.' using errcode = 'P0001'; end if;
  if v_room.status <> 'waiting' or v_player.profile_locked_at is not null then
    raise exception '전투가 시작되어 프로필이 확정되었습니다. 수정이 필요하면 관리자에게 요청하세요.' using errcode = 'P0001';
  end if;
  -- 능력치 키가 섞여 와도 apply_profile 은 프로필 항목만 읽으므로 무시됨
  return public.apply_profile(v_room, v_player, p_data, 'player');
end $$;

-- 관리자: 참가자 프로필 수정 (종료 전까지)
create or replace function public.admin_update_profile(p_user_id uuid, p_room_id uuid, p_player_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_player public.players;
begin
  if v_room.status = 'ended' then
    raise exception '종료된 전투의 프로필은 수정할 수 없습니다.' using errcode = 'P0001';
  end if;
  select * into v_player from public.players where id = p_player_id and room_id = p_room_id for update;
  if not found then raise exception '플레이어를 찾을 수 없습니다.' using errcode = 'P0001'; end if;
  return public.apply_profile(v_room, v_player, p_data, 'admin');
end $$;

-- 관리자: 추가 프로필 항목 정의 (최대 5개). p_labels: ["나이", "직업"] 또는 [{key, label}]
--  기존 항목은 key 를 유지해서 이미 입력된 값이 사라지지 않게 함
create or replace function public.admin_set_profile_fields(p_user_id uuid, p_room_id uuid, p_fields jsonb)
returns jsonb language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  f jsonb;
  v_label text;
  v_key text;
  v_out jsonb := '[]'::jsonb;
begin
  if v_room.status = 'ended' then raise exception '종료된 전투방입니다.' using errcode = 'P0001'; end if;
  if p_fields is null or jsonb_typeof(p_fields) <> 'array' then
    raise exception '잘못된 형식입니다.' using errcode = 'P0001';
  end if;
  if jsonb_array_length(p_fields) > 5 then
    raise exception '추가 항목은 최대 5개까지 만들 수 있습니다.' using errcode = 'P0001';
  end if;
  for f in select * from jsonb_array_elements(p_fields) loop
    v_label := btrim(coalesce(case jsonb_typeof(f) when 'string' then f #>> '{}' else f ->> 'label' end, ''));
    v_key := case when jsonb_typeof(f) = 'object' then nullif(f ->> 'key', '') end;
    if char_length(v_label) < 1 or char_length(v_label) > 20 then
      raise exception '항목 이름은 1~20자로 입력하세요.' using errcode = 'P0001';
    end if;
    if v_key is null or v_key !~ '^f[0-9a-f]{6}$' then
      v_key := 'f' || substr(md5(random()::text || clock_timestamp()::text), 1, 6);
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('key', v_key, 'label', v_label));
  end loop;
  update public.rooms set profile_fields = v_out, updated_at = now() where id = p_room_id;
  return v_out;
end $$;

-- ---------------------------------------------------------------------
-- 전투 시작 시 프로필 확정(잠금) — 004 의 전투 시작 함수에 잠금만 추가
-- ---------------------------------------------------------------------
create or replace function public.admin_start_battle(p_user_id uuid, p_room_id uuid)
returns void language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_names text;
begin
  if v_room.status <> 'waiting' then
    raise exception '이미 시작되었거나 종료된 전투입니다.' using errcode = 'P0001';
  end if;
  if v_room.first_side is null then
    raise exception '선공 측을 먼저 설정하세요.' using errcode = 'P0001';
  end if;
  select string_agg(display_name, ', ' order by display_name) into v_names from public.alive_players(p_room_id);
  if v_names is null then
    raise exception '전투에 참가할 (생존한) 플레이어가 없습니다.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.enemies where room_id = p_room_id) then
    raise exception '적군을 1명 이상 등록하세요. (등장은 전투 중에 시켜도 됩니다)' using errcode = 'P0001';
  end if;

  update public.players set profile_locked_at = now() where room_id = p_room_id;
  update public.rooms set status = 'in_progress', battle_started_at = now(), updated_at = now() where id = p_room_id;
  insert into public.battle_events (room_id, event_type, event_message, event_data)
  values (p_room_id, 'battle_started',
          format('⚔ 전투 시작! (%s 선공)', case v_room.first_side when 'players' then '플레이어 측' else '적군 측' end),
          jsonb_build_object('first_side', v_room.first_side, 'players', v_names, 'turn_duration', v_room.turn_duration));
  perform public.add_battle_log(p_room_id, 'battle_started',
    format('전투 시작 — 선공: %s / 참가자: %s', case v_room.first_side when 'players' then '플레이어 측' else '적군 측' end, v_names),
    'system', null, null, null, jsonb_build_object('first_side', v_room.first_side));

  perform public.open_phase(p_room_id, 1, 1);
  perform public.progress_room(p_room_id, null);
end $$;

-- ---------------------------------------------------------------------
-- 방 상태 조회 (005 대체). 이후 단계에서 바뀔 부분은 작은 함수로 분리
-- ---------------------------------------------------------------------
create or replace function public.player_json(p public.players, p_full boolean)
returns jsonb language sql stable as $$
  select jsonb_build_object('id', p.id, 'member_id', p.member_id, 'display_name', p.display_name,
                            'max_hp', p.max_hp, 'current_hp', p.current_hp, 'status', p.status,
                            'name_color', p.name_color, 'bio', p.bio, 'appearance', p.appearance,
                            'profile_extra', p.profile_extra, 'profile_locked_at', p.profile_locked_at)
      || case when p_full then jsonb_build_object('min_attack', p.min_attack, 'max_attack', p.max_attack,
                                                  'dodge_rate', p.dodge_rate, 'escape_rate', p.escape_rate)
              else '{}'::jsonb end
$$;

-- 판정 전 행동: 관리자에게 보여줄 목록 (008 에서는 비공개 — 009 에서 관리자 열람 허용으로 교체)
create or replace function public.admin_actions_json(p_phase_id uuid)
returns jsonb language sql stable as $$ select '[]'::jsonb $$;

create or replace function public.get_room_state(p_user_id uuid, p_room_id uuid)
returns jsonb language sql stable as $$
with
  adm   as (select exists (select 1 from public.admins where user_id = p_user_id) as is_admin),
  rm    as (select * from public.rooms where id = p_room_id),
  mine  as (select * from public.room_members where room_id = p_room_id and user_id = p_user_id),
  myp   as (select p.* from public.players p join mine m on m.id = p.member_id),
  vis_m as (select m.* from public.room_members m, adm
             where m.room_id = p_room_id and (adm.is_admin or m.status = 'active')),
  ph    as (select ph.* from public.battle_phases ph join rm on ph.id = rm.current_phase_id)
select case
  when not exists (select 1 from rm) then jsonb_build_object('error', 'not_found')
  when not (select is_admin from adm) and not exists (select 1 from mine) then jsonb_build_object('error', 'not_member')
  when not (select is_admin from adm) and (select status from mine) = 'kicked' then jsonb_build_object('error', 'kicked')
  when not (select is_admin from adm) and (select status from mine) = 'left' then jsonb_build_object('error', 'left')
  else jsonb_build_object(
    'viewer', case when (select is_admin from adm) then 'admin' else 'guest' end,
    'serverNow', now(),
    'room', (select to_jsonb(r) - 'created_by' - 'updated_at' from rm r),
    'members', coalesce((select jsonb_agg(to_jsonb(m) - 'user_id' order by m.joined_at) from vis_m m), '[]'::jsonb),
    'players', coalesce((
      select jsonb_agg(public.player_json(p, (select is_admin from adm) or p.id = (select id from myp)) order by m.joined_at)
        from public.players p join vis_m m on m.id = p.member_id), '[]'::jsonb),
    'me', (select jsonb_build_object('member', to_jsonb(m) - 'user_id',
                                     'player', (select public.player_json(p, true) from myp p))
             from mine m where m.status = 'active'),
    'enemies', coalesce((
      select jsonb_agg(
        case when (select is_admin from adm) then to_jsonb(e) - 'room_id' - 'updated_at'
             else (to_jsonb(e) - 'room_id' - 'updated_at')
                  || jsonb_build_object('target_player_id', null, 'appearance_message', '') end
        order by e.created_at)
      from public.enemies e
      where e.room_id = p_room_id and ((select is_admin from adm) or e.appearance_status = 'appeared')), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'description', i.description,
                                                           'item_type', i.item_type, 'effect_value', i.effect_value)
                                        order by i.created_at)
                         from public.items i where i.room_id = p_room_id), '[]'::jsonb),
    'inventory', coalesce((select jsonb_agg(jsonb_build_object('player_id', v.player_id, 'item_id', v.item_id, 'quantity', v.quantity))
                             from public.player_inventory v
                            where v.room_id = p_room_id and v.quantity > 0
                              and ((select is_admin from adm) or v.player_id = (select id from myp))), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from (
                select id, enemy_id, event_type, event_message, event_data, created_at
                  from public.battle_events where room_id = p_room_id order by id desc limit 200) x), '[]'::jsonb),
    'phase', (select to_jsonb(ph) - 'room_id' from ph),
    'submissions', coalesce((select jsonb_agg(s.player_id) from public.phase_submissions s join ph on s.phase_id = ph.id), '[]'::jsonb),
    'myAction', (select jsonb_build_object('action_type', a.action_type, 'target_id', a.target_id, 'item_id', a.item_id,
                                           'submitted_at', a.submitted_at, 'status', a.status)
                   from public.actions a join ph on a.phase_id = ph.id
                  where not (select is_admin from adm) and a.player_id = (select id from myp)),
    'adminActions', case when (select is_admin from adm) then public.admin_actions_json((select id from ph)) else '[]'::jsonb end,
    'pendingAttacks', coalesce((select jsonb_agg(jsonb_build_object('id', pa.id, 'enemy_id', pa.enemy_id,
                                     'target_player_id', pa.target_player_id, 'attack_power', pa.attack_power) order by pa.created_at)
                                  from public.pending_attacks pa join ph on pa.declared_phase_id = ph.response_to_phase_id
                                 where ph.acting_side = 'players' and ph.phase_type = 'reaction' and pa.status = 'pending'), '[]'::jsonb),
    'logs', coalesce((select jsonb_agg(to_jsonb(x) - 'room_id' order by x.id) from (
                select * from public.battle_logs where room_id = p_room_id order by id desc limit 400) x), '[]'::jsonb),
    'profileHistory', case when (select is_admin from adm) then coalesce((
                select jsonb_agg(to_jsonb(h) - 'room_id' order by h.id) from (
                  select * from public.profile_history where room_id = p_room_id order by id desc limit 200) h), '[]'::jsonb)
              else '[]'::jsonb end
  )
end
$$;

-- 권한
revoke execute on all functions in schema public from public, anon, authenticated;
grant  execute on all functions in schema public to service_role;
grant  execute on function public.is_admin(), public.is_room_member(uuid),
                           public.can_view_room(uuid), public.is_my_player(uuid)
  to authenticated;
