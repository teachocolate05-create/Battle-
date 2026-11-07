-- 4단계 테스트: 전투 시작 / 4단계 사이클 / 행동 제출 / 판정 / 승패 / 조기 판정 / 강제 종료
-- 확률은 0% 또는 100%, 공격력은 최소=최대로 고정해서 결과가 항상 같게 만듭니다.
create or replace function pg_temp.expect_error(p_sql text, p_contains text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_contains in sqlerrm) = 0 then
      raise exception 'FAIL: 예상 오류 "%" 대신 "%" 발생 (sql: %)', p_contains, sqlerrm, p_sql;
    end if;
    raise notice 'ok  - 예상한 오류: %', sqlerrm;
    return;
  end;
  raise exception 'FAIL: 오류가 나야 하는데 성공함 (sql: %)', p_sql;
end $$;
create or replace function pg_temp.ok(p_cond boolean, p_name text)
returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'ok  - %', p_name;
end $$;

-- 테스트 도우미: 이름으로 ID 찾기
create or replace function pg_temp.pid(p_name text) returns uuid language sql as $$
  select id from public.players where display_name = p_name $$;
create or replace function pg_temp.eid(p_name text) returns uuid language sql as $$
  select id from public.enemies where name = p_name $$;
create or replace function pg_temp.hp(p_name text) returns int language sql as $$
  select coalesce((select current_hp from public.players where display_name = p_name),
                  (select current_hp from public.enemies where name = p_name)) $$;
create or replace function pg_temp.cur_phase(p_room uuid) returns public.battle_phases language sql as $$
  select ph.* from public.battle_phases ph join public.rooms r on r.current_phase_id = ph.id where r.id = p_room $$;
-- 현재 단계의 제한 시간을 지난 것으로 만들기
create or replace function pg_temp.expire(p_room uuid) returns void language sql as $$
  update public.battle_phases set ends_at = now() - interval '1 second'
   where id = (select current_phase_id from public.rooms where id = p_room) $$;

-- 결과 공개 시각을 지난 것으로 만들고 예약 작업 실행 (실제로는 5초 뒤 자동)
create or replace function pg_temp.reveal(p_room uuid) returns int language plpgsql as $$
begin
  update public.battle_phases set reveal_at = now() - interval '1 second'
   where id = (select current_phase_id from public.rooms where id = p_room) and status = 'declared';
  return public.battle_tick();
end $$;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000004a1'),
  ('00000000-0000-0000-0000-000000000041'), ('00000000-0000-0000-0000-000000000042'),
  ('00000000-0000-0000-0000-000000000043'), ('00000000-0000-0000-0000-000000000044'),
  ('00000000-0000-0000-0000-000000000045'), ('00000000-0000-0000-0000-000000000046');
select public.register_admin('00000000-0000-0000-0000-0000000004a1');

-- =====================================================================
-- 시나리오 A: 플레이어 선공, 2사이클, 승리
-- =====================================================================
create temp table A as
  select (r->>'id')::uuid as room_id, r->>'room_code' as code, '00000000-0000-0000-0000-0000000004a1'::uuid as adm
  from (select public.admin_create_room('00000000-0000-0000-0000-0000000004a1', 'A방', '', null, 10, 180) r) x;
select public.join_room('00000000-0000-0000-0000-000000000041', (select code from A), '기사', null);
select public.join_room('00000000-0000-0000-0000-000000000042', (select code from A), '도적', null);
select public.admin_update_player((select adm from A), (select room_id from A), pg_temp.pid('기사'),
  '{"min_attack":10,"max_attack":10,"dodge_rate":100,"escape_rate":0}');
select public.admin_update_player((select adm from A), (select room_id from A), pg_temp.pid('도적'),
  '{"min_attack":5,"max_attack":5,"dodge_rate":0,"escape_rate":0}');
select public.admin_save_enemy((select adm from A), (select room_id from A), null,
  '{"name":"허수아비","max_hp":30,"min_attack":3,"max_attack":3,"dodge_rate":0,"defense":2,"target_type":"all"}');
select public.admin_save_enemy((select adm from A), (select room_id from A), null,
  '{"name":"늑대","max_hp":10,"min_attack":1,"max_attack":1,"dodge_rate":0,"defense":0,"target_type":"all"}');
