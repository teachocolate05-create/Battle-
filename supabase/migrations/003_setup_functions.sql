-- =====================================================================
-- 003_setup_functions.sql : 3단계 전투 설정
--   플레이어 능력치 / HP 조정, 적군 등록·수정·삭제·등장, 아이템 생성·지급, 선공 설정
-- 실행 순서: 002 다음. 여러 번 실행해도 안전합니다 (create or replace).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 공통 도우미
-- ---------------------------------------------------------------------

-- 관리자 확인 + 방 행 잠금 (동시에 두 요청이 와도 순서대로 처리)
create or replace function public.lock_room_for_admin(p_user_id uuid, p_room_id uuid)
returns public.rooms language plpgsql as $$
declare
  v_room public.rooms;
begin
  perform public.assert_admin(p_user_id);
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found then
    raise exception '전투방을 찾을 수 없습니다.' using errcode = 'P0001';
  end if;
  return v_room;
end $$;

-- jsonb 에서 정수 꺼내기 (없으면 기본값, 범위 밖/숫자 아님이면 한국어 오류)
create or replace function public.jint(p jsonb, k text, label text, lo int, hi int, dflt int)
returns int language plpgsql immutable as $$
declare
  v_text text := p ->> k;
  v int;
begin
  if v_text is null or btrim(v_text) = '' then
    if dflt is null then
      raise exception '%을(를) 입력하세요.', label using errcode = 'P0001';
    end if;
    return dflt;
  end if;
  begin
    v := v_text::numeric::int;
    if v::numeric <> v_text::numeric then raise exception 'not int'; end if;
  exception when others then
    raise exception '%은(는) 정수로 입력하세요.', label using errcode = 'P0001';
  end;
  if v < lo or v > hi then
    raise exception '%은(는) % ~ % 사이로 입력하세요.', label, lo, hi using errcode = 'P0001';
  end if;
  return v;
end $$;

-- jsonb 에서 문자열 꺼내기 (앞뒤 공백 제거, 길이 검사)
create or replace function public.jtext(p jsonb, k text, label text, min_len int, max_len int, dflt text)
returns text language plpgsql immutable as $$
declare
  v text := btrim(coalesce(p ->> k, dflt, ''));
begin
  if char_length(v) < min_len or char_length(v) > max_len then
    if min_len > 0 then
      raise exception '%은(는) %~%자로 입력하세요.', label, min_len, max_len using errcode = 'P0001';
    end if;
    raise exception '%은(는) %자 이하로 입력하세요.', label, max_len using errcode = 'P0001';
  end if;
  return v;
end $$;

-- 한국어 조사: 받침 있으면 첫 번째, 없으면 두 번째 (예: 허수아비가 / 거인이)
create or replace function public.josa(p_word text, p_with text, p_without text)
returns text language plpgsql immutable as $$
declare
  c int;
begin
  if p_word is null or p_word = '' then return p_with || '(' || p_without || ')'; end if;
  c := ascii(right(p_word, 1));
  if c between 44032 and 55203 then
    return case when (c - 44032) % 28 = 0 then p_without else p_with end;
  end if;
  return p_with || '(' || p_without || ')';
end $$;

-- 전투 로그 한 줄 기록 (현재 사이클/단계 정보 자동 첨부)
create or replace function public.add_battle_log(
  p_room_id uuid, p_log_type text, p_content text,
  p_actor_type text default 'system', p_actor_id uuid default null,
  p_target_type text default null, p_target_id uuid default null,
  p_data jsonb default '{}'::jsonb
) returns void language plpgsql as $$
declare
  v_phase public.battle_phases;
