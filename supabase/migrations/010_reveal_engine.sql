-- =====================================================================
-- 010_reveal_engine.sql : (v2 4단계) 행동 선언 → 5초 후 최종 결과 공개
--
--  진행 구간 = [1·2단계] 또는 [3·4단계] (화면의 [턴 + 반응턴] 묶음)
--   1) 첫 단계 행동 선언 공개 (플레이어 단계: 제한 시간 종료/조기 판정 시, 적군 단계: 즉시)
--   2) 두 번째 단계 행동 선언 공개
--   3) 두 번째 단계에 reveal_at = 지금 + 5초 저장 → 5초 대기
--   4) reveal_at 이 되면 그때 처음으로 판정(무작위 공격력·회피·도주·피해) → 결과 로그 + HP 반영
--   5) 다음 구간 시작
--
--  ▶ 판정은 공개 시각에 처음 실행되므로, 공개 전에는 결과가 DB 어디에도 없음 → 화면·네트워크로 새지 않음
--  ▶ 공개 시각은 DB(reveal_at) 기준 → 새로고침해도 남은 시간 유지
--  ▶ 1초마다 예약 작업이 확인 + 접속한 브라우저가 공개 시각에 확인 요청 (서버가 시각을 다시 검사)
--  ▶ 결과 공개 전에는 다음 단계로 넘어가지 않음 / 강제 종료 시 대기 중인 결과 공개는 취소
--  ▶ 방 행 잠금(FOR UPDATE)으로 같은 구간이 두 번 판정되지 않음
-- 실행 순서: 009 다음. 여러 번 실행해도 안전합니다.
-- =====================================================================

alter table public.battle_phases add column if not exists reveal_at timestamptz;
alter table public.battle_phases drop constraint if exists battle_phases_status_check;
alter table public.battle_phases add constraint battle_phases_status_check
  check (status in ('open', 'declared', 'resolved', 'aborted'));

alter table public.battle_logs add column if not exists stage text not null default 'info';
alter table public.battle_logs drop constraint if exists battle_logs_stage_check;
alter table public.battle_logs add constraint battle_logs_stage_check check (stage in ('declare', 'result', 'info'));

alter table public.pending_attacks alter column attack_power drop not null;

-- 조사 보완: 영문으로 끝나는 이름은 한국어로 읽을 때 받침이 생기는 경우(l·m·n·b·p: 볼·샘·존·밥·톱)만 받침 있음
--  (r 은 "피터·스타"처럼 받침 없이 읽히는 경우가 많아 받침 없음으로 처리)
create or replace function public.josa(p_word text, p_with text, p_without text)
returns text language plpgsql immutable as $$
declare
  ch text;
  c int;
begin
  if p_word is null or btrim(p_word) = '' then return p_with || '(' || p_without || ')'; end if;
  ch := right(btrim(p_word), 1);
  c := ascii(ch);
  if c between 44032 and 55203 then
    return case when (c - 44032) % 28 = 0 then p_without else p_with end;
  elsif ch ~ '[0-9]' then
    return case when ch in ('0', '1', '3', '6', '7', '8') then p_with else p_without end;
  elsif ch ~* '[a-z]' then
    return case when lower(ch) in ('l', 'm', 'n', 'b', 'p') then p_with else p_without end;
  end if;
  return p_with || '(' || p_without || ')';
end $$;

-- 이전 방식(단계마다 즉시 판정)의 함수 제거
drop function if exists public.resolve_player_phase(public.rooms, public.battle_phases);
drop function if exists public.resolve_enemy_phase(public.rooms, public.battle_phases);
drop function if exists public.apply_enemy_hit(uuid, public.enemies, uuid, int, boolean, uuid);

-- ---------------------------------------------------------------------
-- 특정 단계에 로그 기록 (결과 공개 때는 현재 단계가 아니라 원래 단계에 기록해야 하므로 단계를 직접 지정)
-- ---------------------------------------------------------------------
create or replace function public.log_at(
  p_room_id uuid, p_phase public.battle_phases, p_stage text, p_type text, p_content text,
  p_actor_type text default 'system', p_actor_id uuid default null,
  p_target_type text default null, p_target_id uuid default null, p_data jsonb default '{}'::jsonb
) returns void language sql as $$
  insert into public.battle_logs (room_id, cycle_id, phase_id, cycle_number, phase_number,
                                  actor_type, actor_id, target_type, target_id, log_type, content, data, stage)
  values (p_room_id, p_phase.cycle_id, p_phase.id, p_phase.cycle_number, p_phase.phase_number,
          p_actor_type, p_actor_id, p_target_type, p_target_id, p_type, p_content, coalesce(p_data, '{}'::jsonb), p_stage);
