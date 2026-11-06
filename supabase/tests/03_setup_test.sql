-- 3단계 테스트: 능력치 / HP 조정 / 적군 등록·등장 / 아이템 / 선공 설정
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

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000003a1'), ('00000000-0000-0000-0000-000000000031'),
  ('00000000-0000-0000-0000-000000000032');
select public.register_admin('00000000-0000-0000-0000-0000000003a1');

create temp table s as
  select (r->>'id')::uuid as room_id, r->>'room_code' as code, '00000000-0000-0000-0000-0000000003a1'::uuid as adm
  from (select public.admin_create_room('00000000-0000-0000-0000-0000000003a1', '3단계 방', '', null, 10, 180) r) x;
select public.join_room('00000000-0000-0000-0000-000000000031', (select code from s), '전사', null);
select public.join_room('00000000-0000-0000-0000-000000000032', (select code from s), '궁수', null);
create temp table pl as select p.id, p.display_name from public.players p where p.room_id = (select room_id from s);

-- ---------------- 플레이어 능력치 ----------------
select public.admin_update_player((select adm from s), (select room_id from s), (select id from pl where display_name = '전사'),
  '{"display_name":"전사 A","max_hp":"120","current_hp":120,"min_attack":5,"max_attack":10,"dodge_rate":30,"escape_rate":20}');
select pg_temp.ok((select display_name = '전사 A' and max_hp = 120 and current_hp = 120 from public.players
                   where id = (select id from pl where display_name = '전사')), '능력치 수정 (이름, 최대/현재 HP)');
select pg_temp.ok((select count(*) = 1 from public.battle_logs where log_type = 'admin_hp'), 'HP 변경은 전투 로그에 기록');
select pg_temp.expect_error(format($$select public.admin_update_player(%L,%L,%L,'{"min_attack":11,"max_attack":10}')$$,
  (select adm from s), (select room_id from s), (select id from pl where display_name = '전사')), '최소 공격력이 최대 공격력보다');
select pg_temp.expect_error(format($$select public.admin_update_player(%L,%L,%L,'{"dodge_rate":101}')$$,
  (select adm from s), (select room_id from s), (select id from pl where display_name = '전사')), '0 ~ 100');
select pg_temp.expect_error(format($$select public.admin_update_player(%L,%L,%L,'{"max_hp":"abc"}')$$,
  (select adm from s), (select room_id from s), (select id from pl where display_name = '전사')), '정수로');
select pg_temp.expect_error(format($$select public.admin_update_player(%L,%L,%L,'{"current_hp":500}')$$,
  (select adm from s), (select room_id from s), (select id from pl where display_name = '전사')), '현재 HP가 최대 HP보다');
select pg_temp.expect_error(format($$select public.admin_update_player(%L,%L,%L,'{"max_hp":50}')$$,
  '00000000-0000-0000-0000-000000000031', (select room_id from s), (select id from pl where display_name = '전사')), '관리자 권한');

-- HP 조정: 0 → 사망, 다시 올리면 부활
select public.admin_set_player_hp((select adm from s), (select room_id from s), (select id from pl where display_name = '궁수'), 0, '함정');
select pg_temp.ok((select status = 'dead' from public.players where id = (select id from pl where display_name = '궁수')), 'HP 0 → 사망');
select public.admin_set_player_hp((select adm from s), (select room_id from s), (select id from pl where display_name = '궁수'), 30, null);
select pg_temp.ok((select status = 'alive' and current_hp = 30 from public.players where id = (select id from pl where display_name = '궁수')), 'HP 회복 → 부활');
select pg_temp.ok((select content like '%사유: 함정%' from public.battle_logs where log_type = 'admin_hp' order by id limit 1 offset 1), 'HP 조정 사유 기록');
select pg_temp.expect_error(format($$select public.admin_set_player_hp(%L,%L,%L,101,null)$$,
  (select adm from s), (select room_id from s), (select id from pl where display_name = '궁수')), '최대 HP');

-- ---------------- 적군 ----------------
create temp table en (id uuid, name text);
insert into en select public.admin_save_enemy((select adm from s), (select room_id from s), null,
  '{"name":"나무 허수아비","max_hp":100,"min_attack":1,"max_attack":4,"dodge_rate":0,"defense":0,"target_type":"random"}'), '나무 허수아비';