select public.admin_appear_enemy((select adm from A), (select room_id from A), pg_temp.eid('허수아비'));
create temp table bomb as select public.admin_create_item((select adm from A), (select room_id from A),
  '{"item_type":"damage","name":"폭탄","effect_value":5}') as id;
select public.admin_grant_item((select adm from A), (select room_id from A), (select id from bomb), pg_temp.pid('도적'), 1);

-- 시작 조건
select pg_temp.expect_error(format($$select public.admin_start_battle(%L,%L)$$, (select adm from A), (select room_id from A)), '선공 측을 먼저');
select pg_temp.expect_error(format($$select public.submit_action('00000000-0000-0000-0000-000000000041',%L,'{"action_type":"dodge"}')$$,
  (select room_id from A)), '아직 시작되지');
select public.admin_update_room_settings((select adm from A), (select room_id from A), '{"first_side":"players"}');
select pg_temp.expect_error(format($$select public.admin_start_battle('00000000-0000-0000-0000-000000000041',%L)$$, (select room_id from A)), '관리자 권한');
select public.admin_start_battle((select adm from A), (select room_id from A));
select pg_temp.expect_error(format($$select public.admin_start_battle(%L,%L)$$, (select adm from A), (select room_id from A)), '이미 시작');

select pg_temp.ok((select status = 'in_progress' and current_cycle = 1 and battle_started_at is not null from public.rooms where id = (select room_id from A)),
  '전투 시작 → 진행 중, 1사이클');
select pg_temp.ok((select phase_number = 1 and acting_side = 'players' and phase_type = 'turn' and status = 'open'
                     and ends_at > now() + interval '170 seconds' from pg_temp.cur_phase((select room_id from A))),
  '1단계 = 플레이어 선공턴, 서버 기준 마감 시각(3분) 저장');
select pg_temp.ok((select count(*) = 1 from public.battle_events where room_id = (select room_id from A) and event_type = 'battle_started'),
  '전투 시작 시스템 이벤트');

-- 행동 제출 검증
select pg_temp.expect_error(format($$select public.submit_action('00000000-0000-0000-0000-000000000041',%L,%L)$$,
  (select room_id from A), json_build_object('action_type','attack','target_id',pg_temp.eid('늑대'))), '등장하지 않았거나');
select pg_temp.expect_error(format($$select public.submit_action('00000000-0000-0000-0000-000000000041',%L,'{"action_type":"attack"}')$$,
  (select room_id from A)), '대상 적군을 선택');
select pg_temp.expect_error(format($$select public.submit_action('00000000-0000-0000-0000-000000000041',%L,%L)$$,
  (select room_id from A), json_build_object('action_type','item','item_id',(select id from bomb),'target_id',pg_temp.eid('허수아비'))), '수량이 부족');
select pg_temp.expect_error(format($$select public.submit_action('00000000-0000-0000-0000-000000000043',%L,'{"action_type":"dodge"}')$$,
  (select room_id from A)), '참가자가 아닙니다');
select public.submit_action('00000000-0000-0000-0000-000000000041', (select room_id from A),
  json_build_object('action_type','attack','target_id',pg_temp.eid('허수아비'))::jsonb);
select pg_temp.expect_error(format($$select public.submit_action('00000000-0000-0000-0000-000000000041',%L,'{"action_type":"dodge"}')$$,
  (select room_id from A)), '이미 이번 단계에');
select public.submit_action('00000000-0000-0000-0000-000000000042', (select room_id from A),
  json_build_object('action_type','item','item_id',(select id from bomb),'target_id',pg_temp.eid('허수아비'))::jsonb);
select pg_temp.ok((select count(*) = 2 from public.phase_submissions where room_id = (select room_id from A)), '제출 여부 2명 기록');

-- 판정 전 비공개 (RLS)
grant select on A to authenticated;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000041', false);
select pg_temp.ok((select count(*) = 1 and bool_and(action_type = 'attack') from public.actions), '본인은 자기 행동만 조회');
select pg_temp.ok((select count(*) = 2 from public.phase_submissions), '제출 여부(행동 종류 없음)는 모두 조회');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000004a1', false);
select pg_temp.ok((select count(*) = 2 from public.actions), '관리자는 판정 전 행동 확인 가능 (v2 요청서 8-4)');
reset role;

