-- 2단계 테스트: 관리자 / 방 생성 / 입장 / 인원 제한 / 퇴장 / 강퇴 / 삭제 / RLS
\set QUIET on

-- 테스트 도우미: SQL을 실행해서 특정 오류 메시지가 나오는지 확인
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

-- 테스트용 사용자
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000a1'),  -- 관리자
  ('00000000-0000-0000-0000-000000000001'),  -- 게스트1
  ('00000000-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-000000000003'),
  ('00000000-0000-0000-0000-000000000004');

-- 관리자가 아니면 방 생성 불가
select pg_temp.expect_error(
  $$select public.admin_create_room('00000000-0000-0000-0000-000000000001','방','',null,10,180)$$,
  '관리자 권한');

select public.register_admin('00000000-0000-0000-0000-0000000000a1');
select public.register_admin('00000000-0000-0000-0000-0000000000a1'); -- 중복 등록해도 오류 없음

-- 잘못된 입력 검증
select pg_temp.expect_error(
  $$select public.admin_create_room('00000000-0000-0000-0000-0000000000a1','방','',null,10,200)$$, '3분, 5분, 7분');
select pg_temp.expect_error(
  $$select public.admin_create_room('00000000-0000-0000-0000-0000000000a1','방','',null,11,180)$$, '1~10명');
select pg_temp.expect_error(
  $$select public.admin_create_room('00000000-0000-0000-0000-0000000000a1','  ','',null,10,180)$$, '1~50자');

-- 비밀번호 있는 방 (최대 2명)
create temp table t_room as
  select public.admin_create_room('00000000-0000-0000-0000-0000000000a1',
         '시험의 방', '테스트', 'secret123', 2, 300) as r;
select pg_temp.ok((select (r->>'room_code') ~ '^[A-Z2-9]{6}$' from t_room), '방 코드 6자리 발급');
select pg_temp.ok((select has_password from public.rooms), 'has_password = true');
select pg_temp.ok((select password_hash <> 'secret123' from public.room_secrets), '비밀번호는 해시로 저장');

create temp table t as select (r->>'id')::uuid as room_id, r->>'room_code' as code from t_room;

-- 잘못된 코드 / 비밀번호
select pg_temp.expect_error(
  $$select public.join_room('00000000-0000-0000-0000-000000000001','ZZZZZZ','A','secret123')$$, '존재하지 않는 방 코드');
select pg_temp.expect_error(
  format($$select public.join_room('00000000-0000-0000-0000-000000000001',%L,'A','wrong')$$, (select code from t)),
  '비밀번호가 올바르지 않습니다');

-- 정상 입장 (소문자 코드도 허용)
select pg_temp.ok(
  (select (public.join_room('00000000-0000-0000-0000-000000000001', lower((select code from t)), ' 용사A ', 'secret123')->>'restored')::boolean = false),
  '게스트1 입장');
select pg_temp.ok((select nickname = '용사A' from public.room_members where user_id = '00000000-0000-0000-0000-000000000001'),
  '닉네임 앞뒤 공백 제거');
select pg_temp.ok((select count(*) = 1 from public.players), '입장 시 캐릭터 자동 생성');
select pg_temp.ok((select max_hp = 100 and min_attack = 5 and max_attack = 10 and dodge_rate = 30 and escape_rate = 20
                   from public.players), '기본 능력치');

-- 같은 사용자가 다시 입장 → 기존 캐릭터 복구 (중복 캐릭터 금지)
select pg_temp.ok(
  (select (public.join_room('00000000-0000-0000-0000-000000000001', (select code from t), '다른이름', 'secret123')->>'restored')::boolean),
  '재접속 시 기존 참가자 복구');
select pg_temp.ok((select count(*) = 1 from public.room_members), '중복 참여 방지 (참가자 1명 유지)');

-- 닉네임 중복 (대소문자 무시)
select public.join_room('00000000-0000-0000-0000-000000000001', (select code from t), 'x', 'secret123');
select pg_temp.expect_error(
  format($$select public.join_room('00000000-0000-0000-0000-000000000002',%L,'용사A','secret123')$$, (select code from t)),
  '이미 사용 중인 닉네임');

