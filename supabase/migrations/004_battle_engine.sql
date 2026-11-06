-- =====================================================================
-- 004_battle_engine.sql : 4단계 턴제 전투 엔진
--   전투 시작 / 4단계 사이클 / 행동 제출 / 서버 판정 / 승패 / 조기 판정 / 강제 종료
--   + pg_cron 으로 5초마다 제한 시간 만료 단계 자동 판정
-- 실행 순서: 003 다음. 여러 번 실행해도 안전합니다.
--
-- 판정 규칙 요약 (docs/DESIGN.md 4장)
--  사이클 = ① 선공턴 ② 후공 반응턴 ③ 후공턴 ④ 선공 반응턴
--  플레이어 단계: 제한 시간 동안 행동 제출 → 시간 종료(또는 관리자 조기 판정) 시 일괄 판정
--  적군 단계: 즉시 자동 판정
--    - 적군 '턴'      : 공격 대상·공격력 선언 (pending_attacks) → 다음 플레이어 반응턴에서 적용
--    - 적군 '반응턴'  : 즉시 반격. 직전 플레이어 턴에서 회피를 고른 플레이어는 회피 판정
--  플레이어 단계 판정 순서: 회피 태세 공개 → 도주 → (반응턴이면) 선언된 적 공격 적용 → 아이템 → 일반 공격
-- =====================================================================

-- ---------------------------------------------------------------------
-- 조사 개선: 영문·숫자로 끝나는 이름도 자연스럽게 (Bob을 / 용사A가 / 3번이)
--   영문: L·M·N·R 로 끝나면 받침 있음 / 숫자: 0,1,3,6,7,8 은 받침 있음 (영, 일, 삼, 육, 칠, 팔)
-- ---------------------------------------------------------------------
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
    return case when lower(ch) in ('l', 'm', 'n', 'r') then p_with else p_without end;
  end if;
  return p_with || '(' || p_without || ')';
end $$;

-- ---------------------------------------------------------------------
-- 단계 정보
-- ---------------------------------------------------------------------
create or replace function public.phase_info(p_first text, p_n int, out acting_side text, out phase_type text)
language sql immutable as $$
  select case when p_n in (1, 4) then p_first
              else case p_first when 'players' then 'enemies' else 'players' end end,
         case when p_n in (1, 3) then 'turn' else 'reaction' end
$$;

create or replace function public.phase_name(p_first text, p_n int)
returns text language sql immutable as $$
  select case p_first
    when 'players' then (array['플레이어 선공턴', '적군 반응턴', '적군 후공턴', '플레이어 반응턴'])[p_n]
    else                (array['적군 선공턴', '플레이어 반응턴', '플레이어 후공턴', '적군 반응턴'])[p_n]
  end
$$;

-- 전투에 참여 중인(활성 참가자) 살아 있는 플레이어
create or replace function public.alive_players(p_room_id uuid)
returns setof public.players language sql stable as $$
  select p.* from public.players p
  join public.room_members m on m.id = p.member_id
  where p.room_id = p_room_id and m.status = 'active' and p.status = 'alive'
$$;

create or replace function public.roll(p_min int, p_max int)
returns int language sql volatile as $$
  select p_min + floor(random() * (p_max - p_min + 1))::int
$$;

-- 확률 판정 (rate: 0~100)
create or replace function public.chance(p_rate int)
returns boolean language sql volatile as $$
  select random() * 100 < p_rate
$$;

-- ---------------------------------------------------------------------
-- 새 단계 열기 (1단계면 새 사이클도 생성)
-- ---------------------------------------------------------------------
create or replace function public.open_phase(p_room_id uuid, p_cycle int, p_n int)
returns public.battle_phases language plpgsql as $$
declare
  v_room public.rooms;
  v_cycle_id uuid;
  v_info record;
  v_resp uuid;
  v_ph public.battle_phases;
begin
  select * into v_room from public.rooms where id = p_room_id;
  if p_n = 1 then
    insert into public.battle_cycles (room_id, cycle_number) values (p_room_id, p_cycle) returning id into v_cycle_id;
  else
    select id into v_cycle_id from public.battle_cycles where room_id = p_room_id and cycle_number = p_cycle;
  end if;
  select * into v_info from public.phase_info(v_room.first_side, p_n);
  if v_info.phase_type = 'reaction' then
    select id into v_resp from public.battle_phases where cycle_id = v_cycle_id and phase_number = p_n - 1;
  end if;

  insert into public.battle_phases (room_id, cycle_id, cycle_number, phase_number, phase_type, acting_side,
                                    response_to_phase_id, started_at, ends_at)
  values (p_room_id, v_cycle_id, p_cycle, p_n, v_info.phase_type, v_info.acting_side, v_resp, now(),
          case when v_info.acting_side = 'players' then now() + make_interval(secs => v_room.turn_duration) end)
  returning * into v_ph;

  update public.rooms set current_cycle = p_cycle, current_phase_id = v_ph.id, updated_at = now() where id = p_room_id;

  perform public.add_battle_log(p_room_id, 'phase_started',
    format('%s사이클 %s단계 · %s', p_cycle, p_n, public.phase_name(v_room.first_side, p_n)),
    'system', null, null, null,
    jsonb_build_object('acting_side', v_info.acting_side, 'phase_type', v_info.phase_type, 'ends_at', v_ph.ends_at));
  return v_ph;
