-- 6단계 테스트: 채팅 전송 / 검증 / 스팸 방지 / 읽기 전용 / 기록 페이지 조회
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

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000006a1'),
  ('00000000-0000-0000-0000-000000000061'), ('00000000-0000-0000-0000-000000000062'), ('00000000-0000-0000-0000-000000000063');
select public.register_admin('00000000-0000-0000-0000-0000000006a1');
create temp table C as select (r->>'id')::uuid as room_id, r->>'room_code' as code
  from (select public.admin_create_room('00000000-0000-0000-0000-0000000006a1', '채팅방', '', null, 10, 180) r) x;
select public.join_room('00000000-0000-0000-0000-000000000061', (select code from C), '이야기꾼', null);
select public.join_room('00000000-0000-0000-0000-000000000062', (select code from C), '구경꾼', null);

-- 정상 전송
select public.send_chat('00000000-0000-0000-0000-0000000006a1', (select room_id from C), '숲이 고요하다…');
select public.send_chat('00000000-0000-0000-0000-000000000061', (select room_id from C), '  이번 턴에는 공격할게!  ');
select pg_temp.ok((select nickname = '관리자' and sender_role = 'admin' from public.chat_messages order by id limit 1), '관리자 메시지 (닉네임 관리자)');
select pg_temp.ok((select message = '이번 턴에는 공격할게!' and nickname = '이야기꾼' from public.chat_messages order by id desc limit 1), '게스트 메시지 (앞뒤 공백 제거)');

-- HTML/스크립트는 글자 그대로 저장 (화면은 텍스트로만 출력) + 보이지 않는 문자 제거
select public.send_chat('00000000-0000-0000-0000-000000000062', (select room_id from C), E'<script>alert(1)</script>‮​\n줄바꿈');
select pg_temp.ok((select message = '<script>alert(1)</script> 줄바꿈' from public.chat_messages order by id desc limit 1),
  '태그는 실행되지 않는 글자로 저장, 제어·방향 문자 제거, 줄바꿈→공백');

-- 검증
select pg_temp.expect_error(format($$select public.send_chat('00000000-0000-0000-0000-000000000061',%L,'   ')$$, (select room_id from C)), '메시지를 입력');
select pg_temp.expect_error(format($$select public.send_chat('00000000-0000-0000-0000-000000000061',%L,%L)$$, (select room_id from C), repeat('가', 301)), '300자');
select public.send_chat('00000000-0000-0000-0000-000000000061', (select room_id from C), repeat('나', 300));
select pg_temp.ok(true, '300자 정확히는 허용');
select pg_temp.expect_error(format($$select public.send_chat('00000000-0000-0000-0000-000000000063',%L,'안녕')$$, (select room_id from C)), '참가자가 아닙니다');
select pg_temp.expect_error(format($$select public.send_chat('00000000-0000-0000-0000-000000000061',%L,'이번 턴에는 공격할게!')$$, (select room_id from C)), '연속으로');

-- 스팸: 10초에 5개
select public.send_chat('00000000-0000-0000-0000-000000000061', (select room_id from C), '1');
select public.send_chat('00000000-0000-0000-0000-000000000061', (select room_id from C), '2');
select public.send_chat('00000000-0000-0000-0000-000000000061', (select room_id from C), '5번째 (허용)');
select pg_temp.expect_error(format($$select public.send_chat('00000000-0000-0000-0000-000000000061',%L,'3')$$, (select room_id from C)), '너무 빠르게');
select public.send_chat('00000000-0000-0000-0000-000000000062', (select room_id from C), '다른 사람은 보낼 수 있음');

-- 채팅은 행동 제출과 무관
select pg_temp.ok((select count(*) = 0 from public.actions where room_id = (select room_id from C)), '채팅은 행동 데이터에 영향 없음');

-- 기록 조회
select pg_temp.ok((select jsonb_array_length(public.get_room_history('00000000-0000-0000-0000-000000000061', (select room_id from C), 'chat', null, 200)->'items') = 8),
  '채팅 기록 조회');
select pg_temp.ok((select (h->'items'->0->>'is_mine')::boolean = false and (h->'items'->1->>'is_mine')::boolean = true
                     and h::text not like '%sender_id%'
                   from (select public.get_room_history('00000000-0000-0000-0000-000000000061', (select room_id from C), 'chat', null, 200) h) x),
  '내 메시지 표시(is_mine), 보낸 사람 ID는 숨김');
select pg_temp.ok((select (h->>'has_more')::boolean and jsonb_array_length(h->'items') = 3
                   from (select public.get_room_history('00000000-0000-0000-0000-000000000061', (select room_id from C), 'chat', null, 3) h) x),
  '페이지 단위 조회 (3개 + 더 있음)');
select pg_temp.ok((select jsonb_array_length(h->'items') = 2 and not (h->>'has_more')::boolean
                   from (select public.get_room_history('00000000-0000-0000-0000-000000000061', (select room_id from C), 'chat',
                           (select min(id) + 2 from public.chat_messages where room_id = (select room_id from C)), 50) h) x),
  '이전 기록 더 보기 (before 커서)');
select pg_temp.ok(public.get_room_history('00000000-0000-0000-0000-000000000063', (select room_id from C), 'chat', null, 10)->>'error' = 'not_member',
  '참가자가 아니면 기록 조회 불가');

-- 퇴장/강퇴 사용자 차단
select public.admin_kick_member('00000000-0000-0000-0000-0000000006a1', (select room_id from C),
  (select id from public.room_members where nickname = '구경꾼'));
select pg_temp.expect_error(format($$select public.send_chat('00000000-0000-0000-0000-000000000062',%L,'나 아직 있어')$$, (select room_id from C)), '강퇴된');

-- 전투 종료 → 읽기 전용 (조회는 가능)
update public.rooms set status = 'ended' where id = (select room_id from C);
select pg_temp.expect_error(format($$select public.send_chat('00000000-0000-0000-0000-0000000006a1',%L,'끝')$$, (select room_id from C)), '읽기 전용');
select pg_temp.ok((select jsonb_array_length(public.get_room_history('00000000-0000-0000-0000-000000000061', (select room_id from C), 'chat', null, 200)->'items') >= 8),
  '종료 후에도 채팅 기록 열람 가능');
