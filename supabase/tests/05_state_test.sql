-- 5: get_room_state 공개 범위 테스트
create or replace function pg_temp.ok(p_cond boolean, p_name text)
returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'ok  - %', p_name;
end $$;

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000005a1'),
  ('00000000-0000-0000-0000-000000000051'), ('00000000-0000-0000-0000-000000000052'), ('00000000-0000-0000-0000-000000000053');
select public.register_admin('00000000-0000-0000-0000-0000000005a1');
create temp table S as select (r->>'id')::uuid as room_id, r->>'room_code' as code
  from (select public.admin_create_room('00000000-0000-0000-0000-0000000005a1', '상태방', '', 'pw12', 10, 180) r) x;
select public.join_room('00000000-0000-0000-0000-000000000051', (select code from S), '하나', 'pw12');
select public.join_room('00000000-0000-0000-0000-000000000052', (select code from S), '둘', 'pw12');
select public.join_room('00000000-0000-0000-0000-000000000053', (select code from S), '셋', 'pw12');
select public.admin_kick_member('00000000-0000-0000-0000-0000000005a1', (select room_id from S),
  (select id from public.room_members where nickname = '셋'));
select public.admin_save_enemy('00000000-0000-0000-0000-0000000005a1', (select room_id from S), null, '{"name":"보이는 적","target_type":"random"}');
select public.admin_save_enemy('00000000-0000-0000-0000-0000000005a1', (select room_id from S), null, '{"name":"숨은 적","appearance_message":"비밀 문구"}');
select public.admin_appear_enemy('00000000-0000-0000-0000-0000000005a1', (select room_id from S), (select id from public.enemies where name = '보이는 적'));
select public.admin_update_room_settings('00000000-0000-0000-0000-0000000005a1', (select room_id from S), '{"first_side":"players"}');
select public.admin_start_battle('00000000-0000-0000-0000-0000000005a1', (select room_id from S));
select public.submit_action('00000000-0000-0000-0000-000000000051', (select room_id from S),
  json_build_object('action_type','attack','target_id',(select id from public.enemies where name = '보이는 적'))::jsonb);
select public.submit_action('00000000-0000-0000-0000-000000000052', (select room_id from S), '{"action_type":"escape"}');

create temp table G as select public.get_room_state('00000000-0000-0000-0000-000000000051', (select room_id from S)) as s;
create temp table AD as select public.get_room_state('00000000-0000-0000-0000-0000000005a1', (select room_id from S)) as s;

select pg_temp.ok((select s->>'viewer' = 'guest' and s->'room'->>'status' = 'in_progress' from G), '게스트 상태 조회');
select pg_temp.ok((select jsonb_array_length(s->'enemies') = 1 and s::text not like '%숨은 적%' from G), '게스트: 미등장 적군 이름조차 없음');
select pg_temp.ok((select s->'myAction'->>'action_type' = 'attack' from G), '게스트: 내 행동 보임');
select pg_temp.ok((select s::text not like '%"escape"%' from G), '게스트: 다른 플레이어의 행동(도망) 정보 없음');
select pg_temp.ok((select jsonb_array_length(s->'submissions') = 2 from G), '게스트: 제출 여부 2명');
select pg_temp.ok((select jsonb_array_length(s->'members') = 2 from G), '게스트: 활성 참가자만 (강퇴자 제외)');
select pg_temp.ok((select s->'players'->1 ? 'min_attack' = false and s->'players'->0 ? 'min_attack' from G), '게스트: 본인만 세부 능력치');
select pg_temp.ok((select s::text not like '%user_id%' and s::text not like '%password_hash%' and s::text not like '%$2a$%' from G), '사용자 ID·비밀번호 정보 없음');
select pg_temp.ok((select s->>'viewer' = 'admin' and jsonb_array_length(s->'enemies') = 2 and jsonb_array_length(s->'members') = 3 from AD),
  '관리자: 미등장 적군·강퇴자 포함');
select pg_temp.ok((select s->'myAction' = 'null'::jsonb and s::text not like '%"escape"%' and s::text not like '%"attack"%' from AD),
  '관리자: 판정 전 행동 종류 없음');
select pg_temp.ok((select public.get_room_state('00000000-0000-0000-0000-000000000053', (select room_id from S))->>'error' = 'kicked'), '강퇴자 거부');
select pg_temp.ok((select public.get_room_state('00000000-0000-0000-0000-000000000051', gen_random_uuid())->>'error' = 'not_found'), '없는 방');
