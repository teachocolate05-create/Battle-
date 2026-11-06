-- =====================================================================
-- 007_archive.sql : 7단계 전투 기록 자동 저장 + 보관함
--   - 전투가 끝나는 순간(승리/패배/전원 도주/강제 종료) 자동 저장 (관리자가 저장 버튼을 누를 필요 없음)
--   - battle_results(요약) + battle_archives(전체 기록) 에 스냅샷 저장. rooms 와 FK 가 없어서 방을 지워도 남음
--   - room_id UNIQUE → 중복 저장 방지. 이미 저장됐으면 "이미 저장됨"으로 처리
--   - 저장 중 오류: 전투 종료는 그대로 유지, rooms.archive_status = 'failed' + 오류 기록 → 관리자 재시도
--   - 저장 전 방 삭제 금지 (기록 유실 방지)
-- 실행 순서: 006 다음. 여러 번 실행해도 안전합니다.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 실제 저장 (오류가 나면 예외를 그대로 올림 — try_save_archive 가 감쌈)
-- ---------------------------------------------------------------------
create or replace function public.save_battle_archive(p_room_id uuid)
returns text language plpgsql as $$
declare
  v_room public.rooms;
  v_result_id uuid;
  v_total_phases int;
  v_duration int;
  v_summary jsonb;
  v_full jsonb;
begin
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found then raise exception '전투방을 찾을 수 없습니다.' using errcode = 'P0001'; end if;
  if v_room.status <> 'ended' then raise exception '종료된 전투만 저장할 수 있습니다.' using errcode = 'P0001'; end if;

  -- 이미 저장됨 → 중복 저장 없이 상태만 맞춤
  if exists (select 1 from public.battle_archives where room_id = p_room_id) then
    update public.rooms set archive_status = 'saved', archive_error = null where id = p_room_id;
    return 'already_saved';
  end if;

  select count(*) into v_total_phases from public.battle_phases where room_id = p_room_id and status = 'resolved';
  v_duration := greatest(0, floor(extract(epoch from (coalesce(v_room.battle_ended_at, now()) - coalesce(v_room.battle_started_at, now()))))::int);

  -- 요약: 전투 기본 정보 / 참가자 / 적군 / 아이템
  v_summary := jsonb_build_object(
    'room', jsonb_build_object(
      'room_name', v_room.room_name, 'description', v_room.description, 'room_code', v_room.room_code,
      'first_side', v_room.first_side, 'turn_duration', v_room.turn_duration,
      'started_at', v_room.battle_started_at, 'ended_at', v_room.battle_ended_at, 'duration_seconds', v_duration,
      'result', v_room.result, 'end_reason', v_room.end_reason,
      'total_cycles', v_room.current_cycle, 'total_phases', v_total_phases),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nickname', m.nickname, 'display_name', p.display_name, 'member_status', m.status,
        'final_hp', p.current_hp, 'max_hp', p.max_hp, 'status', p.status,
        'damage_dealt', p.total_damage_dealt, 'damage_taken', p.total_damage_taken,
        'min_attack', p.min_attack, 'max_attack', p.max_attack, 'dodge_rate', p.dodge_rate, 'escape_rate', p.escape_rate,
        'items_used', coalesce((
          select jsonb_agg(jsonb_build_object('item_name', i.name, 'item_type', i.item_type, 'count', u.cnt) order by i.name)
            from (select a.item_id, count(*) as cnt from public.actions a
                   where a.player_id = p.id and a.action_type = 'item' and a.status = 'resolved' group by a.item_id) u
            join public.items i on i.id = u.item_id), '[]'::jsonb),
        'items_left', coalesce((
          select jsonb_agg(jsonb_build_object('item_name', i.name, 'quantity', v.quantity) order by i.name)
            from public.player_inventory v join public.items i on i.id = v.item_id
           where v.player_id = p.id and v.quantity > 0), '[]'::jsonb))
        order by m.joined_at)
      from public.players p join public.room_members m on m.id = p.member_id
     where p.room_id = p_room_id), '[]'::jsonb),
    'enemies', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', e.name, 'description', e.description,
        'appeared', e.appearance_status = 'appeared', 'appeared_at', e.appeared_at, 'appearance_order', e.appearance_order,
        'appearance_message', e.appearance_message,
        'final_hp', e.current_hp, 'max_hp', e.max_hp, 'dead', e.status = 'dead',
        'min_attack', e.min_attack, 'max_attack', e.max_attack, 'dodge_rate', e.dodge_rate, 'defense', e.defense,
        'target_type', e.target_type)
        order by e.appearance_order nulls last, e.created_at)
      from public.enemies e where e.room_id = p_room_id), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('name', i.name, 'description', i.description,
                                          'item_type', i.item_type, 'effect_value', i.effect_value) order by i.created_at)
      from public.items i where i.room_id = p_room_id), '[]'::jsonb)
  );

  -- 전체 기록: 요약 + 단계 / 전투 로그 / 시스템 이벤트 / 채팅 (각각 분리해서 보관)
  v_full := v_summary || jsonb_build_object(
    'phases', coalesce((
      select jsonb_agg(jsonb_build_object('cycle_number', ph.cycle_number, 'phase_number', ph.phase_number,
                                          'phase_type', ph.phase_type, 'acting_side', ph.acting_side,
                                          'started_at', ph.started_at, 'ends_at', ph.ends_at,
                                          'resolved_at', ph.resolved_at, 'status', ph.status)
                       order by ph.cycle_number, ph.phase_number)
      from public.battle_phases ph where ph.room_id = p_room_id), '[]'::jsonb),
    'logs', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'cycle_number', l.cycle_number, 'phase_number', l.phase_number,
                                          'actor_type', l.actor_type, 'target_type', l.target_type,
                                          'log_type', l.log_type, 'content', l.content, 'data', l.data,
                                          'created_at', l.created_at) order by l.id)
      from public.battle_logs l where l.room_id = p_room_id), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('id', ev.id, 'event_type', ev.event_type, 'event_message', ev.event_message,
                                          'event_data', ev.event_data, 'created_at', ev.created_at) order by ev.id)
      from public.battle_events ev where ev.room_id = p_room_id), '[]'::jsonb),
    'chat', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'sender_role', c.sender_role, 'nickname', c.nickname,
                                          'message', c.message, 'created_at', c.created_at) order by c.id)
      from public.chat_messages c where c.room_id = p_room_id), '[]'::jsonb)
  );

  insert into public.battle_results (room_id, result, total_cycles, total_phases, duration_seconds, result_data)
  values (p_room_id, v_room.result, v_room.current_cycle, v_total_phases, v_duration, v_summary)
  on conflict (room_id) do nothing
  returning id into v_result_id;
  if v_result_id is null then
    select id into v_result_id from public.battle_results where room_id = p_room_id;
  end if;

  insert into public.battle_archives (room_id, battle_result_id, room_name_snapshot, started_at, ended_at,
                                      result, first_side, archive_data)
  values (p_room_id, v_result_id, v_room.room_name, v_room.battle_started_at, v_room.battle_ended_at,
          v_room.result, v_room.first_side, v_full)
  on conflict (room_id) do nothing;

  update public.rooms set archive_status = 'saved', archive_error = null where id = p_room_id;
  return 'saved';