end $$;

-- ---------------------------------------------------------------------
-- 적군 공격 1회 적용 (회피 판정 포함). 반환: 'hit' / 'dodged'
-- ---------------------------------------------------------------------
create or replace function public.apply_enemy_hit(
  p_room_id uuid, p_enemy public.enemies, p_target_id uuid, p_atk int, p_can_dodge boolean, p_pending_id uuid
) returns text language plpgsql as $$
declare
  t public.players;
  v_new int;
  v_dmg int;
begin
  select * into t from public.players where id = p_target_id for update;

  if p_can_dodge then
    if public.chance(t.dodge_rate) then
      perform public.add_battle_log(p_room_id, 'dodge_success',
        format('%s%s 회피에 성공했다! (%s%%)', t.display_name, public.josa(t.display_name, '이', '가'), t.dodge_rate),
        'player', t.id, 'enemy', p_enemy.id,
        jsonb_build_object('dodged', true, 'attack_power', p_atk, 'enemy_name', p_enemy.name));
      if p_pending_id is not null then
        update public.pending_attacks set status = 'dodged', damage = 0 where id = p_pending_id;
      end if;
      return 'dodged';
    end if;
    perform public.add_battle_log(p_room_id, 'dodge_fail',
      format('%s%s 회피에 실패했다.', t.display_name, public.josa(t.display_name, '이', '가')),
      'player', t.id, 'enemy', p_enemy.id, jsonb_build_object('dodged', false));
  end if;

  v_new := greatest(0, t.current_hp - p_atk);
  v_dmg := t.current_hp - v_new;
  update public.players
     set current_hp = v_new,
         status = case when v_new = 0 then 'dead' else status end,
         total_damage_taken = total_damage_taken + v_dmg,
         updated_at = now()
   where id = t.id;
  perform public.add_battle_log(p_room_id, 'damage',
    format('%s%s %s의 피해를 받았다. (HP %s → %s/%s)', t.display_name, public.josa(t.display_name, '이', '가'),
           p_atk, t.current_hp, v_new, t.max_hp),
    'enemy', p_enemy.id, 'player', t.id,
    jsonb_build_object('attack_power', p_atk, 'damage', v_dmg, 'hp_before', t.current_hp, 'hp_after', v_new,
                       'max_hp', t.max_hp, 'enemy_name', p_enemy.name, 'target_name', t.display_name));
  if v_new = 0 then
    perform public.add_battle_log(p_room_id, 'player_dead',
      format('%s%s 쓰러졌다.', t.display_name, public.josa(t.display_name, '이', '가')), 'system', null, 'player', t.id);
  end if;
  if p_pending_id is not null then
    update public.pending_attacks set status = 'hit', damage = v_dmg where id = p_pending_id;
  end if;
  return 'hit';
end $$;

-- ---------------------------------------------------------------------
-- 적군 단계 판정
-- ---------------------------------------------------------------------
create or replace function public.resolve_enemy_phase(p_room public.rooms, p_phase public.battle_phases)
returns void language plpgsql as $$
declare
  e public.enemies;
  v_targets uuid[];
  v_tid uuid;
  v_atk int;
  v_t public.players;
  v_count int := 0;
  v_can_dodge boolean;
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
      perform public.add_battle_log(p_room.id, 'enemy_idle',
        format('%s%s 공격할 대상을 찾지 못했다.', e.name, public.josa(e.name, '이', '가')), 'enemy', e.id);
      continue;
    end if;

    foreach v_tid in array v_targets loop
      select * into v_t from public.players where id = v_tid;
      continue when v_t.status <> 'alive';
      v_atk := public.roll(e.min_attack, e.max_attack);

      if p_phase.phase_type = 'turn' then
        -- 공격 선언: 다음 플레이어 반응턴에서 적용
        insert into public.pending_attacks (room_id, declared_phase_id, enemy_id, target_player_id, attack_power)
        values (p_room.id, p_phase.id, e.id, v_t.id, v_atk);
        perform public.add_battle_log(p_room.id, 'enemy_declare',
          format('%s%s %s%s 노린다! (공격력 %s)', e.name, public.josa(e.name, '이', '가'),
                 v_t.display_name, public.josa(v_t.display_name, '을', '를'), v_atk),
          'enemy', e.id, 'player', v_t.id,
          jsonb_build_object('attack_power', v_atk, 'enemy_name', e.name, 'target_name', v_t.display_name));
      else
        -- 반응턴: 즉시 반격. 직전 플레이어 턴에 회피를 골랐으면 회피 판정
        v_can_dodge := exists (
          select 1 from public.actions
           where phase_id = p_phase.response_to_phase_id and player_id = v_t.id
             and action_type = 'dodge' and status = 'resolved');
        perform public.add_battle_log(p_room.id, 'enemy_attack',
          format('%s%s %s%s 공격했다! (공격력 %s)', e.name, public.josa(e.name, '이', '가'),
                 v_t.display_name, public.josa(v_t.display_name, '을', '를'), v_atk),
          'enemy', e.id, 'player', v_t.id,
          jsonb_build_object('attack_power', v_atk, 'enemy_name', e.name, 'target_name', v_t.display_name));
        perform public.apply_enemy_hit(p_room.id, e, v_t.id, v_atk, v_can_dodge, null);
      end if;
    end loop;
  end loop;

  if v_count = 0 then
    perform public.add_battle_log(p_room.id, 'enemy_idle', '행동할 수 있는 적군이 없다.', 'system');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 플레이어 단계 판정 (제출된 행동을 모두 모은 뒤 일괄 처리)
