-- v2 3단계 테스트: 적군 퇴장·재등장 / 승리 조건 / 관리자 행동 열람 / 채팅 가리기
create or replace function pg_temp.expect_error(p_sql text, p_contains text)
returns void language plpgsql as $$
begin
  begin execute p_sql;
  exception when others then
    if position(p_contains in sqlerrm) = 0 then
      raise exception 'FAIL: 예상 오류 "%" 대신 "%" 발생 (sql: %)', p_contains, sqlerrm, p_sql;
    end if;
    raise notice 'ok  - 예상한 오류: %', sqlerrm; return;
  end;
  raise exception 'FAIL: 오류가 나야 하는데 성공함 (sql: %)', p_sql;
end $$;
create or replace function pg_temp.ok(p_cond boolean, p_name text)
returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'ok  - %', p_name;
end $$;

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000009a1'),
  ('00000000-0000-0000-0000-000000000091'), ('00000000-0000-0000-0000-000000000092');
select public.register_admin('00000000-0000-0000-0000-0000000009a1');
create temp table T as select (r->>'id')::uuid as room_id, r->>'room_code' as code, '00000000-0000-0000-0000-0000000009a1'::uuid as adm
  from (select public.admin_create_room('00000000-0000-0000-0000-0000000009a1', '도구방', '', null, 10, 180) r) x;
select public.join_room('00000000-0000-0000-0000-000000000091', (select code from T), '전사9', null);
select public.join_room('00000000-0000-0000-0000-000000000092', (select code from T), '궁수9', null);
create temp table E as select
  public.admin_save_enemy((select adm from T), (select room_id from T), null, '{"name":"도망자","max_hp":50}') as runner,
  public.admin_save_enemy((select adm from T), (select room_id from T), null, '{"name":"약골","max_hp":1,"min_attack":0,"max_attack":0}') as weak;
select public.admin_update_player((select adm from T), (select room_id from T),
  (select p.id from public.players p join public.room_members m on m.id = p.member_id where m.nickname = '전사9'), '{"min_attack":10,"max_attack":10}');

-- 퇴장은 등장한 적군만
select pg_temp.expect_error(format($$select public.admin_withdraw_enemy(%L,%L,%L)$$, (select adm from T), (select room_id from T), (select runner from E)), '전장에 나와 있는');
select public.admin_appear_enemy((select adm from T), (select room_id from T), (select runner from E));
select public.admin_appear_enemy((select adm from T), (select room_id from T), (select weak from E));
select public.admin_update_room_settings((select adm from T), (select room_id from T), '{"first_side":"players"}');
select public.admin_start_battle((select adm from T), (select room_id from T));

-- 관리자: 판정 전 행동 열람 / 게스트는 남의 행동 못 봄
select public.submit_action('00000000-0000-0000-0000-000000000091', (select room_id from T),
  json_build_object('action_type','attack','target_id',(select weak from E))::jsonb);
select public.submit_action('00000000-0000-0000-0000-000000000092', (select room_id from T), '{"action_type":"dodge"}');
select pg_temp.ok((select jsonb_array_length(s->'adminActions') = 2 and s->'adminActions' @> '[{"action_type":"attack"},{"action_type":"dodge"}]'
                   from (select public.get_room_state((select adm from T), (select room_id from T)) s) x), '관리자: 판정 전 행동 상세 확인');
select pg_temp.ok((select jsonb_array_length(s->'adminActions') = 0 and s::text not like '%"attack"%'
                   from (select public.get_room_state('00000000-0000-0000-0000-000000000092', (select room_id from T)) s) x), '게스트: 남의 행동 비공개');
grant select on T to authenticated;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000009a1', false);
select pg_temp.ok((select count(*) = 2 from public.actions where room_id = (select room_id from T)), 'RLS: 관리자는 행동 조회 가능');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000092', false);
select pg_temp.ok((select count(*) = 1 from public.actions where room_id = (select room_id from T)), 'RLS: 게스트는 자기 행동만');
reset role;

