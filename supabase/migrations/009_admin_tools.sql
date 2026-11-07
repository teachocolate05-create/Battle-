-- =====================================================================
-- 009_admin_tools.sql : (v2 3단계) 관리자 도구
--   - 적군 퇴장(전장에서 물러남) / 퇴장한 적군 재등장
--   - 관리자는 판정 전에도 각 참가자가 제출한 행동을 확인 (다른 참가자에게는 여전히 비공개)
--   - 채팅 가리기 (관리자)
-- 실행 순서: 008 다음. 여러 번 실행해도 안전합니다.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 적군 상태에 '퇴장(withdrawn)' 추가
--   퇴장한 적군: 공격하지도 공격받지도 않음, 승리 조건에서 제외 (기존 판정은 status = 'alive' 만 대상으로 함)
-- ---------------------------------------------------------------------
alter table public.enemies drop constraint if exists enemies_status_check;
alter table public.enemies add constraint enemies_status_check check (status in ('alive', 'dead', 'withdrawn'));

create or replace function public.admin_withdraw_enemy(p_user_id uuid, p_room_id uuid, p_enemy_id uuid)
returns jsonb language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_e public.enemies;
  v_msg text;
begin
  if v_room.status = 'ended' then raise exception '이미 종료된 전투입니다.' using errcode = 'P0001'; end if;
  select * into v_e from public.enemies where id = p_enemy_id and room_id = p_room_id for update;
  if not found then raise exception '적군을 찾을 수 없습니다.' using errcode = 'P0001'; end if;
  if v_e.appearance_status <> 'appeared' or v_e.status <> 'alive' then
    raise exception '전장에 나와 있는(등장했고 살아 있는) 적군만 퇴장시킬 수 있습니다.' using errcode = 'P0001';
  end if;

  update public.enemies set status = 'withdrawn', updated_at = now() where id = v_e.id;
  -- 아직 적용되지 않은 이 적군의 공격 선언은 취소
  update public.pending_attacks set status = 'cancelled' where enemy_id = v_e.id and status = 'pending';

  v_msg := format('%s%s 전장에서 물러났다.', v_e.name, public.josa(v_e.name, '이', '가'));
  insert into public.battle_events (room_id, enemy_id, event_type, event_message, event_data)
  values (p_room_id, v_e.id, 'enemy_withdrawn', v_msg, jsonb_build_object('enemy_name', v_e.name, 'hp', v_e.current_hp));
  perform public.add_battle_log(p_room_id, 'enemy_withdrawn', v_msg, 'system', null, 'enemy', v_e.id,
    jsonb_build_object('enemy_name', v_e.name, 'hp', v_e.current_hp));
  perform public.check_and_end(p_room_id);
  return jsonb_build_object('message', v_msg);
end $$;

-- 등장: 처음 등장 + 퇴장했던 적군의 재등장
create or replace function public.admin_appear_enemy(p_user_id uuid, p_room_id uuid, p_enemy_id uuid)
returns jsonb language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_e public.enemies;
  v_order int;
  v_msg text;
  v_cycle int; v_phase int;
  v_again boolean;