-- 시간이 남았으면 cron 이 돌아도 판정 안 함
select pg_temp.ok(public.battle_tick() = 0, '제한 시간 전에는 자동 판정하지 않음 (모두 제출해도 대기)');
select pg_temp.ok(public.room_tick('00000000-0000-0000-0000-000000000041', (select room_id from A)) = 0, '브라우저 요청도 시간 전에는 무시');

-- 시간 만료 → 1단계(플레이어) 선언 공개 + 2단계(적 반응) 선언 → 5초 대기 (결과는 아직 없음)
select pg_temp.expire((select room_id from A));
select pg_temp.expect_error(format($$select public.submit_action('00000000-0000-0000-0000-000000000041',%L,'{"action_type":"dodge"}')$$,
  (select room_id from A)), '제한 시간이 끝났습니다');
select pg_temp.ok(public.battle_tick() = 2, '시간 만료 → 1단계 선언 공개 + 2단계 적군 선언 (판정은 아직)');
select pg_temp.ok((select count(*) = 1 from public.battle_logs where room_id = (select room_id from A) and stage = 'declare' and content = '기사가 허수아비를 공격했다.')
              and (select count(*) = 1 from public.battle_logs where room_id = (select room_id from A) and stage = 'declare' and content = '도적이 폭탄을 허수아비에게 던졌다.')
              and (select count(*) = 2 from public.battle_logs where room_id = (select room_id from A) and stage = 'declare' and log_type = 'enemy_declare' and content like '허수아비가 % 공격했다.'),
  '행동 선언: 누가 누구에게 무엇을 했는지만 공개');
select pg_temp.ok((select count(*) = 0 from public.battle_logs where room_id = (select room_id from A) and stage = 'declare' and (content ~ '[0-9]' or data ? 'damage' or data ? 'attack_power')),
  '선언에는 공격력·피해량 등 숫자가 없음');
select pg_temp.ok((select count(*) = 0 from public.battle_logs where room_id = (select room_id from A) and stage = 'result'), '결과 로그 없음 (판정 전)');
select pg_temp.ok(pg_temp.hp('허수아비') = 30 and pg_temp.hp('기사') = 100 and pg_temp.hp('도적') = 100, '결과 공개 전에는 HP 변화 없음');
select pg_temp.ok((select quantity = 1 from public.player_inventory where player_id = pg_temp.pid('도적')), '결과 공개 전에는 아이템 수량도 그대로');
select pg_temp.ok((select phase_number = 2 and status = 'declared' and reveal_at between now() + interval '4 seconds' and now() + interval '6 seconds'
                     from pg_temp.cur_phase((select room_id from A))), '2단계 선언 완료, 서버 기준 5초 뒤 공개 시각 저장');
select pg_temp.ok((select count(*) = 2 and bool_and(attack_power is null) from public.pending_attacks where room_id = (select room_id from A)),
  '적군 공격력은 공개 전까지 정해지지도 않음');
select pg_temp.ok(public.battle_tick() = 0, '5초가 지나기 전에는 결과 공개 안 함');
select pg_temp.expect_error(format($$select public.admin_resolve_now(%L,%L)$$, (select adm from A), (select room_id from A)), '결과 공개(5초)');

-- 5초 경과 → 결과 공개 → 3단계(적 후공) 선언 → 4단계 열림
select pg_temp.ok(pg_temp.reveal((select room_id from A)) = 2, '5초 후 결과 공개 + 다음 구간 적군 선언');
select pg_temp.ok(pg_temp.hp('허수아비') = 17, '폭탄 5(고정) + 공격 10-방어 2=8 → 허수아비 HP 30→17');
select pg_temp.ok((select quantity = 0 from public.player_inventory where player_id = pg_temp.pid('도적')), '아이템 사용 후 수량 차감');
select pg_temp.ok(pg_temp.hp('기사') = 97 and pg_temp.hp('도적') = 97, '적 반응턴: 전체 공격 3 → 두 플레이어 97');
select pg_temp.ok((select count(*) >= 1 from public.battle_logs where room_id = (select room_id from A) and stage = 'result' and content like '기사의 공격 적중! (공격력 10, 방어력 2)%'),
  '결과: 공격력·방어력·피해량·HP 변화 공개');
select pg_temp.ok((select count(*) = 2 from public.pending_attacks where room_id = (select room_id from A) and status = 'pending'),
  '적 후공턴: 공격 2건 선언 (아직 미적용)');