$$;

-- =====================================================================
-- 1. 행동 선언 (결과 없음: 누가 누구에게 무엇을 하는지만)
-- =====================================================================
create or replace function public.declare_player_phase(p_room public.rooms, p_phase public.battle_phases)
returns void language plpgsql as $$
declare
  a record;
  v_names text;
  v_txt text;
begin
  -- 더 이상 행동할 수 없는 플레이어의 제출은 무효 (제출 후 사망/강퇴 등)
  update public.actions ac
     set status = 'invalid', resolved_at = now(), result = jsonb_build_object('reason', 'not_alive')
    from public.players p join public.room_members m on m.id = p.member_id
   where ac.phase_id = p_phase.id and ac.player_id = p.id and ac.status = 'submitted'
     and (p.status <> 'alive' or m.status <> 'active');

  for a in
    select ac.*, p.display_name as pname, e.name as ename, i.name as iname, i.item_type
      from public.actions ac
      join public.players p on p.id = ac.player_id
      left join public.enemies e on e.id = ac.target_id
      left join public.items i on i.id = ac.item_id
     where ac.phase_id = p_phase.id and ac.status = 'submitted'
     order by ac.submitted_at
  loop
    v_txt := case a.action_type
      when 'attack' then format('%s%s %s%s 공격했다.', a.pname, public.josa(a.pname, '이', '가'), a.ename, public.josa(a.ename, '을', '를'))
      when 'dodge'  then format('%s%s 회피를 시도했다.', a.pname, public.josa(a.pname, '이', '가'))
      when 'escape' then format('%s%s 도망을 시도했다.', a.pname, public.josa(a.pname, '이', '가'))
      when 'item' then case when a.item_type = 'damage'
        then format('%s%s %s%s %s에게 던졌다.', a.pname, public.josa(a.pname, '이', '가'), a.iname, public.josa(a.iname, '을', '를'), a.ename)
        else format('%s%s %s%s 사용했다.', a.pname, public.josa(a.pname, '이', '가'), a.iname, public.josa(a.iname, '을', '를')) end
    end;
    perform public.log_at(p_room.id, p_phase, 'declare', 'declare_' || a.action_type, v_txt,
      'player', a.player_id, case when a.target_id is not null then 'enemy' end, a.target_id,
      jsonb_build_object('action_type', a.action_type, 'target_name', a.ename, 'item_name', a.iname));
  end loop;

  select string_agg(ap.display_name, ', ' order by ap.display_name) into v_names
    from public.alive_players(p_room.id) ap
   where not exists (select 1 from public.actions where phase_id = p_phase.id and player_id = ap.id);
  if v_names is not null then
    perform public.log_at(p_room.id, p_phase, 'declare', 'no_action', format('행동하지 않음: %s', v_names));
  end if;

  update public.battle_phases set status = 'declared' where id = p_phase.id;
end $$;

create or replace function public.declare_enemy_phase(p_room public.rooms, p_phase public.battle_phases)
returns void language plpgsql as $$
declare
  e public.enemies;
  v_targets uuid[];
  v_tid uuid;
  v_t public.players;
  v_count int := 0;