select pg_temp.ok((select current_hp = 100 and appearance_status = 'registered' and status = 'alive' from public.enemies where id = (select id from en)),
  '적군 등록 (현재 HP = 최대 HP, 등록됨 상태)');
insert into en select public.admin_save_enemy((select adm from s), (select room_id from s), null,
  format('{"name":"그림자 거인","max_hp":300,"target_type":"specific","target_player_id":"%s","appearance_message":"어둠 속에서 거대한 그림자가 모습을 드러냈다."}',
         (select id from pl where display_name = '궁수'))::jsonb), '그림자 거인';
select pg_temp.expect_error(format($$select public.admin_save_enemy(%L,%L,null,'{"name":"x","target_type":"specific"}')$$,
  (select adm from s), (select room_id from s)), '특정 플레이어');
select public.admin_save_enemy((select adm from s), (select room_id from s), null, '{"name":"적3"}');
select public.admin_save_enemy((select adm from s), (select room_id from s), null, '{"name":"적4"}');
select public.admin_save_enemy((select adm from s), (select room_id from s), null, '{"name":"적5"}');
select pg_temp.expect_error(format($$select public.admin_save_enemy(%L,%L,null,'{"name":"적6"}')$$,
  (select adm from s), (select room_id from s)), '최대 5명');

-- 수정
select public.admin_save_enemy((select adm from s), (select room_id from s), (select id from en where name = '나무 허수아비'),
  '{"defense":2,"description":"짚으로 만든 허수아비"}');
select pg_temp.ok((select defense = 2 and description = '짚으로 만든 허수아비' and name = '나무 허수아비' from public.enemies
                   where id = (select id from en where name = '나무 허수아비')), '적군 수정 (나머지 값 유지)');

-- 게스트 시점: 등록만 된 적군은 안 보임
grant select on s to authenticated;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000031', false);
select pg_temp.ok((select count(*) = 0 from public.enemies), '등록만 된 적군은 게스트에게 보이지 않음');
reset role;

-- 등장 (기본 문구 / 사용자 문구 / 순서 / 중복 방지)
select public.admin_appear_enemy((select adm from s), (select room_id from s), (select id from en where name = '나무 허수아비'));
select public.admin_appear_enemy((select adm from s), (select room_id from s), (select id from en where name = '그림자 거인'));
select pg_temp.ok((select appearance_status = 'appeared' and appearance_order = 1 and appeared_at is not null from public.enemies
                   where id = (select id from en where name = '나무 허수아비')), '등장 상태·순서·시각 기록');
select pg_temp.ok((select appearance_order = 2 from public.enemies where id = (select id from en where name = '그림자 거인')), '두 번째 등장 순서 2');
select pg_temp.ok((select event_message = '나무 허수아비가 등장했다!' from public.battle_events where enemy_id = (select id from en where name = '나무 허수아비')),
  '기본 등장 문구 (받침 없음 → 가)');
select pg_temp.ok((select event_message = '어둠 속에서 거대한 그림자가 모습을 드러냈다.' from public.battle_events where enemy_id = (select id from en where name = '그림자 거인')),
  '사용자 지정 등장 문구');
select pg_temp.ok((select count(*) = 2 from public.battle_logs where log_type = 'enemy_appeared'), '등장 이벤트가 전투 로그에도 기록');
select pg_temp.ok(public.josa('거인', '이', '가') = '이', '조사: 받침 있음 → 이');
select pg_temp.expect_error(format($$select public.admin_appear_enemy(%L,%L,%L)$$,
  (select adm from s), (select room_id from s), (select id from en where name = '나무 허수아비')), '이미 등장한');
select pg_temp.expect_error(format($$select public.admin_delete_enemy(%L,%L,%L)$$,
  (select adm from s), (select room_id from s), (select id from en where name = '나무 허수아비')), '이미 등장한 적군은 삭제');
select public.admin_delete_enemy((select adm from s), (select room_id from s), (select id from public.enemies where name = '적5'));
select pg_temp.ok((select count(*) = 4 from public.enemies where room_id = (select room_id from s)), '미등장 적군 삭제');