-- ---------------------------------------------------------------------
create or replace function public.resolve_player_phase(p_room public.rooms, p_phase public.battle_phases)
returns void language plpgsql as $$
declare
  a record;
  pa public.pending_attacks;
  v_p public.players;
  v_e public.enemies;
  v_item public.items;
  v_qty int;
  v_names text;
  v_new int;
  v_atk int;
  v_dmg int;
  v_can_dodge boolean;
begin
  -- 0) 더 이상 행동할 수 없는 플레이어의 제출은 무효 (제출 후 사망/강퇴 등)
  update public.actions ac
     set status = 'invalid', resolved_at = now(), result = jsonb_build_object('reason', 'not_alive')
    from public.players p join public.room_members m on m.id = p.member_id
   where ac.phase_id = p_phase.id and ac.player_id = p.id and ac.status = 'submitted'
     and (p.status <> 'alive' or m.status <> 'active');

  -- 미제출자 (자동 행동 없음)
  select string_agg(ap.display_name, ', ' order by ap.display_name) into v_names
    from public.alive_players(p_room.id) ap
   where not exists (select 1 from public.actions where phase_id = p_phase.id and player_id = ap.id);
  if v_names is not null then
    perform public.add_battle_log(p_room.id, 'no_action', format('행동하지 않음: %s', v_names), 'system');
  end if;

  -- 1) 회피 태세 공개
  for a in
    select ac.id, ac.player_id, p.display_name from public.actions ac join public.players p on p.id = ac.player_id
     where ac.phase_id = p_phase.id and ac.status = 'submitted' and ac.action_type = 'dodge'
     order by ac.submitted_at
  loop
    update public.actions set status = 'resolved', resolved_at = now(), result = '{"stance":"dodge"}' where id = a.id;
    perform public.add_battle_log(p_room.id, 'dodge_stance',
      format('%s%s 회피 태세를 취했다.', a.display_name, public.josa(a.display_name, '이', '가')),
      'player', a.player_id, null, null, jsonb_build_object('action_type', 'dodge'));
  end loop;

  -- 2) 도주
  for a in
    select ac.id, ac.player_id from public.actions ac
     where ac.phase_id = p_phase.id and ac.status = 'submitted' and ac.action_type = 'escape'
     order by ac.submitted_at
  loop
    select * into v_p from public.players where id = a.player_id for update;
    if public.chance(v_p.escape_rate) then
      update public.players set status = 'escaped', updated_at = now() where id = v_p.id;
      update public.actions set status = 'resolved', resolved_at = now(), result = '{"escaped":true}' where id = a.id;
      perform public.add_battle_log(p_room.id, 'escape_success',
        format('%s%s 전투에서 도망쳤다! (도주 성공률 %s%%)', v_p.display_name, public.josa(v_p.display_name, '이', '가'), v_p.escape_rate),
        'player', v_p.id, null, null, jsonb_build_object('action_type', 'escape', 'success', true));
    else
      update public.actions set status = 'resolved', resolved_at = now(), result = '{"escaped":false}' where id = a.id;
      perform public.add_battle_log(p_room.id, 'escape_fail',
        format('%s%s 도망치려 했지만 실패했다.', v_p.display_name, public.josa(v_p.display_name, '이', '가')),
        'player', v_p.id, null, null, jsonb_build_object('action_type', 'escape', 'success', false));
    end if;
  end loop;

  -- 3) 적군 턴에 대한 반응턴: 선언된 적군 공격 적용 (이번 단계 회피 선택자는 회피 판정)
  if p_phase.phase_type = 'reaction' then
    for pa in
      select * from public.pending_attacks
       where declared_phase_id = p_phase.response_to_phase_id and status = 'pending'
       order by created_at, id
    loop
      update public.pending_attacks set resolve_phase_id = p_phase.id where id = pa.id;
      select * into v_e from public.enemies where id = pa.enemy_id;
      select p.* into v_p from public.players p where p.id = pa.target_player_id;
      if v_e.status <> 'alive' then
        update public.pending_attacks set status = 'cancelled' where id = pa.id;
        perform public.add_battle_log(p_room.id, 'attack_cancelled',
          format('%s%s 쓰러져 %s에 대한 공격이 취소되었다.', v_e.name, public.josa(v_e.name, '이', '가'), v_p.display_name),
          'enemy', v_e.id, 'player', v_p.id);
      elsif not exists (select 1 from public.alive_players(p_room.id) where id = v_p.id) then
        update public.pending_attacks set status = 'cancelled' where id = pa.id;
        perform public.add_battle_log(p_room.id, 'attack_cancelled',
          format('%s의 공격이 빗나갔다. (%s%s 전투에 없음)', v_e.name, v_p.display_name, public.josa(v_p.display_name, '이', '가')),
          'enemy', v_e.id, 'player', v_p.id);
      else
        v_can_dodge := exists (select 1 from public.actions where phase_id = p_phase.id and player_id = v_p.id
                                 and action_type = 'dodge' and status = 'resolved');
        perform public.add_battle_log(p_room.id, 'enemy_attack',
          format('%s의 공격이 %s에게 날아든다! (공격력 %s)', v_e.name, v_p.display_name, pa.attack_power),
          'enemy', v_e.id, 'player', v_p.id,
          jsonb_build_object('attack_power', pa.attack_power, 'enemy_name', v_e.name, 'target_name', v_p.display_name));
        perform public.apply_enemy_hit(p_room.id, v_e, v_p.id, pa.attack_power, v_can_dodge, pa.id);
      end if;
    end loop;
  end if;

  -- 4) 아이템 사용 (제출 순서)
  for a in
    select ac.id, ac.player_id, ac.item_id, ac.target_id from public.actions ac
     where ac.phase_id = p_phase.id and ac.status = 'submitted' and ac.action_type = 'item'
     order by ac.submitted_at
  loop
    select * into v_p from public.players where id = a.player_id for update;
    if v_p.status <> 'alive' then
      update public.actions set status = 'invalid', resolved_at = now(), result = '{"reason":"not_alive"}' where id = a.id;
      perform public.add_battle_log(p_room.id, 'action_invalid',
        format('%s%s 쓰러져 아이템을 사용하지 못했다.', v_p.display_name, public.josa(v_p.display_name, '이', '가')), 'player', v_p.id);
      continue;
    end if;
    select * into v_item from public.items where id = a.item_id;
    select quantity into v_qty from public.player_inventory where player_id = v_p.id and item_id = a.item_id for update;
    if v_item.id is null or coalesce(v_qty, 0) < 1 then
      update public.actions set status = 'invalid', resolved_at = now(), result = '{"reason":"no_item"}' where id = a.id;
      perform public.add_battle_log(p_room.id, 'action_invalid',
        format('%s%s 아이템이 없어 사용하지 못했다.', v_p.display_name, public.josa(v_p.display_name, '은', '는')), 'player', v_p.id);
      continue;
    end if;

    if v_item.item_type = 'heal' then
      v_new := least(v_p.max_hp, v_p.current_hp + v_item.effect_value);
      update public.players set current_hp = v_new, updated_at = now() where id = v_p.id;
      update public.player_inventory set quantity = quantity - 1 where player_id = v_p.id and item_id = v_item.id;
      update public.actions set status = 'resolved', resolved_at = now(),
             result = jsonb_build_object('healed', v_new - v_p.current_hp) where id = a.id;
      perform public.add_battle_log(p_room.id, 'item_heal',
        format('%s%s %s%s 사용했다. HP %s 회복 (HP %s → %s/%s)', v_p.display_name, public.josa(v_p.display_name, '이', '가'),
               v_item.name, public.josa(v_item.name, '을', '를'), v_new - v_p.current_hp, v_p.current_hp, v_new, v_p.max_hp),
        'player', v_p.id, 'player', v_p.id,
        jsonb_build_object('action_type', 'item', 'item_name', v_item.name, 'item_type', 'heal',
                           'hp_before', v_p.current_hp, 'hp_after', v_new, 'max_hp', v_p.max_hp));
    else
      select * into v_e from public.enemies where id = a.target_id and room_id = p_room.id for update;
      if v_e.id is null or v_e.appearance_status <> 'appeared' or v_e.status <> 'alive' then
        update public.actions set status = 'invalid', resolved_at = now(), result = '{"reason":"no_target"}' where id = a.id;
        perform public.add_battle_log(p_room.id, 'action_invalid',
          format('%s의 %s 대상이 이미 쓰러져 아이템을 사용하지 않았다.', v_p.display_name, v_item.name), 'player', v_p.id);
        continue;
      end if;
      v_new := greatest(0, v_e.current_hp - v_item.effect_value);
      v_dmg := v_e.current_hp - v_new;
      update public.enemies set current_hp = v_new, status = case when v_new = 0 then 'dead' else status end, updated_at = now()
       where id = v_e.id;
      update public.players set total_damage_dealt = total_damage_dealt + v_dmg where id = v_p.id;
      update public.player_inventory set quantity = quantity - 1 where player_id = v_p.id and item_id = v_item.id;
      update public.actions set status = 'resolved', resolved_at = now(),
             result = jsonb_build_object('damage', v_dmg) where id = a.id;
      perform public.add_battle_log(p_room.id, 'item_damage',
        format('%s%s %s%s %s에게 사용했다! %s의 피해 (HP %s → %s/%s)', v_p.display_name, public.josa(v_p.display_name, '이', '가'),
               v_item.name, public.josa(v_item.name, '을', '를'), v_e.name, v_dmg, v_e.current_hp, v_new, v_e.max_hp),
        'player', v_p.id, 'enemy', v_e.id,
        jsonb_build_object('action_type', 'item', 'item_name', v_item.name, 'item_type', 'damage', 'damage', v_dmg,
                           'hp_before', v_e.current_hp, 'hp_after', v_new, 'max_hp', v_e.max_hp));
      if v_new = 0 then
        perform public.add_battle_log(p_room.id, 'enemy_dead',
          format('%s%s 쓰러졌다!', v_e.name, public.josa(v_e.name, '이', '가')), 'system', null, 'enemy', v_e.id);
      end if;
    end if;
  end loop;

  -- 5) 일반 공격 (제출 순서): 공격력 산출 → 적군 회피 → 방어력 → 최종 피해 → HP 감소 → 사망 확인
  for a in
    select ac.id, ac.player_id, ac.target_id from public.actions ac
     where ac.phase_id = p_phase.id and ac.status = 'submitted' and ac.action_type = 'attack'
     order by ac.submitted_at
  loop
    select * into v_p from public.players where id = a.player_id;
    if v_p.status <> 'alive' then
      update public.actions set status = 'invalid', resolved_at = now(), result = '{"reason":"not_alive"}' where id = a.id;
      perform public.add_battle_log(p_room.id, 'action_invalid',
        format('%s%s 쓰러져 공격하지 못했다.', v_p.display_name, public.josa(v_p.display_name, '이', '가')), 'player', v_p.id);
      continue;
    end if;
    select * into v_e from public.enemies where id = a.target_id and room_id = p_room.id for update;
    if v_e.id is null or v_e.appearance_status <> 'appeared' or v_e.status <> 'alive' then
      update public.actions set status = 'invalid', resolved_at = now(), result = '{"reason":"no_target"}' where id = a.id;
      perform public.add_battle_log(p_room.id, 'action_invalid',
        format('%s의 공격 대상 %s%s 이미 쓰러져 공격이 무효가 되었다.', v_p.display_name, v_e.name, public.josa(v_e.name, '이', '가')),
        'player', v_p.id, 'enemy', v_e.id);
      continue;
    end if;

    v_atk := public.roll(v_p.min_attack, v_p.max_attack);
    perform public.add_battle_log(p_room.id, 'player_attack',
      format('%s%s %s%s 공격했다! (공격력 %s)', v_p.display_name, public.josa(v_p.display_name, '이', '가'),
             v_e.name, public.josa(v_e.name, '을', '를'), v_atk),
      'player', v_p.id, 'enemy', v_e.id,
      jsonb_build_object('action_type', 'attack', 'attack_power', v_atk, 'target_name', v_e.name));

    if public.chance(v_e.dodge_rate) then
      update public.actions set status = 'resolved', resolved_at = now(),
             result = jsonb_build_object('attack_power', v_atk, 'dodged', true, 'damage', 0) where id = a.id;
      perform public.add_battle_log(p_room.id, 'enemy_dodge',
        format('%s%s 공격을 회피했다!', v_e.name, public.josa(v_e.name, '이', '가')), 'enemy', v_e.id, 'player', v_p.id,
        jsonb_build_object('dodged', true));
      continue;
    end if;
    if v_e.dodge_rate > 0 then
      perform public.add_battle_log(p_room.id, 'enemy_dodge_fail',
        format('%s%s 회피에 실패했다.', v_e.name, public.josa(v_e.name, '이', '가')), 'enemy', v_e.id, null, null,
        jsonb_build_object('dodged', false));
    end if;

    v_dmg := greatest(0, v_atk - v_e.defense);
    v_new := greatest(0, v_e.current_hp - v_dmg);
    update public.enemies set current_hp = v_new, status = case when v_new = 0 then 'dead' else status end, updated_at = now()
     where id = v_e.id;
    update public.players set total_damage_dealt = total_damage_dealt + (v_e.current_hp - v_new) where id = v_p.id;
    update public.actions set status = 'resolved', resolved_at = now(),
           result = jsonb_build_object('attack_power', v_atk, 'dodged', false, 'damage', v_dmg) where id = a.id;
    perform public.add_battle_log(p_room.id, 'damage',
      format('%s%s %s의 피해를 받았다.%s (HP %s → %s/%s)', v_e.name, public.josa(v_e.name, '이', '가'), v_dmg,
             case when v_e.defense > 0 then format(' (방어력 %s 적용)', v_e.defense) else '' end,
             v_e.current_hp, v_new, v_e.max_hp),
      'player', v_p.id, 'enemy', v_e.id,
      jsonb_build_object('attack_power', v_atk, 'defense', v_e.defense, 'damage', v_dmg,
                         'hp_before', v_e.current_hp, 'hp_after', v_new, 'max_hp', v_e.max_hp));
    if v_new = 0 then
      perform public.add_battle_log(p_room.id, 'enemy_dead',
        format('%s%s 쓰러졌다!', v_e.name, public.josa(v_e.name, '이', '가')), 'system', null, 'enemy', v_e.id);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 승패 확인 (null = 계속)