end $$;

-- ---------------------------------------------------------------------
-- 저장 시도: 오류가 나도 바깥 트랜잭션(전투 종료)은 유지, 실패 상태와 오류만 기록
-- ---------------------------------------------------------------------
create or replace function public.try_save_archive(p_room_id uuid)
returns text language plpgsql as $$
declare
  v_status text;
begin
  begin
    v_status := public.save_battle_archive(p_room_id);
  exception when others then
    update public.rooms set archive_status = 'failed', archive_error = left(sqlerrm, 500) where id = p_room_id;
    raise warning '전투 기록 저장 실패 (room %): %', p_room_id, sqlerrm;
    return 'failed';
  end;
  return v_status;
end $$;

-- 관리자: 저장 재시도
create or replace function public.admin_retry_archive(p_user_id uuid, p_room_id uuid)
returns text language plpgsql as $$
declare
  v_room public.rooms := public.lock_room_for_admin(p_user_id, p_room_id);
  v_status text;
begin
  if v_room.status <> 'ended' then
    raise exception '종료된 전투만 기록을 저장할 수 있습니다.' using errcode = 'P0001';
  end if;
  v_status := public.try_save_archive(p_room_id);
  if v_status = 'failed' then
    raise exception '전투 기록 저장에 실패했습니다: %', (select archive_error from public.rooms where id = p_room_id)
      using errcode = 'P0001';
  end if;
  return v_status;
end $$;

-- ---------------------------------------------------------------------
-- end_battle 보강: 종료 직후 자동 저장 (004 의 함수를 같은 동작 + 저장으로 교체)
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

  -- 자동 저장 (실패해도 전투 종료는 유지 → 관리자 재시도 / 예약 작업 재시도)
  perform public.try_save_archive(p_room_id);
  return true;
end $$;

-- ---------------------------------------------------------------------
-- battle_tick 보강: 저장 대기(pending) 상태로 남은 기록을 예약 작업이 다시 저장 시도
-- ---------------------------------------------------------------------
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

  for r in select id from public.rooms where status = 'ended' and archive_status = 'pending' loop
    perform public.try_save_archive(r.id);
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 방 삭제 보강: 종료된 전투의 기록이 저장되기 전에는 삭제 금지
-- ---------------------------------------------------------------------
create or replace function public.admin_delete_room(p_user_id uuid, p_room_id uuid)
returns void language plpgsql as $$
declare
  v_room public.rooms;
begin
  perform public.assert_admin(p_user_id);
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found then
    raise exception '전투방을 찾을 수 없습니다.' using errcode = 'P0001';
  end if;
  if v_room.status = 'in_progress' then
    raise exception '진행 중인 전투방은 삭제할 수 없습니다. 먼저 전투를 종료하세요.' using errcode = 'P0001';
  end if;
  if v_room.status = 'ended' and v_room.archive_status <> 'saved'
     and not exists (select 1 from public.battle_archives where room_id = p_room_id) then
    raise exception '전투 기록이 아직 저장되지 않았습니다. 7. 전투 진행 제어에서 [기록 저장 재시도] 후 삭제하세요.' using errcode = 'P0001';
  end if;
  delete from public.rooms where id = p_room_id;
end $$;

-- =====================================================================
-- 권한
-- =====================================================================
revoke execute on all functions in schema public from public, anon, authenticated;
grant  execute on all functions in schema public to service_role;
grant  execute on function public.is_admin(), public.is_room_member(uuid),
                           public.can_view_room(uuid), public.is_my_player(uuid)
  to authenticated;