set role authenticated;
select pg_temp.ok((select count(*) = 2 from public.enemies), '등장한 적군은 게스트에게 보임');
select pg_temp.ok((select count(*) = 2 from public.battle_events), '게스트가 등장 이벤트 조회 가능');
reset role;

-- ---------------- 아이템 ----------------
create temp table it (id uuid, name text);
insert into it select public.admin_create_item((select adm from s), (select room_id from s),
  '{"item_type":"heal","name":"소형 회복약","description":"HP 20 회복","effect_value":20}'), '소형 회복약';
insert into it select public.admin_create_item((select adm from s), (select room_id from s),
  '{"item_type":"damage","name":"투척 폭탄","effect_value":15}'), '투척 폭탄';
select pg_temp.expect_error(format($$select public.admin_create_item(%L,%L,'{"item_type":"buff","name":"x","effect_value":1}')$$,
  (select adm from s), (select room_id from s)), 'HP 회복 또는 적군 고정 피해');
select pg_temp.expect_error(format($$select public.admin_create_item(%L,%L,'{"item_type":"heal","name":"x"}')$$,
  (select adm from s), (select room_id from s)), '회복량을(를) 입력');

select public.admin_grant_item((select adm from s), (select room_id from s), (select id from it where name = '소형 회복약'),
  (select id from pl where display_name = '전사'), 2);
select pg_temp.ok(public.admin_grant_item((select adm from s), (select room_id from s), (select id from it where name = '소형 회복약'),
  (select id from pl where display_name = '전사'), 3) = 5, '같은 아이템 지급 시 수량 누적');
select pg_temp.expect_error(format($$select public.admin_grant_item(%L,%L,%L,%L,0)$$,
  (select adm from s), (select room_id from s), (select id from it where name = '투척 폭탄'), (select id from pl where display_name = '전사')), '1~99');

set role authenticated;
select pg_temp.ok((select count(*) = 1 from public.player_inventory), '전사는 자기 인벤토리 조회');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000032', false);
select pg_temp.ok((select count(*) = 0 from public.player_inventory), '궁수는 남의 인벤토리 조회 불가');
reset role;

-- ---------------- 선공 / 턴 시간 ----------------
select public.admin_update_room_settings((select adm from s), (select room_id from s), '{"first_side":"enemies","turn_duration":420}');
select pg_temp.ok((select first_side = 'enemies' and turn_duration = 420 from public.rooms where id = (select room_id from s)), '선공 측 + 턴 시간 설정');
select pg_temp.expect_error(format($$select public.admin_update_room_settings(%L,%L,'{"first_side":"nobody"}')$$,
  (select adm from s), (select room_id from s)), '선공 측이 올바르지');

-- ---------------- 전투 중 / 종료 후 제한 ----------------
update public.rooms set status = 'in_progress' where id = (select room_id from s);
select pg_temp.expect_error(format($$select public.admin_update_player(%L,%L,%L,'{"max_attack":99}')$$,
  (select adm from s), (select room_id from s), (select id from pl where display_name = '전사')), '전투 중에는 현재 HP만');
select public.admin_update_player((select adm from s), (select room_id from s), (select id from pl where display_name = '전사'), '{"current_hp":50}');
select pg_temp.ok((select current_hp = 50 from public.players where id = (select id from pl where display_name = '전사')), '전투 중 HP 조정 가능');
select pg_temp.expect_error(format($$select public.admin_update_room_settings(%L,%L,'{"first_side":"players"}')$$,
  (select adm from s), (select room_id from s)), '전투 시작 전에만');
select public.admin_appear_enemy((select adm from s), (select room_id from s), (select id from public.enemies where name = '적3'));
select pg_temp.ok((select appearance_order = 3 from public.enemies where name = '적3'), '전투 중 적군 등장 가능');

update public.rooms set status = 'ended' where id = (select room_id from s);
select pg_temp.expect_error(format($$select public.admin_appear_enemy(%L,%L,%L)$$,
  (select adm from s), (select room_id from s), (select id from public.enemies where name = '적4')), '전투가 종료되어');
select pg_temp.expect_error(format($$select public.admin_set_player_hp(%L,%L,%L,10,null)$$,
  (select adm from s), (select room_id from s), (select id from pl where display_name = '전사')), '종료된 전투');