begin
  if v_room.status = 'ended' then
    raise exception '전투가 종료되어 적군을 등장시킬 수 없습니다.' using errcode = 'P0001';
  end if;
  select * into v_e from public.enemies where id = p_enemy_id and room_id = p_room_id for update;
  if not found then raise exception '적군을 찾을 수 없습니다.' using errcode = 'P0001'; end if;
  v_again := v_e.appearance_status = 'appeared' and v_e.status = 'withdrawn';
  if v_e.appearance_status = 'appeared' and not v_again then
    raise exception '이미 등장한 적군입니다.' using errcode = 'P0001';
  end if;

  if v_again then
    v_order := v_e.appearance_order;
    v_msg := format('%s%s 다시 모습을 드러냈다!', v_e.name, public.josa(v_e.name, '이', '가'));
    update public.enemies set status = 'alive', updated_at = now() where id = v_e.id;
  else
    select coalesce(max(appearance_order), 0) + 1 into v_order from public.enemies where room_id = p_room_id;
    v_msg := coalesce(nullif(btrim(v_e.appearance_message), ''),
                      v_e.name || public.josa(v_e.name, '이', '가') || ' 등장했다!');
    update public.enemies
       set appearance_status = 'appeared', appearance_order = v_order, appeared_at = now(), updated_at = now()
     where id = v_e.id;
  end if;

  select ph.cycle_number, ph.phase_number into v_cycle, v_phase
    from public.battle_phases ph where ph.id = v_room.current_phase_id;

  insert into public.battle_events (room_id, enemy_id, event_type, event_message, event_data)
  values (p_room_id, v_e.id, 'enemy_appeared', v_msg,
          jsonb_build_object('enemy_name', v_e.name, 'appearance_order', v_order, 'reappeared', v_again,
                             'room_status', v_room.status, 'cycle_number', v_cycle, 'phase_number', v_phase));
  perform public.add_battle_log(p_room_id, 'enemy_appeared', v_msg, 'system', null, 'enemy', v_e.id,
    jsonb_build_object('enemy_name', v_e.name, 'appearance_order', v_order, 'max_hp', v_e.max_hp, 'reappeared', v_again));
  return jsonb_build_object('appearance_order', v_order, 'message', v_msg);
end $$;

-- 승패: 승리 = 등장 전·전장에 남은 적군이 없고(모두 사망 또는 퇴장) 1명 이상 쓰러뜨림
--        (모두 퇴장만 하고 아무도 쓰러뜨리지 않았으면 자동 종료하지 않음 → 관리자가 판단)
create or replace function public.check_battle_end(p_room_id uuid)
returns text language plpgsql stable as $$
begin
  if exists (select 1 from public.enemies where room_id = p_room_id)
     and not exists (select 1 from public.enemies where room_id = p_room_id and status = 'alive')
     and exists (select 1 from public.enemies where room_id = p_room_id and status = 'dead') then
    return 'victory';
  end if;
  if not exists (select 1 from public.alive_players(p_room_id)) then
    if exists (select 1 from public.players p join public.room_members m on m.id = p.member_id
                where p.room_id = p_room_id and m.status = 'active' and p.status = 'dead') then
      return 'defeat';
    end if;
    return 'all_escaped';
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------
-- 관리자: 판정 전 제출된 행동 열람 (008 의 빈 함수를 교체)
-- ---------------------------------------------------------------------
create or replace function public.admin_actions_json(p_phase_id uuid)
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('player_id', a.player_id, 'action_type', a.action_type,
                                               'target_id', a.target_id, 'item_id', a.item_id,
                                               'submitted_at', a.submitted_at) order by a.submitted_at), '[]'::jsonb)
    from public.actions a where a.phase_id = p_phase_id
$$;

drop policy if exists actions_select_own on public.actions;
create policy actions_select_own on public.actions
  for select to authenticated using (public.is_admin() or public.is_my_player(player_id));

-- ---------------------------------------------------------------------
-- 채팅 가리기 (관리자). 원문은 보관(관리자·기록 보관함에서 확인), 참가자에게는 "가려진 메시지"로 표시
-- ---------------------------------------------------------------------
alter table public.chat_messages add column if not exists hidden_at timestamptz;

-- 가린 메시지의 원문 (관리자만 읽을 수 있음 — 참가자는 DB 직접 조회·실시간 알림으로도 볼 수 없음)
create table if not exists public.chat_moderation (
  message_id bigint primary key references public.chat_messages(id) on delete cascade,
  room_id    uuid not null references public.rooms(id) on delete cascade,
  original   text not null,
  hidden_at  timestamptz not null default now()
);
alter table public.chat_moderation enable row level security;
drop policy if exists chat_moderation_admin on public.chat_moderation;
create policy chat_moderation_admin on public.chat_moderation for select to authenticated using (public.is_admin());
revoke all on public.chat_moderation from anon;