begin
  for e in
    select * from public.enemies
     where room_id = p_room.id and appearance_status = 'appeared' and status = 'alive'
     order by appearance_order
  loop
    v_count := v_count + 1;
    v_targets := null;
    if e.target_type = 'all' then
      select array_agg(id order by display_name) into v_targets from public.alive_players(p_room.id);
    elsif e.target_type = 'specific' and exists (select 1 from public.alive_players(p_room.id) where id = e.target_player_id) then
      v_targets := array[e.target_player_id];
    else
      select array[id] into v_targets from public.alive_players(p_room.id) order by random() limit 1;
    end if;
    if v_targets is null or cardinality(v_targets) = 0 then
      perform public.log_at(p_room.id, p_phase, 'declare', 'enemy_idle',
        format('%s%s 공격할 대상을 찾지 못했다.', e.name, public.josa(e.name, '이', '가')), 'enemy', e.id);
      continue;
    end if;
    foreach v_tid in array v_targets loop
      select * into v_t from public.players where id = v_tid;
      insert into public.pending_attacks (room_id, declared_phase_id, enemy_id, target_player_id, attack_power)
      values (p_room.id, p_phase.id, e.id, v_t.id, null);
      perform public.log_at(p_room.id, p_phase, 'declare', 'enemy_declare',
        case when p_phase.phase_type = 'turn'
             then format('%s%s %s%s 노린다!', e.name, public.josa(e.name, '이', '가'), v_t.display_name, public.josa(v_t.display_name, '을', '를'))
             else format('%s%s %s%s 공격했다.', e.name, public.josa(e.name, '이', '가'), v_t.display_name, public.josa(v_t.display_name, '을', '를')) end,
        'enemy', e.id, 'player', v_t.id, jsonb_build_object('enemy_name', e.name, 'target_name', v_t.display_name));
    end loop;
  end loop;
  if v_count = 0 then
    perform public.log_at(p_room.id, p_phase, 'declare', 'enemy_idle', '행동할 수 있는 적군이 없다.');
  end if;
  update public.battle_phases set status = 'declared' where id = p_phase.id;
end $$;

-- =====================================================================
-- 2. 판정 (결과 공개 시각에 처음 실행)
-- =====================================================================

-- 도주 판정
create or replace function public.resolve_escapes(p_room public.rooms, p_phase public.battle_phases)
returns void language plpgsql as $$
declare
  a record;
  v_p public.players;
begin
  for a in select * from public.actions where phase_id = p_phase.id and status = 'submitted' and action_type = 'escape' order by submitted_at loop
    select * into v_p from public.players where id = a.player_id for update;
    if v_p.status <> 'alive' then
      update public.actions set status = 'invalid', resolved_at = now(), result = '{"reason":"not_alive"}' where id = a.id;
      continue;
    end if;
    if public.chance(v_p.escape_rate) then
      update public.players set status = 'escaped', updated_at = now() where id = v_p.id;
      update public.actions set status = 'resolved', resolved_at = now(), result = '{"escaped":true}' where id = a.id;
      perform public.log_at(p_room.id, p_phase, 'result', 'escape_success',
        format('%s%s 전투에서 도망쳤다! (도주 성공)', v_p.display_name, public.josa(v_p.display_name, '이', '가')),
        'player', v_p.id, null, null, jsonb_build_object('action_type', 'escape', 'success', true, 'escape_rate', v_p.escape_rate));
    else
      update public.actions set status = 'resolved', resolved_at = now(), result = '{"escaped":false}' where id = a.id;
      perform public.log_at(p_room.id, p_phase, 'result', 'escape_fail',
        format('%s의 도주가 실패했다.', v_p.display_name),
        'player', v_p.id, null, null, jsonb_build_object('action_type', 'escape', 'success', false, 'escape_rate', v_p.escape_rate));
    end if;
  end loop;
end $$;

-- 선언된 적군 공격 적용. p_dodge_phase: 이 구간에서 플레이어가 회피를 선택했는지 볼 단계
create or replace function public.resolve_enemy_attacks(p_room public.rooms, p_phase public.battle_phases, p_dodge_phase_id uuid)
returns void language plpgsql as $$
declare
  pa public.pending_attacks;
  e public.enemies;
  t public.players;
  v_atk int;
  v_new int;
  v_dmg int;
  v_dodging boolean;