select pg_temp.ok((select phase_number = 4 and acting_side = 'players' and phase_type = 'reaction' and status = 'open'
                     from pg_temp.cur_phase((select room_id from A))), '4단계 = 플레이어 반응턴 열림');
select pg_temp.ok((select count(*) = 2 from public.battle_phases where room_id = (select room_id from A) and status = 'resolved')
              and (select count(*) = 1 from public.battle_phases where room_id = (select room_id from A) and status = 'declared'),
  '단계별 기록 (1·2 판정 완료, 3 선언됨)');
select pg_temp.ok((select count(*) = 2 from public.actions where room_id = (select room_id from A) and status = 'resolved'), '판정 후 행동 resolved');

-- 반응턴: 기사 회피(100%) / 도적 미제출 → 조기 마감 → 선언 → 5초 → 선언된 공격 적용
select public.submit_action('00000000-0000-0000-0000-000000000041', (select room_id from A), '{"action_type":"dodge"}');
select pg_temp.ok(public.admin_resolve_now((select adm from A), (select room_id from A)) = 1, '관리자 조기 마감 → 4단계 선언');
select pg_temp.ok((select count(*) = 1 from public.battle_logs where room_id = (select room_id from A) and content = '기사가 회피를 시도했다.'), '회피 선언');
select pg_temp.ok(pg_temp.hp('도적') = 97, '조기 마감해도 결과는 5초 뒤');
select pg_temp.reveal((select room_id from A));
select pg_temp.ok(pg_temp.hp('기사') = 97, '반응턴 회피 성공 → 피해 무효');
select pg_temp.ok(pg_temp.hp('도적') = 94, '미제출 플레이어도 공격 대상 → 피해 3');
select pg_temp.ok((select count(*) = 1 from public.battle_logs where room_id = (select room_id from A) and log_type = 'dodge_success' and content like '기사가 허수아비의 공격(공격력 3)을 회피했다!%'),
  '회피 성공 여부는 결과에서 공개');
select pg_temp.ok((select count(*) = 1 from public.battle_logs where room_id = (select room_id from A) and log_type = 'no_action' and content like '%도적%'),
  '미제출 플레이어 기록 (자동 행동 없음)');
select pg_temp.ok((select string_agg(pa.status, ',' order by pa.status) = 'dodged,hit' from public.pending_attacks pa
                     join public.battle_phases ph on ph.id = pa.declared_phase_id
                    where pa.room_id = (select room_id from A) and ph.cycle_number = 1 and ph.phase_number = 3),
  '3단계에 선언된 공격 결과: 회피 / 적중');
select pg_temp.ok((select current_cycle = 2 from public.rooms where id = (select room_id from A))
              and (select phase_number = 1 from pg_temp.cur_phase((select room_id from A))), '4단계 후 다음 사이클(2) 1단계');
select pg_temp.ok((select status = 'completed' from public.battle_cycles where room_id = (select room_id from A) and cycle_number = 1), '1사이클 완료 기록');

-- 사망한 플레이어 행동 불가 / 관리자 부활
select public.admin_set_player_hp((select adm from A), (select room_id from A), pg_temp.pid('도적'), 0, null);
select pg_temp.ok((select status = 'in_progress' from public.rooms where id = (select room_id from A)), '한 명만 쓰러지면 전투 계속');
select pg_temp.expect_error(format($$select public.submit_action('00000000-0000-0000-0000-000000000042',%L,'{"action_type":"dodge"}')$$,
  (select room_id from A)), '쓰러진 플레이어');
select public.admin_set_player_hp((select adm from A), (select room_id from A), pg_temp.pid('도적'), 50, '부활');

-- 미등장 적군이 남아 있으면 승리 아님 → 늑대 등장 후 모두 처치
select public.admin_save_enemy((select adm from A), (select room_id from A), pg_temp.eid('허수아비'), '{"current_hp":8}');
select public.submit_action('00000000-0000-0000-0000-000000000041', (select room_id from A),
  json_build_object('action_type','attack','target_id',pg_temp.eid('허수아비'))::jsonb);