-- 퇴장: 상태·이벤트·로그, 퇴장한 적군 공격 불가
select public.admin_withdraw_enemy((select adm from T), (select room_id from T), (select runner from E));
select pg_temp.ok((select status = 'withdrawn' from public.enemies where id = (select runner from E)), '적군 퇴장');
select pg_temp.ok((select count(*) = 1 from public.battle_events where room_id = (select room_id from T) and event_type = 'enemy_withdrawn' and event_message like '도망자가 전장에서 물러났다.')
              and (select count(*) = 1 from public.battle_logs where room_id = (select room_id from T) and log_type = 'enemy_withdrawn'), '퇴장 시스템 메시지 + 로그');
select pg_temp.expect_error(format($$select public.admin_withdraw_enemy(%L,%L,%L)$$, (select adm from T), (select room_id from T), (select runner from E)), '전장에 나와 있는');
select pg_temp.ok((select status = 'in_progress' from public.rooms where id = (select room_id from T)), '아무도 쓰러뜨리지 않았으면 퇴장만으로 종료되지 않음');

-- 재등장
select public.admin_appear_enemy((select adm from T), (select room_id from T), (select runner from E));
select pg_temp.ok((select status = 'alive' and appearance_order = 1 from public.enemies where id = (select runner from E))
              and (select count(*) = 1 from public.battle_events where room_id = (select room_id from T) and event_message like '%다시 모습을 드러냈다%'), '퇴장한 적군 재등장 (등장 순서 유지)');
select public.admin_withdraw_enemy((select adm from T), (select room_id from T), (select runner from E));

-- 약골 처치 → 남은 적군은 퇴장 상태뿐 → 승리
select public.admin_resolve_now((select adm from T), (select room_id from T));
select pg_temp.ok((select result = 'victory' from public.rooms where id = (select room_id from T)), '쓰러뜨린 적 + 퇴장한 적만 남으면 승리');

-- 채팅 가리기
update public.rooms set status = 'waiting' where id = (select room_id from T);  -- 채팅 가능한 상태로 (테스트용)
create temp table CM2 as select (public.send_chat('00000000-0000-0000-0000-000000000092', (select room_id from T), '부적절한 말')->>'id')::bigint as id;
select pg_temp.expect_error(format($$select public.admin_hide_chat(%L,%L,%s,true)$$, '00000000-0000-0000-0000-000000000091', (select room_id from T), (select id from CM2)), '관리자 권한');
select public.admin_hide_chat((select adm from T), (select room_id from T), (select id from CM2), true);
select pg_temp.ok((select message = '(관리자가 가린 메시지)' and hidden_at is not null from public.chat_messages where id = (select id from CM2)), '가린 메시지는 채팅 테이블에 원문이 남지 않음');
select pg_temp.ok((select h->'items'->-1->>'original' is null and (h->'items'->-1->>'hidden')::boolean
                   from (select public.get_room_history('00000000-0000-0000-0000-000000000091', (select room_id from T), 'chat', null, 50) h) x), '참가자: 가려진 표시만, 원문 없음');
select pg_temp.ok((select h->'items'->-1->>'original' = '부적절한 말'
                   from (select public.get_room_history((select adm from T), (select room_id from T), 'chat', null, 50) h) x), '관리자: 원문 확인 가능');
grant select on CM2 to authenticated;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000091', false);
select pg_temp.ok((select count(*) = 0 from public.chat_moderation), 'RLS: 참가자는 원문 테이블 조회 불가');
reset role;
select public.admin_hide_chat((select adm from T), (select room_id from T), (select id from CM2), false);
select pg_temp.ok((select message = '부적절한 말' and hidden_at is null from public.chat_messages where id = (select id from CM2))
              and (select count(*) = 0 from public.chat_moderation where message_id = (select id from CM2)), '가리기 해제 시 원문 복구');