begin
  for pa in select * from public.pending_attacks where declared_phase_id = p_phase.id and status = 'pending' order by created_at, id loop
    select * into e from public.enemies where id = pa.enemy_id;
    select * into t from public.players where id = pa.target_player_id for update;
    if e.status <> 'alive' then
      update public.pending_attacks set status = 'cancelled' where id = pa.id;
      perform public.log_at(p_room.id, p_phase, 'result', 'attack_cancelled',
        format('%s%s %s 전장에 없어 %s에 대한 공격이 취소되었다.', e.name, public.josa(e.name, '은', '는'),
               case e.status when 'dead' then '쓰러져' else '물러나' end, t.display_name),
        'enemy', e.id, 'player', t.id);
      continue;
    end if;
    if not exists (select 1 from public.alive_players(p_room.id) where id = t.id) then
      update public.pending_attacks set status = 'cancelled' where id = pa.id;
      perform public.log_at(p_room.id, p_phase, 'result', 'attack_cancelled',
        format('%s의 공격이 빗나갔다. (%s%s 전장에 없음)', e.name, t.display_name, public.josa(t.display_name, '이', '가')),
        'enemy', e.id, 'player', t.id);
      continue;
    end if;

    v_atk := public.roll(e.min_attack, e.max_attack);
    v_dodging := exists (select 1 from public.actions where phase_id = p_dodge_phase_id and player_id = t.id and action_type = 'dodge' and status in ('submitted', 'resolved'));
    if v_dodging and public.chance(t.dodge_rate) then
      update public.pending_attacks set status = 'dodged', damage = 0, attack_power = v_atk where id = pa.id;
      perform public.log_at(p_room.id, p_phase, 'result', 'dodge_success',
        format('%s%s %s의 공격(공격력 %s)을 회피했다! (회피 성공)', t.display_name, public.josa(t.display_name, '이', '가'), e.name, v_atk),
        'player', t.id, 'enemy', e.id, jsonb_build_object('dodged', true, 'attack_power', v_atk, 'enemy_name', e.name, 'hp_after', t.current_hp));
      continue;
    end if;
    if v_dodging then
      perform public.log_at(p_room.id, p_phase, 'result', 'dodge_fail',
        format('%s의 회피가 실패했다.', t.display_name), 'player', t.id, 'enemy', e.id, jsonb_build_object('dodged', false));
    end if;

    v_new := greatest(0, t.current_hp - v_atk);
    v_dmg := t.current_hp - v_new;
    update public.players
       set current_hp = v_new, status = case when v_new = 0 then 'dead' else status end,
           total_damage_taken = total_damage_taken + v_dmg, updated_at = now()
     where id = t.id;
    update public.pending_attacks set status = 'hit', damage = v_dmg, attack_power = v_atk where id = pa.id;
    perform public.log_at(p_room.id, p_phase, 'result', 'damage',
      format('%s의 공격 적중! (공격력 %s) %s%s %s의 피해를 받았다. (HP %s → %s/%s)', e.name, v_atk,
             t.display_name, public.josa(t.display_name, '이', '가'), v_dmg, t.current_hp, v_new, t.max_hp),
      'enemy', e.id, 'player', t.id,
      jsonb_build_object('attack_power', v_atk, 'damage', v_dmg, 'hp_before', t.current_hp, 'hp_after', v_new,
                         'max_hp', t.max_hp, 'enemy_name', e.name, 'target_name', t.display_name, 'dodged', false));
    if v_new = 0 then
      perform public.log_at(p_room.id, p_phase, 'result', 'player_dead',
        format('%s%s 쓰러졌다.', t.display_name, public.josa(t.display_name, '이', '가')), 'system', null, 'player', t.id);
    end if;
  end loop;
end $$;

-- 아이템 사용 + 일반 공격 (제출 순서)
create or replace function public.resolve_items_attacks(p_room public.rooms, p_phase public.battle_phases)
returns void language plpgsql as $$
declare
  a record;
  v_p public.players;
  v_e public.enemies;
  v_item public.items;
  v_qty int;
  v_new int;
  v_dmg int;
  v_atk int;