-- ---------------------------------------------------------------------
create or replace function public.check_battle_end(p_room_id uuid)
returns text language plpgsql stable as $$
begin
  -- 승리: 등록된 적군이 있고, 모두 등장 + 모두 사망 (미등장 적군이 남아 있으면 승리 아님)
  if exists (select 1 from public.enemies where room_id = p_room_id)
     and not exists (select 1 from public.enemies where room_id = p_room_id
                      and not (appearance_status = 'appeared' and status = 'dead')) then
    return 'victory';
  end if;
  -- 패배: 생존 플레이어 0명
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
-- 전투 종료 (중복 호출 안전: 진행 중일 때만 처리)
-- ---------------------------------------------------------------------
create or replace function public.end_battle(p_room_id uuid, p_result text, p_reason text)
returns boolean language plpgsql as $$
declare
  v_room public.rooms;
  v_msg text;
begin
  select * into v_room from public.rooms where id = p_room_id for update;
  if v_room.status <> 'in_progress' then return false; end if;

  update public.battle_phases set status = 'aborted' where room_id = p_room_id and status = 'open';
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
  values (p_room_id, 'battle_ended', v_msg,
          jsonb_build_object('result', p_result, 'reason', p_reason, 'cycle_number', v_room.current_cycle));
  perform public.add_battle_log(p_room_id, 'battle_ended', v_msg, 'system', null, null, null,
          jsonb_build_object('result', p_result, 'reason', p_reason));
  return true;
