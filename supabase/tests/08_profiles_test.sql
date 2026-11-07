-- v2 2단계 테스트: 프로필 / 이름 색상 / 추가 항목 / 잠금 / 수정 내역 / 공개 범위
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

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000008a1'),
  ('00000000-0000-0000-0000-000000000081'), ('00000000-0000-0000-0000-000000000082');
select public.register_admin('00000000-0000-0000-0000-0000000008a1');
create temp table P as select (r->>'id')::uuid as room_id, r->>'room_code' as code
  from (select public.admin_create_room('00000000-0000-0000-0000-0000000008a1', '프로필방', '', null, 10, 180) r) x;
select public.join_room('00000000-0000-0000-0000-000000000081', (select code from P), '하나', null);
select public.join_room('00000000-0000-0000-0000-000000000082', (select code from P), '둘', null);
create temp table ids as select
  (select p.id from public.players p join public.room_members m on m.id = p.member_id where m.nickname = '하나' and p.room_id = (select room_id from P)) as p1,
  (select p.id from public.players p join public.room_members m on m.id = p.member_id where m.nickname = '둘' and p.room_id = (select room_id from P)) as p2;

-- 색상 목록은 모두 읽을 수 있는 색
select pg_temp.ok((select bool_and(public.name_color_readable(c)) from unnest(public.name_color_palette()) c), '기본 색상 12개 모두 가독성 기준 통과');
select pg_temp.ok((select name_color <> (select name_color from public.players where id = (select p2 from ids)) from public.players where id = (select p1 from ids)),
  '입장 순서대로 서로 다른 색 자동 배정');
select pg_temp.ok(not public.name_color_readable('#1a1a2e') and not public.name_color_readable('#333333') and public.name_color_readable('#ffffff'),
  '어두운 색 거부 / 밝은 색 허용');

-- 관리자 추가 항목
select pg_temp.expect_error(format($$select public.admin_set_profile_fields(%L,%L,'["a","b","c","d","e","f"]')$$,
  '00000000-0000-0000-0000-0000000008a1', (select room_id from P)), '최대 5개');
create temp table F as select public.admin_set_profile_fields('00000000-0000-0000-0000-0000000008a1', (select room_id from P), '["나이", "직업"]') as f;
select pg_temp.ok((select jsonb_array_length(f) = 2 and f->0->>'label' = '나이' and (f->0->>'key') ~ '^f[0-9a-f]{6}$' from F), '추가 항목 2개 (고유 키 발급)');
select pg_temp.expect_error(format($$select public.admin_set_profile_fields(%L,%L,'["x"]')$$,
  '00000000-0000-0000-0000-000000000081', (select room_id from P)), '관리자 권한');

-- 참가자 본인 프로필 수정
select public.update_my_profile('00000000-0000-0000-0000-000000000081', (select room_id from P),
  jsonb_build_object('display_name', '빛의 기사', 'bio', '왕국의 기사', 'appearance', '은빛 갑옷', 'name_color', '#FFD54F',
                     'profile_extra', jsonb_build_object((select f->0->>'key' from F), '27', 'hack', 'x'),
                     'max_hp', 99999, 'min_attack', 999));
select pg_temp.ok((select display_name = '빛의 기사' and bio = '왕국의 기사' and appearance = '은빛 갑옷' and name_color = '#ffd54f'
                     and profile_extra = jsonb_build_object((select f->0->>'key' from F), '27')
                   from public.players where id = (select p1 from ids)), '프로필 저장 (정의되지 않은 항목 무시, 색상 소문자 저장)');
select pg_temp.ok((select max_hp = 100 and min_attack = 5 from public.players where id = (select p1 from ids)), '프로필 요청에 능력치를 섞어도 능력치는 바뀌지 않음');
select pg_temp.ok((select count(*) = 1 and bool_and(changed_by = 'player') from public.profile_history where player_id = (select p1 from ids)),
  '수정 내역 기록');
select pg_temp.ok((select changes ? 'display_name' and changes ? 'name_color' and not changes ? 'max_hp' from public.profile_history where player_id = (select p1 from ids)),
  '바뀐 항목만 기록');