begin
  -- 아이템
  for a in select * from public.actions where phase_id = p_phase.id and status = 'submitted' and action_type = 'item' order by submitted_at loop
    select * into v_p from public.players where id = a.player_id for update;
    if v_p.status <> 'alive' then
      update public.actions set status = 'invalid', resolved_at = now(), result = '{"reason":"not_alive"}' where id = a.id;
      perform public.log_at(p_room.id, p_phase, 'result', 'action_invalid',
        format('%s%s 쓰러져 아이템을 사용하지 못했다.', v_p.display_name, public.josa(v_p.display_name, '이', '가')), 'player', v_p.id);
      continue;
    end if;
    select * into v_item from public.items where id = a.item_id;
    select quantity into v_qty from public.player_inventory where player_id = v_p.id and item_id = a.item_id for update;
    if v_item.id is null or coalesce(v_qty, 0) < 1 then
      update public.actions set status = 'invalid', resolved_at = now(), result = '{"reason":"no_item"}' where id = a.id;
      perform public.log_at(p_room.id, p_phase, 'result', 'action_invalid',
        format('%s%s 아이템이 없어 사용하지 못했다.', v_p.display_name, public.josa(v_p.display_name, '은', '는')), 'player', v_p.id);
      continue;
    end if;
    if v_item.item_type = 'heal' then
      v_new := least(v_p.max_hp, v_p.current_hp + v_item.effect_value);
      update public.players set current_hp = v_new, updated_at = now() where id = v_p.id;
      update public.player_inventory set quantity = quantity - 1 where player_id = v_p.id and item_id = v_item.id;
      update public.actions set status = 'resolved', resolved_at = now(), result = jsonb_build_object('healed', v_new - v_p.current_hp) where id = a.id;
      perform public.log_at(p_room.id, p_phase, 'result', 'item_heal',
        format('%s의 %s 효과! HP %s 회복 (HP %s → %s/%s)', v_p.display_name, v_item.name, v_new - v_p.current_hp, v_p.current_hp, v_new, v_p.max_hp),
        'player', v_p.id, 'player', v_p.id,
        jsonb_build_object('action_type', 'item', 'item_name', v_item.name, 'item_type', 'heal', 'hp_before', v_p.current_hp, 'hp_after', v_new, 'max_hp', v_p.max_hp));
    else
      select * into v_e from public.enemies where id = a.target_id and room_id = p_room.id for update;
      if v_e.id is null or v_e.appearance_status <> 'appeared' or v_e.status <> 'alive' then
        update public.actions set status = 'invalid', resolved_at = now(), result = '{"reason":"no_target"}' where id = a.id;
        perform public.log_at(p_room.id, p_phase, 'result', 'action_invalid',
          format('%s의 %s: 대상이 전장에 없어 사용하지 않았다.', v_p.display_name, v_item.name), 'player', v_p.id);
        continue;
      end if;
      v_new := greatest(0, v_e.current_hp - v_item.effect_value);
      v_dmg := v_e.current_hp - v_new;
      update public.enemies set current_hp = v_new, status = case when v_new = 0 then 'dead' else status end, updated_at = now() where id = v_e.id;
      update public.players set total_damage_dealt = total_damage_dealt + v_dmg where id = v_p.id;
      update public.player_inventory set quantity = quantity - 1 where player_id = v_p.id and item_id = v_item.id;
      update public.actions set status = 'resolved', resolved_at = now(), result = jsonb_build_object('damage', v_dmg) where id = a.id;
      perform public.log_at(p_room.id, p_phase, 'result', 'item_damage',
        format('%s의 %s 명중! %s%s %s의 피해를 받았다. (HP %s → %s/%s)', v_p.display_name, v_item.name,
               v_e.name, public.josa(v_e.name, '이', '가'), v_dmg, v_e.current_hp, v_new, v_e.max_hp),
        'player', v_p.id, 'enemy', v_e.id,
        jsonb_build_object('action_type', 'item', 'item_name', v_item.name, 'item_type', 'damage', 'damage', v_dmg,
                           'hp_before', v_e.current_hp, 'hp_after', v_new, 'max_hp', v_e.max_hp));
      if v_new = 0 then
        perform public.log_at(p_room.id, p_phase, 'result', 'enemy_dead',
          format('%s%s 쓰러졌다!', v_e.name, public.josa(v_e.name, '이', '가')), 'system', null, 'enemy', v_e.id);
      end if;
    end if;
  end loop;

  -- 일반 공격: 공격력 산출 → 적군 회피 → 방어력 → 최종 피해(0 미만 없음) → HP 감소 → 사망 확인
  for a in select * from public.actions where phase_id = p_phase.id and status = 'submitted' and action_type = 'attack' order by submitted_at loop
    select * into v_p from public.players where id = a.player_id;
    if v_p.status <> 'alive' then
      update public.actions set status = 'invalid', resolved_at = now(), result = '{"reason":"not_alive"}' where id = a.id;
      perform public.log_at(p_room.id, p_phase, 'result', 'action_invalid',
        format('%s%s 쓰러져 공격하지 못했다.', v_p.display_name, public.josa(v_p.display_name, '이', '가')), 'player', v_p.id);
      continue;
    end if;
    select * into v_e from public.enemies where id = a.target_id and room_id = p_room.id for update;
    if v_e.id is null or v_e.appearance_status <> 'appeared' or v_e.status <> 'alive' then
      update public.actions set status = 'invalid', resolved_at = now(), result = '{"reason":"no_target"}' where id = a.id;
      perform public.log_at(p_room.id, p_phase, 'result', 'action_invalid',
        format('%s의 공격: 대상 %s%s 이미 전장에 없어 무효가 되었다.', v_p.display_name, v_e.name, public.josa(v_e.name, '이', '가')),
        'player', v_p.id, 'enemy', v_e.id);
      continue;
    end if;
    v_atk := public.roll(v_p.min_attack, v_p.max_attack);
    if public.chance(v_e.dodge_rate) then
      update public.actions set status = 'resolved', resolved_at = now(),
             result = jsonb_build_object('attack_power', v_atk, 'dodged', true, 'damage', 0) where id = a.id;
      perform public.log_at(p_room.id, p_phase, 'result', 'enemy_dodge',
        format('%s의 공격(공격력 %s) → %s%s 회피했다!', v_p.display_name, v_atk, v_e.name, public.josa(v_e.name, '이', '가')),
        'player', v_p.id, 'enemy', v_e.id, jsonb_build_object('attack_power', v_atk, 'dodged', true, 'damage', 0));
      continue;
    end if;
    v_dmg := greatest(0, v_atk - v_e.defense);
    v_new := greatest(0, v_e.current_hp - v_dmg);
    update public.enemies set current_hp = v_new, status = case when v_new = 0 then 'dead' else status end, updated_at = now() where id = v_e.id;
    update public.players set total_damage_dealt = total_damage_dealt + (v_e.current_hp - v_new) where id = v_p.id;
    update public.actions set status = 'resolved', resolved_at = now(),
           result = jsonb_build_object('attack_power', v_atk, 'dodged', false, 'damage', v_dmg) where id = a.id;
    perform public.log_at(p_room.id, p_phase, 'result', 'damage',
      format('%s의 공격 적중! (공격력 %s%s) %s%s %s의 피해를 받았다. (HP %s → %s/%s)', v_p.display_name, v_atk,
             case when v_e.defense > 0 then format(', 방어력 %s', v_e.defense) else '' end,
             v_e.name, public.josa(v_e.name, '이', '가'), v_dmg, v_e.current_hp, v_new, v_e.max_hp),
      'player', v_p.id, 'enemy', v_e.id,
      jsonb_build_object('attack_power', v_atk, 'defense', v_e.defense, 'damage', v_dmg, 'dodged', false,
                         'hp_before', v_e.current_hp, 'hp_after', v_new, 'max_hp', v_e.max_hp));
    if v_new = 0 then
      perform public.log_at(p_room.id, p_phase, 'result', 'enemy_dead',
        format('%s%s 쓰러졌다!', v_e.name, public.josa(v_e.name, '이', '가')), 'system', null, 'enemy', v_e.id);
    end if;
  end loop;