end $$;

create or replace function public.check_and_end(p_room_id uuid)
returns text language plpgsql as $$
declare
  v_result text;
begin
  if not exists (select 1 from public.rooms where id = p_room_id and status = 'in_progress') then return null; end if;
  v_result := public.check_battle_end(p_room_id);
  if v_result is not null then
    perform public.end_battle(p_room_id, v_result, null);
  end if;
  return v_result;
end $$;

-- ---------------------------------------------------------------------
-- 진행 엔진: 판정할 단계가 있으면 판정 → 승패 확인 → 다음 단계 열기 (적군 단계는 연속 자동 처리)
--  p_force_phase_id: 관리자 조기 판정 대상 (시간이 남아 있어도 판정)
--  방 행을 잠그므로 cron / 브라우저 / 관리자가 동시에 불러도 한 번만 판정됩니다.
-- ---------------------------------------------------------------------
create or replace function public.progress_room(p_room_id uuid, p_force_phase_id uuid default null)
returns int language plpgsql as $$
declare
  v_room public.rooms;
  v_phase public.battle_phases;
  v_resolved int := 0;
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
    exit when v_phase.id is null or v_phase.status <> 'open';
    exit when v_phase.acting_side = 'players' and v_phase.ends_at > now() and v_phase.id is distinct from v_force;

    if v_phase.acting_side = 'players' then
      perform public.resolve_player_phase(v_room, v_phase);
    else
      perform public.resolve_enemy_phase(v_room, v_phase);
    end if;
    update public.battle_phases set status = 'resolved', resolved_at = now() where id = v_phase.id;
    v_resolved := v_resolved + 1;
    v_force := null;

    exit when public.check_and_end(p_room_id) is not null;

    if v_phase.phase_number < 4 then
      perform public.open_phase(p_room_id, v_phase.cycle_number, v_phase.phase_number + 1);
    else
      update public.battle_cycles set status = 'completed', ended_at = now() where id = v_phase.cycle_id;
      perform public.open_phase(p_room_id, v_phase.cycle_number + 1, 1);
    end if;
  end loop;
  return v_resolved;