select public.update_my_profile('00000000-0000-0000-0000-000000000081', (select room_id from P), '{"bio":"왕국의 기사"}');
select pg_temp.ok((select count(*) = 1 from public.profile_history where player_id = (select p1 from ids)), '바뀐 것이 없으면 기록하지 않음');

select pg_temp.expect_error(format($$select public.update_my_profile(%L,%L,'{"name_color":"#202020"}')$$,
  '00000000-0000-0000-0000-000000000082', (select room_id from P)), '잘 보이지 않는');
select pg_temp.expect_error(format($$select public.update_my_profile(%L,%L,'{"name_color":"red"}')$$,
  '00000000-0000-0000-0000-000000000082', (select room_id from P)), '잘 보이지 않는');
select pg_temp.expect_error(format($$select public.update_my_profile(%L,%L,'{"display_name":"빛의 기사"}')$$,
  '00000000-0000-0000-0000-000000000082', (select room_id from P)), '같은 이름');
select pg_temp.expect_error(format($$select public.update_my_profile(%L,%L,%L)$$,
  '00000000-0000-0000-0000-000000000082', (select room_id from P), json_build_object('bio', repeat('가', 501))), '500자');

-- 상태 조회: 프로필은 모두에게 공개, 능력치는 본인/관리자만, 수정 내역은 관리자만
create temp table G as select public.get_room_state('00000000-0000-0000-0000-000000000082', (select room_id from P)) as s;
select pg_temp.ok((select (select x->>'bio' from jsonb_array_elements(s->'players') x where x->>'display_name' = '빛의 기사') = '왕국의 기사'
                     and (select x->>'name_color' from jsonb_array_elements(s->'players') x where x->>'display_name' = '빛의 기사') = '#ffd54f'
                     and (select not (x ? 'min_attack') from jsonb_array_elements(s->'players') x where x->>'display_name' = '빛의 기사')
                   from G), '다른 참가자에게 프로필·색상 공개, 능력치 비공개');
select pg_temp.ok((select jsonb_array_length(s->'profileHistory') = 0 and jsonb_array_length(s->'room'->'profile_fields') = 2 from G),
  '게스트: 수정 내역 비공개, 추가 항목 정의는 공개');
select pg_temp.ok((select jsonb_array_length(public.get_room_state('00000000-0000-0000-0000-0000000008a1', (select room_id from P))->'profileHistory') = 1),
  '관리자: 수정 내역 조회');

-- 전투 시작 → 잠금
select public.admin_save_enemy('00000000-0000-0000-0000-0000000008a1', (select room_id from P), null, '{"name":"허수아비"}');
select public.admin_update_room_settings('00000000-0000-0000-0000-0000000008a1', (select room_id from P), '{"first_side":"players"}');
select public.admin_start_battle('00000000-0000-0000-0000-0000000008a1', (select room_id from P));
select pg_temp.ok((select bool_and(profile_locked_at is not null) from public.players where room_id = (select room_id from P)), '전투 시작 시 모든 프로필 확정(잠금)');
select pg_temp.expect_error(format($$select public.update_my_profile(%L,%L,'{"bio":"수정"}')$$,
  '00000000-0000-0000-0000-000000000081', (select room_id from P)), '프로필이 확정');
select public.admin_update_profile('00000000-0000-0000-0000-0000000008a1', (select room_id from P), (select p1 from ids), '{"appearance":"부서진 갑옷"}');
select pg_temp.ok((select appearance = '부서진 갑옷' from public.players where id = (select p1 from ids))
              and (select changed_by = 'admin' from public.profile_history where player_id = (select p1 from ids) order by id desc limit 1),
  '관리자는 전투 중에도 프로필 수정 가능 (관리자 수정으로 기록)');
select pg_temp.expect_error(format($$select public.admin_update_profile(%L,%L,%L,'{"bio":"x"}')$$,
  '00000000-0000-0000-0000-000000000082', (select room_id from P), (select p1 from ids)), '관리자 권한');

-- RLS: 수정 내역은 본인 것만
grant select on ids to authenticated;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000082', false);
select pg_temp.ok((select count(*) = 0 from public.profile_history), 'RLS: 남의 프로필 수정 내역 조회 불가');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000081', false);
select pg_temp.ok((select count(*) = 2 from public.profile_history), 'RLS: 본인 수정 내역은 조회 가능');
reset role;