end $$;

-- 회피를 골랐지만 이번 구간에 공격받지 않은 플레이어 → 결과에 표시
create or replace function public.resolve_unused_dodges(p_room public.rooms, p_phase public.battle_phases, p_attack_phase_id uuid)
returns void language plpgsql as $$
declare
  a record;
begin
  for a in select ac.id, ac.player_id, p.display_name from public.actions ac join public.players p on p.id = ac.player_id
            where ac.phase_id = p_phase.id and ac.action_type = 'dodge' and ac.status = 'submitted' order by ac.submitted_at loop
    if not exists (select 1 from public.pending_attacks where declared_phase_id = p_attack_phase_id and target_player_id = a.player_id) then
      perform public.log_at(p_room.id, p_phase, 'result', 'dodge_unused',
        format('%s%s 회피 태세를 취했지만 공격받지 않았다.', a.display_name, public.josa(a.display_name, '은', '는')), 'player', a.player_id);
    end if;
    update public.actions set status = 'resolved', resolved_at = now(), result = '{"stance":"dodge"}' where id = a.id;
  end loop;
end $$;

-- 한 구간(a: 1·3단계, b: 2·4단계) 판정
create or replace function public.resolve_exchange(p_room public.rooms, p_a public.battle_phases, p_b public.battle_phases)
returns void language plpgsql as $$
begin
  perform public.log_at(p_room.id, p_b, 'result', 'reveal', '📣 판정 결과 공개');
  if p_a.acting_side = 'players' then
    -- 플레이어 턴 → 적군 반응: 도주 → 아이템·공격 → 적군 반격(턴에서 회피를 고른 플레이어는 회피 판정)
    perform public.resolve_escapes(p_room, p_a);
    perform public.resolve_items_attacks(p_room, p_a);
    perform public.resolve_enemy_attacks(p_room, p_b, p_a.id);
    perform public.resolve_unused_dodges(p_room, p_a, p_b.id);
  else
    -- 적군 턴 → 플레이어 반응: 도주 → 적군 공격 적용(반응턴 회피 판정) → 아이템·공격
    perform public.resolve_escapes(p_room, p_b);
    perform public.resolve_enemy_attacks(p_room, p_a, p_b.id);
    perform public.resolve_unused_dodges(p_room, p_b, p_a.id);
    perform public.resolve_items_attacks(p_room, p_b);
  end if;
  update public.battle_phases set status = 'resolved', resolved_at = now() where id in (p_a.id, p_b.id);