end $$;

-- 제한 시간 만료 단계 일괄 처리 (pg_cron 이 5초마다 호출)
create or replace function public.battle_tick()
returns int language plpgsql as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select rm.id from public.rooms rm join public.battle_phases ph on ph.id = rm.current_phase_id
     where rm.status = 'in_progress' and ph.status = 'open'
       and (ph.acting_side = 'enemies' or ph.ends_at <= now())
  loop
    begin
      n := n + public.progress_room(r.id, null);
    exception when others then
      raise warning 'battle_tick room % 실패: %', r.id, sqlerrm;
    end;
  end loop;
  return n;
end $$;

-- 참가자/관리자 브라우저가 타이머 0초에 요청 (서버가 시간을 직접 확인하므로 일찍 불러도 판정 안 됨)
create or replace function public.room_tick(p_user_id uuid, p_room_id uuid)
returns int language plpgsql as $$
begin
  if not exists (select 1 from public.admins where user_id = p_user_id)
     and not exists (select 1 from public.room_members where room_id = p_room_id and user_id = p_user_id and status = 'active') then
    raise exception '이 전투방의 참가자가 아닙니다.' using errcode = 'P0001';
  end if;
  return public.progress_room(p_room_id, null);
end $$;

-- ---------------------------------------------------------------------
-- 관리자: 전투 시작
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
    raise exception '선공 측을 먼저 설정하세요. (6. 선공 측 설정)' using errcode = 'P0001';
  end if;
  select string_agg(display_name, ', ' order by display_name) into v_names from public.alive_players(p_room_id);
  if v_names is null then
    raise exception '전투에 참가할 (생존한) 플레이어가 없습니다.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.enemies where room_id = p_room_id) then
    raise exception '적군을 1명 이상 등록하세요. (등장은 전투 중에 시켜도 됩니다)' using errcode = 'P0001';
  end if;

  update public.rooms set status = 'in_progress', battle_started_at = now(), updated_at = now() where id = p_room_id;
  insert into public.battle_events (room_id, event_type, event_message, event_data)
  values (p_room_id, 'battle_started',
          format('⚔ 전투 시작! (%s 선공)', case v_room.first_side when 'players' then '플레이어 측' else '적군 측' end),
          jsonb_build_object('first_side', v_room.first_side, 'players', v_names, 'turn_duration', v_room.turn_duration));
  perform public.add_battle_log(p_room_id, 'battle_started',
    format('전투 시작 — 선공: %s / 참가자: %s', case v_room.first_side when 'players' then '플레이어 측' else '적군 측' end, v_names),
    'system', null, null, null, jsonb_build_object('first_side', v_room.first_side));

  perform public.open_phase(p_room_id, 1, 1);
  perform public.progress_room(p_room_id, null);   -- 적군 선공이면 바로 판정