select public.admin_resolve_now((select adm from A), (select room_id from A));
select pg_temp.ok((select status = 'alive' from public.enemies where name = '허수아비'), '선언 단계에서는 아직 살아 있음');
select pg_temp.reveal((select room_id from A));
select pg_temp.ok((select status = 'dead' from public.enemies where name = '허수아비'), '허수아비 사망 (HP 0, 음수 아님)');
select pg_temp.ok((select count(*) = 2 from public.battle_logs where room_id = (select room_id from A) and log_type = 'attack_cancelled' and content like '허수아비는 쓰러져%'),
  '선언했지만 먼저 쓰러진 적군의 반격은 취소');
select pg_temp.ok(pg_temp.hp('허수아비') = 0, 'HP는 0 미만으로 내려가지 않음');
select pg_temp.ok((select status = 'in_progress' from public.rooms where id = (select room_id from A)), '미등장 적군(늑대)이 있으면 승리 아님');
select pg_temp.ok((select count(*) = 0 from public.pending_attacks where room_id = (select room_id from A)
                     and declared_phase_id = (select response_to_phase_id from pg_temp.cur_phase((select room_id from A)))
                     and enemy_id = pg_temp.eid('허수아비')), '사망한 적군은 이후 공격 선언도 하지 않음');

select public.admin_appear_enemy((select adm from A), (select room_id from A), pg_temp.eid('늑대'));
select pg_temp.ok((select phase_number = 4 and acting_side = 'players' from pg_temp.cur_phase((select room_id from A))), '2사이클 4단계 (플레이어 반응턴)');
-- 기사(10)가 먼저 제출해 늑대(HP 10)를 쓰러뜨림 → 도적의 공격은 무효
select public.submit_action('00000000-0000-0000-0000-000000000041', (select room_id from A),
  json_build_object('action_type','attack','target_id',pg_temp.eid('늑대'))::jsonb);
select public.submit_action('00000000-0000-0000-0000-000000000042', (select room_id from A),
  json_build_object('action_type','attack','target_id',pg_temp.eid('늑대'))::jsonb);
select public.admin_resolve_now((select adm from A), (select room_id from A));
select pg_temp.reveal((select room_id from A));
select pg_temp.ok((select status = 'ended' and result = 'victory' and archive_status in ('pending', 'saved') from public.rooms where id = (select room_id from A)),
  '모든 적군 등장 + 사망 → 승리, 기록 저장 대기');
select pg_temp.ok((select count(*) = 1 from public.battle_logs where room_id = (select room_id from A) and log_type = 'action_invalid'
                     and content like '%이미 전장에 없어 무효%'), '이미 쓰러진 대상에 대한 두 번째 공격은 무효 처리');
select pg_temp.ok((select count(*) = 0 from public.battle_phases where room_id = (select room_id from A) and status = 'open'), '종료 후 남은 단계 없음');
select pg_temp.ok((select count(*) = 1 from public.battle_events where room_id = (select room_id from A) and event_type = 'battle_ended'), '종료 이벤트 1회');
select pg_temp.ok(public.end_battle((select room_id from A), 'forced', 'x') = false, '종료 중복 처리 방지');
select pg_temp.ok(public.battle_tick() = 0, '종료된 전투는 더 이상 판정하지 않음');
select pg_temp.expect_error(format($$select public.submit_action('00000000-0000-0000-0000-000000000041',%L,'{"action_type":"dodge"}')$$,
  (select room_id from A)), '이미 종료된 전투');
select pg_temp.expect_error(format($$select public.admin_end_battle(%L,%L,'x')$$, (select adm from A), (select room_id from A)), '이미 종료된');
select pg_temp.ok((select total_damage_dealt > 0 from public.players where display_name = '기사'), '누적 피해량 기록');

-- =====================================================================
-- 시나리오 B: 적군 선공 → 도주 성공 + 사망 → 패배
-- =====================================================================
create temp table B as
  select (r->>'id')::uuid as room_id, r->>'room_code' as code
  from (select public.admin_create_room('00000000-0000-0000-0000-0000000004a1', 'B방', '', null, 10, 300) r) x;
select public.join_room('00000000-0000-0000-0000-000000000043', (select code from B), '겁쟁이', null);
select public.join_room('00000000-0000-0000-0000-000000000044', (select code from B), '약골', null);
select public.admin_update_player('00000000-0000-0000-0000-0000000004a1', (select room_id from B), pg_temp.pid('겁쟁이'), '{"escape_rate":100}');
select public.admin_update_player('00000000-0000-0000-0000-0000000004a1', (select room_id from B), pg_temp.pid('약골'),
  '{"max_hp":5,"current_hp":5,"dodge_rate":0}');