end $$;

-- =====================================================================
-- 3. 진행 엔진
-- =====================================================================
create or replace function public.progress_room(p_room_id uuid, p_force_phase_id uuid default null)
returns int language plpgsql as $$
declare
  v_room public.rooms;
  v_phase public.battle_phases;
  v_a public.battle_phases;
  v_steps int := 0;
  v_guard int := 0;
  v_force uuid := p_force_phase_id;
begin
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found or v_room.status <> 'in_progress' then return 0; end if;

  loop
    v_guard := v_guard + 1;
    exit when v_guard > 12;
    select * into v_room from public.rooms where id = p_room_id;
    exit when v_room.status <> 'in_progress';
    select * into v_phase from public.battle_phases where id = v_room.current_phase_id;
    exit when v_phase.id is null;

    if v_phase.status = 'open' then
      -- 플레이어 단계는 제한 시간이 끝났거나 관리자가 조기 마감했을 때만 선언
      exit when v_phase.acting_side = 'players' and v_phase.ends_at > now() and v_phase.id is distinct from v_force;
      if v_phase.acting_side = 'players' then
        perform public.declare_player_phase(v_room, v_phase);
      else
        perform public.declare_enemy_phase(v_room, v_phase);
      end if;
      v_steps := v_steps + 1;
      v_force := null;
      if v_phase.phase_number in (1, 3) then
        perform public.open_phase(p_room_id, v_phase.cycle_number, v_phase.phase_number + 1);
      else
        -- 구간의 선언이 모두 끝남 → 5초 뒤 결과 공개
        update public.battle_phases set reveal_at = now() + interval '5 seconds' where id = v_phase.id;
      end if;

    elsif v_phase.status = 'declared' then
      exit when v_phase.reveal_at is null or v_phase.reveal_at > now();
      select * into v_a from public.battle_phases where cycle_id = v_phase.cycle_id and phase_number = v_phase.phase_number - 1;
      perform public.resolve_exchange(v_room, v_a, v_phase);
      v_steps := v_steps + 1;
      exit when public.check_and_end(p_room_id) is not null;
      if v_phase.phase_number = 2 then
        perform public.open_phase(p_room_id, v_phase.cycle_number, 3);
      else
        update public.battle_cycles set status = 'completed', ended_at = now() where id = v_phase.cycle_id;
        perform public.open_phase(p_room_id, v_phase.cycle_number + 1, 1);
      end if;

    else
      exit;
    end if;
  end loop;
  return v_steps;
end $$;