create or replace function public.admin_hide_chat(p_user_id uuid, p_room_id uuid, p_message_id bigint, p_hide boolean)
returns void language plpgsql as $$
declare
  v_msg public.chat_messages;
  v_orig text;
begin
  perform public.assert_admin(p_user_id);
  select * into v_msg from public.chat_messages where id = p_message_id and room_id = p_room_id for update;
  if not found then raise exception '메시지를 찾을 수 없습니다.' using errcode = 'P0001'; end if;
  if p_hide and v_msg.hidden_at is null then
    insert into public.chat_moderation (message_id, room_id, original) values (v_msg.id, p_room_id, v_msg.message)
    on conflict (message_id) do update set original = excluded.original, hidden_at = now();
    update public.chat_messages set message = '(관리자가 가린 메시지)', hidden_at = now() where id = v_msg.id;
  elsif not p_hide and v_msg.hidden_at is not null then
    select original into v_orig from public.chat_moderation where message_id = v_msg.id;
    update public.chat_messages set message = coalesce(v_orig, message), hidden_at = null where id = v_msg.id;
    delete from public.chat_moderation where message_id = v_msg.id;
  end if;
end $$;

-- 기록 조회 (006 대체): 가려진 메시지는 참가자에게 본문을 보내지 않음
create or replace function public.get_room_history(
  p_user_id uuid, p_room_id uuid, p_kind text, p_before bigint, p_limit int
) returns jsonb language plpgsql stable as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_admin boolean := exists (select 1 from public.admins where user_id = p_user_id);
  v_items jsonb;
  v_min bigint;
begin
  if not exists (select 1 from public.rooms where id = p_room_id) then
    return jsonb_build_object('error', 'not_found');
  end if;
  if not v_admin
     and not exists (select 1 from public.room_members where room_id = p_room_id and user_id = p_user_id and status = 'active') then
    return jsonb_build_object('error', 'not_member');
  end if;

  if p_kind = 'chat' then
    select coalesce(jsonb_agg(public.chat_json(x, p_user_id, v_admin) order by x.id), '[]'::jsonb), min(x.id)
      into v_items, v_min
      from (select * from public.chat_messages
             where room_id = p_room_id and (p_before is null or id < p_before)
             order by id desc limit v_limit) x;
    return jsonb_build_object('items', v_items,
      'has_more', v_min is not null and exists (select 1 from public.chat_messages where room_id = p_room_id and id < v_min));
  elsif p_kind = 'logs' then
    select coalesce(jsonb_agg(to_jsonb(x) - 'room_id' order by x.id), '[]'::jsonb), min(x.id)
      into v_items, v_min
      from (select * from public.battle_logs
             where room_id = p_room_id and (p_before is null or id < p_before)
             order by id desc limit v_limit) x;
    return jsonb_build_object('items', v_items,
      'has_more', v_min is not null and exists (select 1 from public.battle_logs where room_id = p_room_id and id < v_min));
  end if;
  raise exception '알 수 없는 기록 종류입니다.' using errcode = 'P0001';
end $$;

-- 채팅 한 줄 → 화면용 JSON (보낸 사람 ID 대신 is_mine, 가린 메시지의 원문은 관리자에게만)
create or replace function public.chat_json(c public.chat_messages, p_user_id uuid, p_admin boolean)
returns jsonb language sql stable as $$
  select jsonb_build_object('id', c.id, 'sender_role', c.sender_role, 'nickname', c.nickname,
                            'message', c.message, 'hidden', c.hidden_at is not null,
                            'original', case when p_admin and c.hidden_at is not null
                                             then (select original from public.chat_moderation where message_id = c.id) end,
                            'created_at', c.created_at, 'is_mine', c.sender_id = p_user_id)
$$;

-- 권한
revoke execute on all functions in schema public from public, anon, authenticated;
grant  execute on all functions in schema public to service_role;
grant  execute on function public.is_admin(), public.is_room_member(uuid),
                           public.can_view_room(uuid), public.is_my_player(uuid)
  to authenticated;