select public.admin_save_enemy('00000000-0000-0000-0000-0000000004a1', (select room_id from B), null,
  '{"name":"오우거","max_hp":100,"min_attack":10,"max_attack":10,"target_type":"all"}');
select public.admin_appear_enemy('00000000-0000-0000-0000-0000000004a1', (select room_id from B), pg_temp.eid('오우거'));
select public.admin_update_room_settings('00000000-0000-0000-0000-0000000004a1', (select room_id from B), '{"first_side":"enemies"}');
select public.admin_start_battle('00000000-0000-0000-0000-0000000004a1', (select room_id from B));
select pg_temp.ok((select phase_number = 2 and acting_side = 'players' and phase_type = 'reaction'
                     and ends_at > now() + interval '290 seconds' from pg_temp.cur_phase((select room_id from B))),
  '적군 선공: 1단계(적 선공턴) 즉시 판정 → 2단계 플레이어 반응턴 (5분)');
select pg_temp.ok((select count(*) = 2 from public.pending_attacks where room_id = (select room_id from B) and status = 'pending'), '적 선공턴 공격 선언 2건');
select public.submit_action('00000000-0000-0000-0000-000000000043', (select room_id from B), '{"action_type":"escape"}');
select public.admin_resolve_now('00000000-0000-0000-0000-0000000004a1', (select room_id from B));
select pg_temp.ok((select status = 'alive' from public.players where display_name = '겁쟁이'), '도주도 결과 공개 전에는 미확정');
select pg_temp.reveal((select room_id from B));
select pg_temp.ok((select status = 'escaped' from public.players where display_name = '겁쟁이'), '도주 성공 → 이탈');
select pg_temp.ok((select status = 'cancelled' from public.pending_attacks where target_player_id = pg_temp.pid('겁쟁이')), '도주한 플레이어에 대한 공격 취소');
select pg_temp.ok((select status = 'dead' and current_hp = 0 from public.players where display_name = '약골'), '약골 사망 (HP 5 - 10 → 0)');
select pg_temp.ok((select status = 'ended' and result = 'defeat' from public.rooms where id = (select room_id from B)), '생존자 0명 → 패배');

-- =====================================================================
-- 시나리오 C: 전원 도주 / 관리자 HP 0 → 패배 / 강제 종료
-- =====================================================================
create temp table C as
  select (public.admin_create_room('00000000-0000-0000-0000-0000000004a1', 'C방', '', null, 10, 180)->>'room_code') as code;
create temp table C2 as select id as room_id from public.rooms where room_code = (select code from C);
select public.join_room('00000000-0000-0000-0000-000000000045', (select code from C), '혼자', null);
select public.admin_update_player('00000000-0000-0000-0000-0000000004a1', (select room_id from C2), pg_temp.pid('혼자'), '{"escape_rate":100}');
select public.admin_save_enemy('00000000-0000-0000-0000-0000000004a1', (select room_id from C2), null, '{"name":"유령"}');
select public.admin_update_room_settings('00000000-0000-0000-0000-0000000004a1', (select room_id from C2), '{"first_side":"players"}');
select public.admin_start_battle('00000000-0000-0000-0000-0000000004a1', (select room_id from C2));
select public.submit_action('00000000-0000-0000-0000-000000000045', (select room_id from C2), '{"action_type":"escape"}');
select pg_temp.expect_error(format($$select public.leave_room('00000000-0000-0000-0000-000000000045',%L)$$, (select room_id from C2)), '전투 중에는 퇴장');
select pg_temp.expire((select room_id from C2));
select public.room_tick('00000000-0000-0000-0000-000000000045', (select room_id from C2));
select pg_temp.reveal((select room_id from C2));
select pg_temp.ok((select result = 'all_escaped' from public.rooms where id = (select room_id from C2)), '전원 도주 → 전투 종료 (all_escaped)');

create temp table D as
  select (public.admin_create_room('00000000-0000-0000-0000-0000000004a1', 'D방', '', null, 10, 180)->>'room_code') as code;
