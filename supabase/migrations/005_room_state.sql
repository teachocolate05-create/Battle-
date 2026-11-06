-- =====================================================================
-- 005_room_state.sql : 방 전체 상태를 "한 번의 질의"로 조립
--   - 하나의 SQL 문 = 하나의 스냅샷 → 진행 중 상태가 섞여 보이는 일이 없음
--   - 서버 ↔ DB 왕복 1회 → 화면 갱신이 빨라짐
--   - 권한별 공개 범위를 여기서 결정 (판정 전 행동은 본인 것만, 미등장 적군은 관리자만)
-- 실행 순서: 004 다음. 여러 번 실행해도 안전합니다.
-- =====================================================================

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

    -- 관리자/본인: 전체 능력치, 다른 플레이어: 공개 정보만
    'players', coalesce((
      select jsonb_agg(
        case when (select is_admin from adm) or p.id = (select id from myp) then
          jsonb_build_object('id', p.id, 'member_id', p.member_id, 'display_name', p.display_name,
                             'max_hp', p.max_hp, 'current_hp', p.current_hp, 'status', p.status,
                             'min_attack', p.min_attack, 'max_attack', p.max_attack,
                             'dodge_rate', p.dodge_rate, 'escape_rate', p.escape_rate)
        else
          jsonb_build_object('id', p.id, 'member_id', p.member_id, 'display_name', p.display_name,
                             'max_hp', p.max_hp, 'current_hp', p.current_hp, 'status', p.status)
        end order by m.joined_at)
      from public.players p join vis_m m on m.id = p.member_id), '[]'::jsonb),

    'me', (select jsonb_build_object(
              'member', to_jsonb(m) - 'user_id',
              'player', (select jsonb_build_object('id', p.id, 'member_id', p.member_id, 'display_name', p.display_name,
                             'max_hp', p.max_hp, 'current_hp', p.current_hp, 'status', p.status,
                             'min_attack', p.min_attack, 'max_attack', p.max_attack,
                             'dodge_rate', p.dodge_rate, 'escape_rate', p.escape_rate) from myp p))
           from mine m where m.status = 'active'),

    -- 게스트: 등장한 적군만, 공격 대상 설정·등장 문구 원본은 숨김
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

    -- 인벤토리: 관리자 전체 / 게스트 본인만
    'inventory', coalesce((select jsonb_agg(jsonb_build_object('player_id', v.player_id, 'item_id', v.item_id, 'quantity', v.quantity))
                             from public.player_inventory v
                            where v.room_id = p_room_id and v.quantity > 0
                              and ((select is_admin from adm) or v.player_id = (select id from myp))), '[]'::jsonb),

    'events', coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from (
                select id, enemy_id, event_type, event_message, event_data, created_at
                  from public.battle_events where room_id = p_room_id order by id desc limit 200) x), '[]'::jsonb),

    'phase', (select jsonb_build_object('id', ph.id, 'cycle_number', ph.cycle_number, 'phase_number', ph.phase_number,
                                        'phase_type', ph.phase_type, 'acting_side', ph.acting_side,
                                        'response_to_phase_id', ph.response_to_phase_id, 'started_at', ph.started_at,
                                        'ends_at', ph.ends_at, 'resolved_at', ph.resolved_at, 'status', ph.status)
                from ph),

    -- 제출 여부 (행동 종류 없음)
    'submissions', coalesce((select jsonb_agg(s.player_id) from public.phase_submissions s join ph on s.phase_id = ph.id), '[]'::jsonb),

    -- 내 행동: 게스트 본인 것만 (관리자는 판정 전 행동을 볼 수 없음)
    'myAction', (select jsonb_build_object('action_type', a.action_type, 'target_id', a.target_id, 'item_id', a.item_id,
                                           'submitted_at', a.submitted_at, 'status', a.status)
                   from public.actions a join ph on a.phase_id = ph.id
                  where not (select is_admin from adm) and a.player_id = (select id from myp)),

    -- 지금 반응해야 할 선언된 적군 공격
    'pendingAttacks', coalesce((select jsonb_agg(jsonb_build_object('id', pa.id, 'enemy_id', pa.enemy_id,
                                     'target_player_id', pa.target_player_id, 'attack_power', pa.attack_power) order by pa.created_at)
                                  from public.pending_attacks pa join ph on pa.declared_phase_id = ph.response_to_phase_id
                                 where ph.acting_side = 'players' and ph.phase_type = 'reaction' and pa.status = 'pending'), '[]'::jsonb),

    'logs', coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from (
                select id, cycle_number, phase_number, phase_id, actor_type, actor_id, target_type, target_id,
                       log_type, content, data, created_at
                  from public.battle_logs where room_id = p_room_id order by id desc limit 400) x), '[]'::jsonb)
  )
end
$$;

-- 권한
revoke execute on all functions in schema public from public, anon, authenticated;
grant  execute on all functions in schema public to service_role;
grant  execute on function public.is_admin(), public.is_room_member(uuid),
                           public.can_view_room(uuid), public.is_my_player(uuid)
  to authenticated;