end $$;

-- 관리자: 조기 판정 (현재 플레이어 단계를 시간 종료 전에 판정)
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
  if v_phase.status <> 'open' then
    raise exception '이미 판정된 단계입니다.' using errcode = 'P0001';
  end if;
  perform public.add_battle_log(p_room_id, 'early_resolve', '관리자가 조기 판정을 실행했다.', 'admin');
  return public.progress_room(p_room_id, v_phase.id);
end $$;

-- 관리자: 강제 종료
create or replace function public.admin_end_battle(p_user_id uuid, p_room_id uuid, p_reason text)
returns void language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_room.status = 'ended' then
    raise exception '이미 종료된 전투입니다.' using errcode = 'P0001';
  end if;
  if v_room.status <> 'in_progress' then
    raise exception '진행 중인 전투가 아닙니다.' using errcode = 'P0001';
  end if;
  if char_length(coalesce(v_reason, '')) > 200 then
    raise exception '종료 사유는 200자 이하로 입력하세요.' using errcode = 'P0001';
  end if;
  perform public.end_battle(p_room_id, 'forced', coalesce(v_reason, '관리자 강제 종료'));
end $$;

-- ---------------------------------------------------------------------
-- 플레이어: 행동 제출 (단계당 1회, 최초 제출만 접수)
--  p_data: { action_type: attack|dodge|item|escape, target_id?, item_id? }
-- ---------------------------------------------------------------------
create or replace function public.submit_action(p_user_id uuid, p_room_id uuid, p_data jsonb)
returns jsonb language plpgsql as $$
declare
  v_room public.rooms;
  v_phase public.battle_phases;
  v_player public.players;
  v_type text := p_data ->> 'action_type';
  v_target uuid;
  v_item_id uuid;
  v_item public.items;
  v_qty int;
  v_id uuid;