begin
  select ph.* into v_phase
    from public.rooms r join public.battle_phases ph on ph.id = r.current_phase_id
   where r.id = p_room_id;
  insert into public.battle_logs (room_id, cycle_id, phase_id, cycle_number, phase_number,
                                  actor_type, actor_id, target_type, target_id, log_type, content, data)
  values (p_room_id, v_phase.cycle_id, v_phase.id, v_phase.cycle_number, v_phase.phase_number,
          p_actor_type, p_actor_id, p_target_type, p_target_id, p_log_type, p_content, coalesce(p_data, '{}'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 플레이어 HP 직접 조정 (관리자). 대기 중·전투 중 모두 가능, 로그 기록.
--  HP 0 → 사망 / 사망자 HP > 0 → 부활 / 도주한 플레이어는 상태 유지
-- ---------------------------------------------------------------------
create or replace function public.apply_admin_hp(p_room public.rooms, p_player public.players, p_hp int, p_reason text)
returns void language plpgsql as $$
declare
  v_new_status text := p_player.status;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if p_hp = p_player.current_hp then return; end if;
  if p_player.status <> 'escaped' then
    v_new_status := case when p_hp = 0 then 'dead' else 'alive' end;
  end if;
  update public.players set current_hp = p_hp, status = v_new_status, updated_at = now() where id = p_player.id;
  perform public.add_battle_log(
    p_room.id, 'admin_hp',
    format('관리자가 %s의 HP를 %s → %s(으)로 조정했다.%s', p_player.display_name, p_player.current_hp, p_hp,
           coalesce(' (사유: ' || v_reason || ')', '')),
    'admin', null, 'player', p_player.id,
    jsonb_build_object('hp_before', p_player.current_hp, 'hp_after', p_hp, 'max_hp', p_player.max_hp,
                       'status_before', p_player.status, 'status_after', v_new_status, 'reason', v_reason));
  if v_new_status = 'dead' and p_player.status = 'alive' then
    perform public.add_battle_log(p_room.id, 'player_dead', format('%s%s 쓰러졌다.', p_player.display_name,
      public.josa(p_player.display_name, '이', '가')), 'system', null, 'player', p_player.id);
  elsif v_new_status = 'alive' and p_player.status = 'dead' then
    perform public.add_battle_log(p_room.id, 'player_revived', format('%s%s 다시 일어섰다.', p_player.display_name,
      public.josa(p_player.display_name, '이', '가')), 'system', null, 'player', p_player.id);
  end if;
end $$;

create or replace function public.admin_set_player_hp(
  p_user_id uuid, p_room_id uuid, p_player_id uuid, p_hp int, p_reason text
) returns void language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_player public.players;
begin
  if v_room.status = 'ended' then
    raise exception '종료된 전투에서는 HP를 조정할 수 없습니다.' using errcode = 'P0001';
  end if;
  select * into v_player from public.players where id = p_player_id and room_id = p_room_id for update;
  if not found then raise exception '플레이어를 찾을 수 없습니다.' using errcode = 'P0001'; end if;
  if p_hp is null or p_hp < 0 or p_hp > v_player.max_hp then
    raise exception 'HP는 0 ~ %(최대 HP) 사이로 입력하세요.', v_player.max_hp using errcode = 'P0001';
  end if;
  perform public.apply_admin_hp(v_room, v_player, p_hp, p_reason);
end $$;

-- ---------------------------------------------------------------------
-- 플레이어 능력치 수정 (관리자)
--  대기 중: 모든 항목 / 전투 중: 현재 HP만 (나머지 세부 수정은 2차 업데이트)
-- ---------------------------------------------------------------------
create or replace function public.admin_update_player(
  p_user_id uuid, p_room_id uuid, p_player_id uuid, p_data jsonb
) returns void language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_p public.players;
  v_name text; v_max int; v_cur int; v_min_atk int; v_max_atk int; v_dodge int; v_escape int;
begin
  if v_room.status = 'ended' then
    raise exception '종료된 전투의 능력치는 수정할 수 없습니다.' using errcode = 'P0001';
  end if;
  select * into v_p from public.players where id = p_player_id and room_id = p_room_id for update;
  if not found then raise exception '플레이어를 찾을 수 없습니다.' using errcode = 'P0001'; end if;

  v_name    := public.jtext(p_data, 'display_name', '플레이어 이름', 1, 20, v_p.display_name);
  v_max     := public.jint(p_data, 'max_hp', '최대 HP', 1, 99999, v_p.max_hp);
  v_cur     := public.jint(p_data, 'current_hp', '현재 HP', 0, 99999, least(v_p.current_hp, v_max));
  v_min_atk := public.jint(p_data, 'min_attack', '최소 공격력', 0, 9999, v_p.min_attack);
  v_max_atk := public.jint(p_data, 'max_attack', '최대 공격력', 0, 9999, v_p.max_attack);
  v_dodge   := public.jint(p_data, 'dodge_rate', '회피 성공률', 0, 100, v_p.dodge_rate);
  v_escape  := public.jint(p_data, 'escape_rate', '도주 성공률', 0, 100, v_p.escape_rate);

  if v_name ~ '[<>]' then raise exception '이름에 < > 문자는 사용할 수 없습니다.' using errcode = 'P0001'; end if;
  if v_min_atk > v_max_atk then raise exception '최소 공격력이 최대 공격력보다 클 수 없습니다.' using errcode = 'P0001'; end if;
  if v_cur > v_max then raise exception '현재 HP가 최대 HP보다 클 수 없습니다.' using errcode = 'P0001'; end if;

  if v_room.status = 'in_progress' and (v_name, v_max, v_min_atk, v_max_atk, v_dodge, v_escape)
       is distinct from (v_p.display_name, v_p.max_hp, v_p.min_attack, v_p.max_attack, v_p.dodge_rate, v_p.escape_rate) then
    raise exception '전투 중에는 현재 HP만 조정할 수 있습니다.' using errcode = 'P0001';
  end if;

  -- 능력치 먼저 (HP는 apply_admin_hp 에서 로그와 함께 처리)
  update public.players
     set display_name = v_name, max_hp = v_max, current_hp = least(current_hp, v_max),
         min_attack = v_min_atk, max_attack = v_max_atk, dodge_rate = v_dodge, escape_rate = v_escape,
         updated_at = now()
   where id = v_p.id
   returning * into v_p;
  perform public.apply_admin_hp(v_room, v_p, v_cur, null);
end $$;

-- ---------------------------------------------------------------------
-- 적군 등록 / 수정 (관리자). p_enemy_id 가 null 이면 새로 등록.
-- ---------------------------------------------------------------------
create or replace function public.admin_save_enemy(
  p_user_id uuid, p_room_id uuid, p_enemy_id uuid, p_data jsonb
) returns uuid language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_e public.enemies;
  v_name text; v_desc text; v_msg text; v_target_type text; v_target uuid;
  v_max int; v_cur int; v_min_atk int; v_max_atk int; v_dodge int; v_def int;
  v_id uuid;
begin
  if v_room.status = 'ended' then
    raise exception '종료된 전투의 적군은 수정할 수 없습니다.' using errcode = 'P0001';
  end if;

  if p_enemy_id is null then
    if (select count(*) from public.enemies where room_id = p_room_id) >= 5 then
      raise exception '적군은 전투방당 최대 5명까지 등록할 수 있습니다.' using errcode = 'P0001';
    end if;
  else
    select * into v_e from public.enemies where id = p_enemy_id and room_id = p_room_id for update;
    if not found then raise exception '적군을 찾을 수 없습니다.' using errcode = 'P0001'; end if;
    if v_e.status = 'dead' then raise exception '사망한 적군은 수정할 수 없습니다.' using errcode = 'P0001'; end if;
  end if;

  v_name    := public.jtext(p_data, 'name', '적군 이름', 1, 30, v_e.name);
  v_desc    := public.jtext(p_data, 'description', '적군 설명', 0, 500, v_e.description);
  v_msg     := public.jtext(p_data, 'appearance_message', '등장 문구', 0, 300, v_e.appearance_message);
  v_max     := public.jint(p_data, 'max_hp', '최대 HP', 1, 99999, coalesce(v_e.max_hp, 100));
  v_cur     := public.jint(p_data, 'current_hp', '현재 HP', 0, 99999, coalesce(least(v_e.current_hp, v_max), v_max));
  v_min_atk := public.jint(p_data, 'min_attack', '최소 공격력', 0, 9999, coalesce(v_e.min_attack, 1));
  v_max_atk := public.jint(p_data, 'max_attack', '최대 공격력', 0, 9999, coalesce(v_e.max_attack, 4));
  v_dodge   := public.jint(p_data, 'dodge_rate', '회피율', 0, 100, coalesce(v_e.dodge_rate, 0));
  v_def     := public.jint(p_data, 'defense', '방어력', 0, 9999, coalesce(v_e.defense, 0));
  v_target_type := coalesce(nullif(p_data ->> 'target_type', ''), v_e.target_type, 'random');

  if v_name ~ '[<>]' then raise exception '이름에 < > 문자는 사용할 수 없습니다.' using errcode = 'P0001'; end if;
  if v_min_atk > v_max_atk then raise exception '최소 공격력이 최대 공격력보다 클 수 없습니다.' using errcode = 'P0001'; end if;
  if v_cur > v_max then raise exception '현재 HP가 최대 HP보다 클 수 없습니다.' using errcode = 'P0001'; end if;
  if v_target_type not in ('all', 'random', 'specific') then
    raise exception '공격 대상 방식이 올바르지 않습니다.' using errcode = 'P0001';
  end if;
  if v_target_type = 'specific' then
    begin
      v_target := nullif(p_data ->> 'target_player_id', '')::uuid;
    exception when others then v_target := null;
    end;
    if v_target is null or not exists (select 1 from public.players where id = v_target and room_id = p_room_id) then
      raise exception '공격할 특정 플레이어를 선택하세요.' using errcode = 'P0001';
    end if;
  end if;
  if v_e.id is not null and v_e.appearance_status = 'appeared' and v_cur = 0 then
    raise exception '등장한 적군의 HP를 0으로 만들 수 없습니다. (전투 판정으로 처치하세요)' using errcode = 'P0001';
  end if;
  if v_cur = 0 then raise exception '현재 HP는 1 이상이어야 합니다.' using errcode = 'P0001'; end if;

  if v_e.id is null then
    insert into public.enemies (room_id, name, description, max_hp, current_hp, min_attack, max_attack,
                                dodge_rate, defense, target_type, target_player_id, appearance_message)
    values (p_room_id, v_name, v_desc, v_max, v_cur, v_min_atk, v_max_atk, v_dodge, v_def,
            v_target_type, v_target, v_msg)
    returning id into v_id;
  else
    update public.enemies
       set name = v_name, description = v_desc, max_hp = v_max, current_hp = v_cur,
           min_attack = v_min_atk, max_attack = v_max_atk, dodge_rate = v_dodge, defense = v_def,
           target_type = v_target_type, target_player_id = v_target, appearance_message = v_msg,
           updated_at = now()
     where id = v_e.id;
    v_id := v_e.id;
    if v_e.appearance_status = 'appeared' and v_cur <> v_e.current_hp then
      perform public.add_battle_log(p_room_id, 'admin_enemy_hp',
        format('관리자가 %s의 HP를 %s → %s(으)로 조정했다.', v_name, v_e.current_hp, v_cur),
        'admin', null, 'enemy', v_id,
        jsonb_build_object('hp_before', v_e.current_hp, 'hp_after', v_cur, 'max_hp', v_max));
    end if;
  end if;
  return v_id;
end $$;

-- 적군 삭제: 아직 등장하지 않은 적군만
create or replace function public.admin_delete_enemy(p_user_id uuid, p_room_id uuid, p_enemy_id uuid)
returns void language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_e public.enemies;
begin
  if v_room.status = 'ended' then
    raise exception '종료된 전투의 적군은 삭제할 수 없습니다.' using errcode = 'P0001';
  end if;
  select * into v_e from public.enemies where id = p_enemy_id and room_id = p_room_id for update;
  if not found then raise exception '적군을 찾을 수 없습니다.' using errcode = 'P0001'; end if;
  if v_e.appearance_status <> 'registered' then
    raise exception '이미 등장한 적군은 삭제할 수 없습니다.' using errcode = 'P0001';
  end if;
  delete from public.enemies where id = p_enemy_id;
end $$;

-- ---------------------------------------------------------------------
-- 적군 등장 실행 (관리자가 원하는 시점에)
--  - 대기 중(스토리 진행 중)에도, 전투 중에도 가능 / 종료 후 불가
--  - 중복 등장 방지, 등장 순서·시각 기록
--  - battle_events(시스템 이벤트) + battle_logs(전투 로그) 에 각각 기록
-- ---------------------------------------------------------------------
create or replace function public.admin_appear_enemy(p_user_id uuid, p_room_id uuid, p_enemy_id uuid)
returns jsonb language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_e public.enemies;
  v_order int;
  v_msg text;
  v_cycle int; v_phase int;
begin
  if v_room.status = 'ended' then
    raise exception '전투가 종료되어 적군을 등장시킬 수 없습니다.' using errcode = 'P0001';
  end if;
  select * into v_e from public.enemies where id = p_enemy_id and room_id = p_room_id for update;
  if not found then raise exception '적군을 찾을 수 없습니다.' using errcode = 'P0001'; end if;
  if v_e.appearance_status = 'appeared' then
    raise exception '이미 등장한 적군입니다.' using errcode = 'P0001';
  end if;

  select coalesce(max(appearance_order), 0) + 1 into v_order from public.enemies where room_id = p_room_id;
  v_msg := coalesce(nullif(btrim(v_e.appearance_message), ''),
                    v_e.name || public.josa(v_e.name, '이', '가') || ' 등장했다!');

  update public.enemies
     set appearance_status = 'appeared', appearance_order = v_order, appeared_at = now(), updated_at = now()
   where id = v_e.id;

  select ph.cycle_number, ph.phase_number into v_cycle, v_phase
    from public.battle_phases ph where ph.id = v_room.current_phase_id;

  insert into public.battle_events (room_id, enemy_id, event_type, event_message, event_data)
  values (p_room_id, v_e.id, 'enemy_appeared', v_msg,
          jsonb_build_object('enemy_name', v_e.name, 'appearance_order', v_order,
                             'room_status', v_room.status, 'cycle_number', v_cycle, 'phase_number', v_phase));

  perform public.add_battle_log(p_room_id, 'enemy_appeared', v_msg, 'system', null, 'enemy', v_e.id,
    jsonb_build_object('enemy_name', v_e.name, 'appearance_order', v_order, 'max_hp', v_e.max_hp));

  return jsonb_build_object('appearance_order', v_order, 'message', v_msg);
end $$;

-- ---------------------------------------------------------------------
-- 아이템 생성 / 삭제 / 지급 (관리자)
-- ---------------------------------------------------------------------
create or replace function public.admin_create_item(p_user_id uuid, p_room_id uuid, p_data jsonb)
returns uuid language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_type text := p_data ->> 'item_type';
  v_name text; v_desc text; v_value int; v_id uuid;
begin
  if v_room.status = 'ended' then
    raise exception '종료된 전투에는 아이템을 만들 수 없습니다.' using errcode = 'P0001';
  end if;
  if v_type is null or v_type not in ('heal', 'damage') then
    raise exception '아이템 종류는 HP 회복 또는 적군 고정 피해만 가능합니다.' using errcode = 'P0001';
  end if;
  if (select count(*) from public.items where room_id = p_room_id) >= 30 then
    raise exception '아이템은 전투방당 최대 30종까지 만들 수 있습니다.' using errcode = 'P0001';
  end if;
  v_name  := public.jtext(p_data, 'name', '아이템 이름', 1, 30, null);
  v_desc  := public.jtext(p_data, 'description', '아이템 설명', 0, 300, '');
  v_value := public.jint(p_data, 'effect_value', case when v_type = 'heal' then '회복량' else '피해량' end, 1, 99999, null);
  if v_name ~ '[<>]' then raise exception '이름에 < > 문자는 사용할 수 없습니다.' using errcode = 'P0001'; end if;
  insert into public.items (room_id, name, description, item_type, effect_value)
  values (p_room_id, v_name, v_desc, v_type, v_value) returning id into v_id;
  return v_id;
end $$;

create or replace function public.admin_delete_item(p_user_id uuid, p_room_id uuid, p_item_id uuid)
returns void language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
begin
  if v_room.status <> 'waiting' then
    raise exception '아이템 삭제는 전투 시작 전에만 가능합니다.' using errcode = 'P0001';
  end if;
  delete from public.items where id = p_item_id and room_id = p_room_id;
  if not found then raise exception '아이템을 찾을 수 없습니다.' using errcode = 'P0001'; end if;
end $$;

create or replace function public.admin_grant_item(
  p_user_id uuid, p_room_id uuid, p_item_id uuid, p_player_id uuid, p_quantity int
) returns int language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_item public.items;
  v_player public.players;
  v_qty int;
begin
  if v_room.status = 'ended' then
    raise exception '종료된 전투에서는 아이템을 지급할 수 없습니다.' using errcode = 'P0001';
  end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 99 then
    raise exception '지급 수량은 1~99개로 입력하세요.' using errcode = 'P0001';
  end if;
  select * into v_item from public.items where id = p_item_id and room_id = p_room_id;
  if not found then raise exception '아이템을 찾을 수 없습니다.' using errcode = 'P0001'; end if;
  select p.* into v_player from public.players p join public.room_members m on m.id = p.member_id
   where p.id = p_player_id and p.room_id = p_room_id and m.status = 'active';
  if not found then raise exception '지급할 플레이어를 찾을 수 없습니다.' using errcode = 'P0001'; end if;

  insert into public.player_inventory (room_id, player_id, item_id, quantity)
  values (p_room_id, p_player_id, p_item_id, p_quantity)
  on conflict (player_id, item_id) do update set quantity = least(player_inventory.quantity + excluded.quantity, 999)
  returning quantity into v_qty;

  perform public.add_battle_log(p_room_id, 'item_granted',
    format('%s에게 %s %s개가 지급되었다.', v_player.display_name, v_item.name, p_quantity),
    'admin', null, 'player', p_player_id,
    jsonb_build_object('item_id', v_item.id, 'item_name', v_item.name, 'quantity', p_quantity, 'total', v_qty));
  return v_qty;
end $$;

-- ---------------------------------------------------------------------
-- 선공 측 / 턴 제한 시간 설정 (전투 시작 전에만)
-- ---------------------------------------------------------------------
create or replace function public.admin_update_room_settings(p_user_id uuid, p_room_id uuid, p_data jsonb)
returns void language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_first text := coalesce(nullif(p_data ->> 'first_side', ''), v_room.first_side);
  v_turn int := public.jint(p_data, 'turn_duration', '턴 제한 시간', 180, 420, v_room.turn_duration);
begin
  if v_room.status <> 'waiting' then
    raise exception '선공 측과 턴 시간은 전투 시작 전에만 바꿀 수 있습니다.' using errcode = 'P0001';
  end if;
  if v_first is not null and v_first not in ('players', 'enemies') then
    raise exception '선공 측이 올바르지 않습니다.' using errcode = 'P0001';
  end if;
  if v_turn not in (180, 300, 420) then
    raise exception '턴 제한 시간은 3분, 5분, 7분 중 하나여야 합니다.' using errcode = 'P0001';
  end if;
  update public.rooms set first_side = v_first, turn_duration = v_turn, updated_at = now() where id = p_room_id;
end $$;

-- =====================================================================
-- 권한 (002와 동일한 블록 반복 — 새 함수도 서버만 실행 가능)
-- =====================================================================
revoke execute on all functions in schema public from public, anon, authenticated;
grant  execute on all functions in schema public to service_role;
grant  execute on function public.is_admin(), public.is_room_member(uuid),
                           public.can_view_room(uuid), public.is_my_player(uuid)
  to authenticated;