select public.join_room('00000000-0000-0000-0000-000000000002', (select code from t), 'Bob', 'secret123');

-- 인원 초과 (최대 2명)
select pg_temp.expect_error(
  format($$select public.join_room('00000000-0000-0000-0000-000000000003',%L,'bob2','secret123')$$, (select code from t)),
  '인원이 가득');

-- 게스트1 퇴장 → 게스트3 입장 가능
select public.leave_room('00000000-0000-0000-0000-000000000001', (select room_id from t));
select pg_temp.expect_error(
  format($$select public.leave_room('00000000-0000-0000-0000-000000000001', %L)$$, (select room_id from t)),
  '참가 중인 방이 아닙니다');
select public.join_room('00000000-0000-0000-0000-000000000003', (select code from t), 'Carol', 'secret123');

-- 게스트1 재입장 → 인원 초과
select pg_temp.expect_error(
  format($$select public.join_room('00000000-0000-0000-0000-000000000001',%L,'',%L)$$, (select code from t), 'secret123'),
  '인원이 가득');

-- 강퇴: 비관리자는 불가, 관리자는 가능, 강퇴된 사람은 재입장 불가
select pg_temp.expect_error(
  format($$select public.admin_kick_member('00000000-0000-0000-0000-000000000002', %L, %L)$$,
         (select room_id from t),
         (select id from public.room_members where user_id = '00000000-0000-0000-0000-000000000003')),
  '관리자 권한');
select public.admin_kick_member('00000000-0000-0000-0000-0000000000a1', (select room_id from t),
       (select id from public.room_members where user_id = '00000000-0000-0000-0000-000000000003'));
select pg_temp.expect_error(
  format($$select public.join_room('00000000-0000-0000-0000-000000000003',%L,'Carol',%L)$$, (select code from t), 'secret123'),
  '강퇴');

-- 게스트1 재입장 → 기존 캐릭터 복구
create temp table t_p1 as select p.id from public.players p join public.room_members m on m.id = p.member_id
  where m.user_id = '00000000-0000-0000-0000-000000000001';
select pg_temp.ok(
  (select (public.join_room('00000000-0000-0000-0000-000000000001', (select code from t), '', 'secret123')->>'restored')::boolean),
  '나갔던 참가자 재입장');
select pg_temp.ok((select count(*) = 1 from public.players p join public.room_members m on m.id = p.member_id
                   where m.user_id = '00000000-0000-0000-0000-000000000001' and p.id = (select id from t_p1)),
  '재입장 시 같은 캐릭터 유지');

-- =====================================================================
-- RLS 테스트 (브라우저 = authenticated 역할)
-- =====================================================================
-- 다른 방 하나 더 + 적군/행동 테스트 데이터
create temp table t2 as select (public.admin_create_room('00000000-0000-0000-0000-0000000000a1','다른 방','',null,10,180)->>'id')::uuid as room_id;
insert into public.enemies (room_id, name) values ((select room_id from t), '숨은 적');
insert into public.enemies (room_id, name, appearance_status) values ((select room_id from t), '등장한 적', 'appeared');
insert into public.battle_cycles (room_id, cycle_number) values ((select room_id from t), 1);
insert into public.battle_phases (room_id, cycle_id, cycle_number, phase_number, phase_type, acting_side)
  select (select room_id from t), id, 1, 1, 'turn', 'players' from public.battle_cycles;
insert into public.actions (room_id, phase_id, player_id, action_type)
  select (select room_id from t), (select id from public.battle_phases), p.id, 'dodge'
  from public.players p join public.room_members m on m.id = p.member_id where m.status = 'active';

grant select on t, t2 to authenticated;