begin
  -- 공유 잠금: 판정(FOR UPDATE) 중에는 제출이 끼어들 수 없음
  select * into v_room from public.rooms where id = p_room_id for share;
  if not found then raise exception '전투방을 찾을 수 없습니다.' using errcode = 'P0001'; end if;

  select p.* into v_player from public.players p join public.room_members m on m.id = p.member_id
   where p.room_id = p_room_id and m.user_id = p_user_id and m.status = 'active';
  if not found then raise exception '이 전투방의 참가자가 아닙니다.' using errcode = 'P0001'; end if;

  if v_room.status = 'waiting' then raise exception '전투가 아직 시작되지 않았습니다.' using errcode = 'P0001'; end if;
  if v_room.status = 'ended' then raise exception '이미 종료된 전투입니다.' using errcode = 'P0001'; end if;

  select * into v_phase from public.battle_phases where id = v_room.current_phase_id;
  if v_phase.id is null or v_phase.status <> 'open' or v_phase.acting_side <> 'players' then
    raise exception '지금은 플레이어가 행동할 수 있는 단계가 아닙니다.' using errcode = 'P0001';
  end if;
  if v_phase.ends_at <= now() then
    raise exception '제한 시간이 끝났습니다. 판정을 기다리세요.' using errcode = 'P0001';
  end if;
  if v_player.status = 'dead' then raise exception '쓰러진 플레이어는 행동할 수 없습니다.' using errcode = 'P0001'; end if;
  if v_player.status = 'escaped' then raise exception '도주한 플레이어는 행동할 수 없습니다.' using errcode = 'P0001'; end if;
  if exists (select 1 from public.actions where phase_id = v_phase.id and player_id = v_player.id) then
    raise exception '이미 이번 단계에 행동을 제출했습니다.' using errcode = 'P0001';
  end if;
  if v_type is null or v_type not in ('attack', 'dodge', 'item', 'escape') then
    raise exception '알 수 없는 행동입니다.' using errcode = 'P0001';
  end if;

  begin
    v_target := nullif(p_data ->> 'target_id', '')::uuid;
    v_item_id := nullif(p_data ->> 'item_id', '')::uuid;
  exception when others then
    raise exception '잘못된 대상입니다.' using errcode = 'P0001';
  end;

  if v_type = 'item' then
    select * into v_item from public.items where id = v_item_id and room_id = p_room_id;
    if not found then raise exception '사용할 아이템을 선택하세요.' using errcode = 'P0001'; end if;
    select quantity into v_qty from public.player_inventory where player_id = v_player.id and item_id = v_item_id;
    if coalesce(v_qty, 0) < 1 then raise exception '아이템 수량이 부족합니다.' using errcode = 'P0001'; end if;
    if v_item.item_type = 'heal' then v_target := null; end if;
  else
    v_item_id := null;
  end if;

  if v_type = 'attack' or (v_type = 'item' and v_item.item_type = 'damage') then
    if v_target is null then raise exception '대상 적군을 선택하세요.' using errcode = 'P0001'; end if;
    if not exists (select 1 from public.enemies where id = v_target and room_id = p_room_id
                    and appearance_status = 'appeared' and status = 'alive') then
      raise exception '등장하지 않았거나 이미 쓰러진 적군입니다.' using errcode = 'P0001';
    end if;
  elsif v_type in ('dodge', 'escape') then
    v_target := null;
  end if;

  insert into public.actions (room_id, phase_id, player_id, action_type, target_id, item_id)
  values (p_room_id, v_phase.id, v_player.id, v_type, v_target, v_item_id)
  on conflict (phase_id, player_id) do nothing
  returning id into v_id;
  if v_id is null then
    raise exception '이미 이번 단계에 행동을 제출했습니다.' using errcode = 'P0001';
  end if;
  insert into public.phase_submissions (phase_id, player_id, room_id) values (v_phase.id, v_player.id, p_room_id)
  on conflict do nothing;
  return jsonb_build_object('action_id', v_id, 'phase_id', v_phase.id);
end $$;

-- ---------------------------------------------------------------------
-- 3단계 함수 보강: 관리자 HP 조정 / 강퇴 후 승패 확인
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
  perform public.check_and_end(p_room.id);   -- 전원 사망 시 패배 처리
end $$;

create or replace function public.admin_kick_member(p_user_id uuid, p_room_id uuid, p_member_id uuid)
returns void language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_m public.room_members;
begin
  update public.room_members
     set status = 'kicked', left_at = now()
   where id = p_member_id and room_id = p_room_id and status <> 'kicked'
  returning * into v_m;
  if v_m.id is null then
    raise exception '참가자를 찾을 수 없습니다.' using errcode = 'P0001';
  end if;
  if v_room.status = 'in_progress' then
    perform public.add_battle_log(p_room_id, 'player_removed',
      format('%s%s 관리자에 의해 전투에서 제외되었다.', v_m.nickname, public.josa(v_m.nickname, '이', '가')),
      'admin', null, 'player', (select id from public.players where member_id = v_m.id));
    perform public.check_and_end(p_room_id);
  end if;
end $$;

-- =====================================================================
-- 권한
-- =====================================================================
revoke execute on all functions in schema public from public, anon, authenticated;
grant  execute on all functions in schema public to service_role;
grant  execute on function public.is_admin(), public.is_room_member(uuid),
                           public.can_view_room(uuid), public.is_my_player(uuid)
  to authenticated;

-- =====================================================================
-- 서버 스케줄러: pg_cron 으로 5초마다 battle_tick() 실행
-- (pg_cron 이 없는 환경에서는 건너뜀 → 브라우저 타이머 요청 + 관리자 조기 판정으로만 진행)
-- =====================================================================
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('battle-tick', '5 seconds', 'select public.battle_tick()');
    raise notice 'pg_cron: battle-tick 5초 주기 등록';
  else
    raise notice 'pg_cron 을 사용할 수 없어 자동 예약 판정을 건너뜁니다.';
  end if;
end $$;
