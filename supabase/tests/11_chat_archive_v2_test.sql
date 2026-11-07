-- v2 5단계 테스트: 채팅 이름·색 / 기록 보관 보강
create or replace function pg_temp.ok(p_cond boolean, p_name text)
returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'ok  - %', p_name;
end $$;
create or replace function pg_temp.reveal(p_room uuid) returns int language plpgsql as $$
begin
  update public.battle_phases set reveal_at = now() - interval '1 second'
   where id = (select current_phase_id from public.rooms where id = p_room) and status = 'declared';
  return public.battle_tick();
end $$;

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000011a1'), ('00000000-0000-0000-0000-000000000111');
select public.register_admin('00000000-0000-0000-0000-0000000011a1');
create temp table K as select (r->>'id')::uuid as room_id, r->>'room_code' as code
  from (select public.admin_create_room('00000000-0000-0000-0000-0000000011a1', '기록방2', '', null, 10, 180) r) x;
select public.join_room('00000000-0000-0000-0000-000000000111', (select code from K), 'kim', null);
select public.admin_set_profile_fields('00000000-0000-0000-0000-0000000011a1', (select room_id from K), '["직업"]');
select public.update_my_profile('00000000-0000-0000-0000-000000000111', (select room_id from K),
  jsonb_build_object('display_name', '불꽃 마법사', 'name_color', '#ff8a80', 'bio', '불을 다룬다',
                     'profile_extra', jsonb_build_object((select profile_fields->0->>'key' from public.rooms where id = (select room_id from K)), '마법사')));

-- 채팅: 캐릭터 이름 + 색
select public.send_chat('00000000-0000-0000-0000-000000000111', (select room_id from K), '준비됐어!');
select public.send_chat('00000000-0000-0000-0000-0000000011a1', (select room_id from K), '어둠이 내려앉는다…');
create temp table H as select public.get_room_history('00000000-0000-0000-0000-000000000111', (select room_id from K), 'chat', null, 50) as h;
select pg_temp.ok((select h->'items'->0->>'nickname' = '불꽃 마법사' and h->'items'->0->>'name_color' = '#ff8a80' from H), '채팅에 캐릭터 이름 + 이름 색');
select pg_temp.ok((select h->'items'->1->>'sender_role' = 'admin' and h->'items'->1->>'name_color' is null from H), '관리자 메시지 구분 (역할 admin)');
create temp table X as select (public.send_chat('00000000-0000-0000-0000-000000000111', (select room_id from K), '나쁜 말')->>'id')::bigint as id;
select public.admin_hide_chat('00000000-0000-0000-0000-0000000011a1', (select room_id from K), (select id from X), true);

-- 전투 → 종료 → 기록
select public.admin_save_enemy('00000000-0000-0000-0000-0000000011a1', (select room_id from K), null, '{"name":"슬라임","max_hp":1}');
select public.admin_appear_enemy('00000000-0000-0000-0000-0000000011a1', (select room_id from K), (select id from public.enemies where name = '슬라임' and room_id = (select room_id from K)));
select public.admin_update_room_settings('00000000-0000-0000-0000-0000000011a1', (select room_id from K), '{"first_side":"players"}');
select public.admin_start_battle('00000000-0000-0000-0000-0000000011a1', (select room_id from K));
select public.admin_update_profile('00000000-0000-0000-0000-0000000011a1', (select room_id from K),
  (select p.id from public.players p where p.room_id = (select room_id from K)), '{"appearance":"붉은 로브"}');
select public.submit_action('00000000-0000-0000-0000-000000000111', (select room_id from K),
  json_build_object('action_type','attack','target_id',(select id from public.enemies where name = '슬라임' and room_id = (select room_id from K)))::jsonb);
select public.admin_resolve_now('00000000-0000-0000-0000-0000000011a1', (select room_id from K));
select pg_temp.reveal((select room_id from K));
select pg_temp.ok((select result = 'victory' and archive_status = 'saved' from public.rooms where id = (select room_id from K)), '승리 → 자동 저장');

create temp table AR as select archive_data d from public.battle_archives where room_id = (select room_id from K);
select pg_temp.ok((select (d->>'version')::int = 2 from AR), '기록 v2 형식');
select pg_temp.ok((select d->'players'->0->>'name_color' = '#ff8a80' and d->'players'->0->>'bio' = '불을 다룬다'
                     and d->'players'->0->>'appearance' = '붉은 로브' and d->'players'->0->>'profile_locked_at' is not null from AR),
  '참가자 프로필·이름 색·확정 시각 저장');
select pg_temp.ok((select jsonb_array_length(d->'profile_fields') = 1 and jsonb_array_length(d->'profile_history') = 2 from AR), '추가 항목 정의 + 프로필 수정 내역 저장');
select pg_temp.ok((select d->'logs' @> '[{"stage":"declare"}]' and d->'logs' @> '[{"stage":"result"}]' from AR), '로그에 행동 선언 / 판정 결과 구분 저장');
select pg_temp.ok((select (select c->>'message' from jsonb_array_elements(d->'chat') c where (c->>'hidden')::boolean) = '나쁜 말'
                     and d->'chat'->0->>'name_color' = '#ff8a80' from AR), '채팅: 이름 색 + 가린 메시지 원문 보관');
select pg_temp.ok((select count(*) = 1 from public.battle_archives where room_id = (select room_id from K)), '중복 저장 없음');
select pg_temp.ok(public.save_battle_archive((select room_id from K)) = 'already_saved', '재저장 요청 → 이미 저장됨');