-- 게스트1 시점
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
select pg_temp.ok((select count(*) = 1 from public.rooms), 'RLS: 게스트는 자기 방만 보임');
select pg_temp.ok((select count(*) = 0 from public.room_secrets), 'RLS: 비밀번호 해시 조회 불가');
select pg_temp.ok((select count(*) = 1 from public.enemies), 'RLS: 게스트는 등장한 적군만 보임');
select pg_temp.ok((select count(*) = 1 from public.actions), 'RLS: 게스트는 자기 행동만 보임');
select pg_temp.ok((select count(*) = 0 from public.admins), 'RLS: 관리자 목록 조회 불가');
select pg_temp.ok((select count(*) = 0 from public.battle_archives), 'RLS: 기록 보관함 조회 불가');
select pg_temp.expect_error($$insert into public.chat_messages (room_id, sender_id, sender_role, nickname, message)
  select room_id, auth.uid(), 'guest', 'x', 'hack' from t$$, 'row-level security');
update public.players set current_hp = 9999;  -- RLS: 수정 정책이 없으므로 0행 수정
select pg_temp.ok((select count(*) = 0 from public.players where current_hp = 9999), 'RLS: HP 직접 수정 불가');
select pg_temp.expect_error($$select public.admin_create_room(auth.uid(),'x','',null,10,180)$$, 'permission denied');
select pg_temp.expect_error($$select public.join_room(auth.uid(),'x','x',null)$$, 'permission denied');

-- 강퇴된 게스트3 시점: 방 데이터 못 봄, 자기 참가 기록만 봄
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', false);
select pg_temp.ok((select count(*) = 0 from public.rooms), 'RLS: 강퇴된 사용자는 방 조회 불가');
select pg_temp.ok((select count(*) = 1 from public.room_members), 'RLS: 강퇴된 사용자는 자기 참가 기록만 조회');

-- 관리자 시점: 모든 방, 숨은 적 보임, 하지만 행동은 못 봄
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', false);
select pg_temp.ok((select count(*) = 2 from public.rooms), 'RLS: 관리자는 모든 방 조회');
select pg_temp.ok((select count(*) = 2 from public.enemies), 'RLS: 관리자는 미등장 적군도 조회');
select pg_temp.ok((select count(*) = 2 from public.actions), 'RLS: 관리자는 판정 전 행동 조회 가능 (v2 요청서 8-4)');

-- 로그인 안 한 사용자
reset role;
set role anon;
select pg_temp.expect_error($$select count(*) from public.rooms$$, 'permission denied');
reset role;
select set_config('request.jwt.claim.sub', '', false);

-- =====================================================================
-- 삭제: 진행 중이면 불가 / 삭제해도 기록 보관함 유지
-- =====================================================================
update public.rooms set status = 'in_progress' where id = (select room_id from t);
select pg_temp.expect_error(
  format($$select public.join_room('00000000-0000-0000-0000-000000000004',%L,'Dan','secret123')$$, (select code from t)),
  '새로 입장할 수 없습니다');
select pg_temp.ok(
  (select (public.join_room('00000000-0000-0000-0000-000000000002', (select code from t), '', 'secret123')->>'restored')::boolean),
  '전투 중에도 기존 참가자 재접속 가능');
select pg_temp.expect_error(
  format($$select public.admin_delete_room('00000000-0000-0000-0000-0000000000a1', %L)$$, (select room_id from t)),
  '진행 중인 전투방은 삭제할 수 없습니다');
select pg_temp.expect_error(
  format($$select public.leave_room('00000000-0000-0000-0000-000000000002', %L)$$, (select room_id from t)),
  '전투 중에는 퇴장할 수 없습니다');

update public.rooms set status = 'ended' where id = (select room_id from t);
insert into public.battle_results (room_id, result) values ((select room_id from t), 'victory');
insert into public.battle_archives (room_id, battle_result_id, room_name_snapshot, result)
  select (select room_id from t), id, '시험의 방', 'victory' from public.battle_results;
select public.admin_delete_room('00000000-0000-0000-0000-0000000000a1', (select room_id from t));
select pg_temp.ok((select count(*) = 0 from public.rooms where id = (select room_id from t)), '방 삭제');
select pg_temp.ok((select count(*) = 0 from public.players), '방 삭제 시 캐릭터도 삭제');
select pg_temp.ok((select count(*) = 1 from public.battle_archives), '방을 삭제해도 전투 기록은 유지');