create temp table D2 as select id as room_id from public.rooms where room_code = (select code from D);
select public.join_room('00000000-0000-0000-0000-000000000046', (select code from D), '불운', null);
select public.admin_save_enemy('00000000-0000-0000-0000-0000000004a1', (select room_id from D2), null, '{"name":"그림자"}');
select public.admin_update_room_settings('00000000-0000-0000-0000-0000000004a1', (select room_id from D2), '{"first_side":"players"}');
select public.admin_start_battle('00000000-0000-0000-0000-0000000004a1', (select room_id from D2));
select pg_temp.expect_error(format($$select public.admin_end_battle(%L,%L,%L)$$, '00000000-0000-0000-0000-0000000004a1',
  (select room_id from D2), repeat('가', 201)), '200자');
select public.admin_end_battle('00000000-0000-0000-0000-0000000004a1', (select room_id from D2), '시간 관계상 종료');
select pg_temp.ok((select result = 'forced' and end_reason = '시간 관계상 종료' from public.rooms where id = (select room_id from D2)), '강제 종료 + 사유 기록');
select pg_temp.ok((select event_message like '%시간 관계상 종료%' from public.battle_events where room_id = (select room_id from D2) and event_type = 'battle_ended'),
  '강제 종료 사유가 시스템 메시지에 표시');
select pg_temp.ok((select status = 'aborted' from public.battle_phases where room_id = (select room_id from D2)), '진행 중이던 단계는 중단(aborted)');
select pg_temp.expect_error(format($$select public.admin_appear_enemy(%L,%L,%L)$$, '00000000-0000-0000-0000-0000000004a1',
  (select room_id from D2), pg_temp.eid('그림자')), '전투가 종료되어');

-- 조사 처리
select pg_temp.ok(public.josa('용사A', '이', '가') = '가' and public.josa('Bob', '을', '를') = '을'
              and public.josa('Sam', '이', '가') = '이' and public.josa('3번', '이', '가') = '이'
              and public.josa('No.7', '이', '가') = '이' and public.josa('고블린', '이', '가') = '이'
              and public.josa('Bob', '이', '가') = '이' and public.josa('Peter', '이', '가') = '가', '조사: 한글/영문/숫자 이름');

-- =====================================================================
-- 시나리오 E: 결과 공개 대기 중 강제 종료 → 대기 중인 결과 공개 취소
-- =====================================================================
insert into auth.users (id) values ('00000000-0000-0000-0000-000000000047');
create temp table E5 as select (r->>'id')::uuid as room_id, r->>'room_code' as code
  from (select public.admin_create_room('00000000-0000-0000-0000-0000000004a1', 'E방', '', null, 10, 180) r) x;
select public.join_room('00000000-0000-0000-0000-000000000047', (select code from E5), '대기자', null);
select public.admin_save_enemy('00000000-0000-0000-0000-0000000004a1', (select room_id from E5), null, '{"name":"표적","max_hp":50}');
select public.admin_appear_enemy('00000000-0000-0000-0000-0000000004a1', (select room_id from E5), (select id from public.enemies where name = '표적'));
select public.admin_update_room_settings('00000000-0000-0000-0000-0000000004a1', (select room_id from E5), '{"first_side":"players"}');
select public.admin_start_battle('00000000-0000-0000-0000-0000000004a1', (select room_id from E5));
select public.submit_action('00000000-0000-0000-0000-000000000047', (select room_id from E5),
  json_build_object('action_type','attack','target_id',(select id from public.enemies where name = '표적'))::jsonb);
select public.admin_resolve_now('00000000-0000-0000-0000-0000000004a1', (select room_id from E5));
select pg_temp.ok((select status = 'declared' and reveal_at is not null from pg_temp.cur_phase((select room_id from E5))), '결과 공개 대기 중');
select public.admin_end_battle('00000000-0000-0000-0000-0000000004a1', (select room_id from E5), '중단');
update public.battle_phases set reveal_at = now() - interval '1 second' where room_id = (select room_id from E5);
select public.battle_tick();
select pg_temp.ok((select current_hp = 50 from public.enemies where name = '표적')
              and (select count(*) = 0 from public.battle_logs where room_id = (select room_id from E5) and stage = 'result')
              and (select count(*) = 0 from public.battle_phases where room_id = (select room_id from E5) and status in ('open', 'declared')),
  '강제 종료 시 대기 중인 결과 공개는 취소 (판정하지 않음)');