-- 예약 작업: 선언할 단계 / 결과를 공개할 단계 / 저장 대기 기록 처리
create or replace function public.battle_tick()
returns int language plpgsql as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select rm.id from public.rooms rm join public.battle_phases ph on ph.id = rm.current_phase_id
     where rm.status = 'in_progress'
       and ((ph.status = 'open' and (ph.acting_side = 'enemies' or ph.ends_at <= now()))
         or (ph.status = 'declared' and ph.reveal_at <= now()))
  loop
    begin
      n := n + public.progress_room(r.id, null);
    exception when others then
      raise warning 'battle_tick room % 실패: %', r.id, sqlerrm;
    end;
  end loop;
  for r in select id from public.rooms where status = 'ended' and archive_status = 'pending' loop
    perform public.try_save_archive(r.id);
  end loop;
  return n;
end $$;

-- 관리자 조기 판정 = 플레이어 행동 조기 마감 (선언 공개 → 5초 대기는 그대로)
create or replace function public.admin_resolve_now(p_user_id uuid, p_room_id uuid)
returns int language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_phase public.battle_phases;
begin
  if v_room.status <> 'in_progress' then
    raise exception '진행 중인 전투가 아닙니다.' using errcode = 'P0001';
  end if;
  select * into v_phase from public.battle_phases where id = v_room.current_phase_id;
  if v_phase.status = 'declared' then
    raise exception '행동 선언이 끝나 결과 공개(5초)를 기다리는 중입니다.' using errcode = 'P0001';
  end if;
  if v_phase.status <> 'open' or v_phase.acting_side <> 'players' then
    raise exception '플레이어가 행동을 제출하는 단계에서만 조기 판정할 수 있습니다.' using errcode = 'P0001';
  end if;
  perform public.add_battle_log(p_room_id, 'early_resolve', '관리자가 행동 제출을 조기 마감했다.', 'admin');
  return public.progress_room(p_room_id, v_phase.id);
end $$;

-- 전투 종료 (007 대체): 대기 중인 결과 공개도 취소
create or replace function public.end_battle(p_room_id uuid, p_result text, p_reason text)
returns boolean language plpgsql as $$
declare
  v_room public.rooms;
  v_msg text;
begin
  select * into v_room from public.rooms where id = p_room_id for update;
  if v_room.status <> 'in_progress' then return false; end if;

  update public.battle_phases set status = 'aborted', reveal_at = null where room_id = p_room_id and status in ('open', 'declared');
  update public.battle_cycles c
     set status = case when (select count(*) from public.battle_phases where cycle_id = c.id and status = 'resolved') = 4
                       then 'completed' else 'aborted' end,
         ended_at = now()
   where room_id = p_room_id and status = 'in_progress';
  update public.pending_attacks set status = 'cancelled' where room_id = p_room_id and status = 'pending';

  v_msg := case p_result
    when 'victory'     then '🏆 전투 승리! 모든 적군을 쓰러뜨렸다.'
    when 'defeat'      then '💀 전투 패배… 살아남은 플레이어가 없다.'
    when 'all_escaped' then '🏃 모든 플레이어가 전장을 벗어났다. 전투 종료.'
    else format('⛔ 관리자가 전투를 종료했다.%s', coalesce(' (사유: ' || nullif(btrim(p_reason), '') || ')', ''))
  end;

  update public.rooms
     set status = 'ended', battle_ended_at = now(), result = p_result, end_reason = p_reason,
         archive_status = 'pending', updated_at = now()
   where id = p_room_id;
  insert into public.battle_events (room_id, event_type, event_message, event_data)
  values (p_room_id, 'battle_ended', v_msg, jsonb_build_object('result', p_result, 'reason', p_reason, 'cycle_number', v_room.current_cycle));
  perform public.add_battle_log(p_room_id, 'battle_ended', v_msg, 'system', null, null, null,
          jsonb_build_object('result', p_result, 'reason', p_reason));
  perform public.try_save_archive(p_room_id);
  return true;
end $$;

-- 권한
revoke execute on all functions in schema public from public, anon, authenticated;
grant  execute on all functions in schema public to service_role;
grant  execute on function public.is_admin(), public.is_room_member(uuid),
                           public.can_view_room(uuid), public.is_my_player(uuid)
  to authenticated;

-- 예약 작업: 1초마다 (결과 공개 5초를 정확히 지키기 위해)
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('battle-tick', '1 seconds', 'select public.battle_tick()');
  end if;
end $$;
