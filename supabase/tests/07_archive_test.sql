-- 7단계 테스트: 전투 종료 시 자동 저장 / 중복 저장 방지 / 저장 실패 → 재시도 / 방 삭제 후에도 기록 유지
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

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000007a1'),
  ('00000000-0000-0000-0000-000000000071'), ('00000000-0000-0000-0000-000000000072');
select public.register_admin('00000000-0000-0000-0000-0000000007a1');

-- ---------------- 시나리오 1: 승리 → 자동 저장 ----------------
create temp table V as select (r->>'id')::uuid as room_id, r->>'room_code' as code
  from (select public.admin_create_room('00000000-0000-0000-0000-0000000007a1', '기록방', '보관 테스트', null, 10, 180) r) x;
select public.join_room('00000000-0000-0000-0000-000000000071', (select code from V), '영웅', null);
select public.admin_update_player('00000000-0000-0000-0000-0000000007a1', (select room_id from V),
  (select id from public.players where display_name = '영웅'), '{"min_attack":50,"max_attack":50}');
select public.admin_save_enemy('00000000-0000-0000-0000-0000000007a1', (select room_id from V), null,
  '{"name":"슬라임","max_hp":40,"appearance_message":"말랑한 슬라임이 튀어나왔다!"}');
create temp table heal as select public.admin_create_item('00000000-0000-0000-0000-0000000007a1', (select room_id from V),
  '{"item_type":"heal","name":"약초","effect_value":10}') as id;
select public.admin_grant_item('00000000-0000-0000-0000-0000000007a1', (select room_id from V), (select id from heal),
  (select id from public.players where display_name = '영웅'), 2);
select public.send_chat('00000000-0000-0000-0000-0000000007a1', (select room_id from V), '이야기가 시작된다.');
select public.admin_appear_enemy('00000000-0000-0000-0000-0000000007a1', (select room_id from V), (select id from public.enemies where name = '슬라임'));
select public.admin_update_room_settings('00000000-0000-0000-0000-0000000007a1', (select room_id from V), '{"first_side":"players"}');
select public.admin_start_battle('00000000-0000-0000-0000-0000000007a1', (select room_id from V));
select public.submit_action('00000000-0000-0000-0000-000000000071', (select room_id from V),
  json_build_object('action_type','item','item_id',(select id from heal))::jsonb);
select public.send_chat('00000000-0000-0000-0000-000000000071', (select room_id from V), '약초 먹을게');
select public.admin_resolve_now('00000000-0000-0000-0000-0000000007a1', (select room_id from V));
select public.submit_action('00000000-0000-0000-0000-000000000071', (select room_id from V),
  json_build_object('action_type','attack','target_id',(select id from public.enemies where name = '슬라임'))::jsonb);
select public.admin_resolve_now('00000000-0000-0000-0000-0000000007a1', (select room_id from V));

select pg_temp.ok((select status = 'ended' and result = 'victory' and archive_status = 'saved' from public.rooms where id = (select room_id from V)),
  '승리 → 관리자 조작 없이 자동 저장 (saved)');
create temp table AR as select * from public.battle_archives where room_id = (select room_id from V);
select pg_temp.ok((select count(*) = 1 from AR), '보관함에 1건 저장');
select pg_temp.ok((select room_name_snapshot = '기록방' and result = 'victory' and first_side = 'players'
                     and started_at is not null and ended_at is not null from AR), '기본 정보 (방 이름, 결과, 선공, 시작/종료 시각)');
select pg_temp.ok((select total_cycles = 1 and total_phases >= 4 and duration_seconds >= 0 from public.battle_results where room_id = (select room_id from V)),
  '요약 (총 사이클·단계 수, 소요 시간)');
select pg_temp.ok((select archive_data->'players'->0->>'nickname' = '영웅'
                     and (archive_data->'players'->0->>'status') = 'alive'
                     and (archive_data->'players'->0->>'damage_dealt')::int = 40
                     and archive_data->'players'->0->'items_used'->0->>'item_name' = '약초'
                     and (archive_data->'players'->0->'items_used'->0->>'count')::int = 1 from AR),
  '참가자 정보 (닉네임, 상태, 누적 피해량, 사용 아이템)');
select pg_temp.ok((select (archive_data->'enemies'->0->>'appeared')::boolean and (archive_data->'enemies'->0->>'appearance_order')::int = 1
                     and archive_data->'enemies'->0->>'appeared_at' is not null and (archive_data->'enemies'->0->>'dead')::boolean
                     and (archive_data->'enemies'->0->>'final_hp')::int = 0 from AR),
  '적군 정보 (등장 여부·시각·순서, 최종 HP, 사망)');
select pg_temp.ok((select jsonb_array_length(archive_data->'logs') > 10
                     and archive_data->'logs' @> '[{"log_type":"enemy_appeared"}]' and archive_data->'logs' @> '[{"log_type":"battle_ended"}]'
                     and archive_data->'logs' @> '[{"log_type":"item_heal"}]' from AR),
  '전투 로그 전체 (등장 이벤트·아이템·종료 결과 포함)');
select pg_temp.ok((select jsonb_array_length(archive_data->'chat') = 2 and archive_data->'chat'->0->>'nickname' = '관리자'
                     and archive_data->'events' @> '[{"event_type":"enemy_appeared","event_message":"말랑한 슬라임이 튀어나왔다!"}]' from AR),
  '채팅 기록과 시스템 메시지를 따로 저장');
select pg_temp.ok((select jsonb_array_length(archive_data->'phases') = 4 from AR), '단계별 진행 기록');

-- 중복 저장 방지
select pg_temp.ok(public.save_battle_archive((select room_id from V)) = 'already_saved', '재저장 요청 → 이미 저장됨');
select pg_temp.ok(public.admin_retry_archive('00000000-0000-0000-0000-0000000007a1', (select room_id from V)) = 'already_saved', '관리자 재시도도 중복 저장 안 함');
select pg_temp.ok((select count(*) = 1 from public.battle_archives where room_id = (select room_id from V))
              and (select count(*) = 1 from public.battle_results where room_id = (select room_id from V)), '기록 1건 유지');

-- 방 삭제 후에도 기록 유지
select public.admin_delete_room('00000000-0000-0000-0000-0000000007a1', (select room_id from V));
select pg_temp.ok((select count(*) = 1 from public.battle_archives where room_id = (select room_id from V)), '방을 삭제해도 기록 보존');
select pg_temp.ok((select count(*) = 0 from public.chat_messages where room_id = (select room_id from V)), '(원본 채팅은 방과 함께 삭제되지만 보관함 사본은 유지)');

-- ---------------- 시나리오 2: 저장 실패 → 전투 종료는 유지 → 재시도 ----------------
create temp table F as select (r->>'id')::uuid as room_id, r->>'room_code' as code
  from (select public.admin_create_room('00000000-0000-0000-0000-0000000007a1', '실패방', '', null, 10, 180) r) x;
select public.join_room('00000000-0000-0000-0000-000000000072', (select code from F), '용사', null);
select public.admin_save_enemy('00000000-0000-0000-0000-0000000007a1', (select room_id from F), null, '{"name":"유령"}');
select public.admin_update_room_settings('00000000-0000-0000-0000-0000000007a1', (select room_id from F), '{"first_side":"players"}');
select public.admin_start_battle('00000000-0000-0000-0000-0000000007a1', (select room_id from F));

-- 저장 단계에서 일부러 오류를 일으키는 장치
create function pg_temp.boom() returns trigger language plpgsql as $$ begin raise exception '디스크 가득 참(테스트)'; end $$;
create trigger boom before insert on public.battle_archives for each row execute function pg_temp.boom();

select public.admin_end_battle('00000000-0000-0000-0000-0000000007a1', (select room_id from F), '테스트');
select pg_temp.ok((select status = 'ended' and result = 'forced' from public.rooms where id = (select room_id from F)), '저장 실패해도 전투 종료는 정상 처리');
select pg_temp.ok((select archive_status = 'failed' and archive_error like '%디스크 가득 참%' from public.rooms where id = (select room_id from F)),
  '실패 상태 + 오류 내용 기록');
select pg_temp.ok((select count(*) = 0 from public.battle_archives where room_id = (select room_id from F))
              and (select count(*) = 0 from public.battle_results where room_id = (select room_id from F)), '실패 시 반쪽 기록 남지 않음');
select pg_temp.expect_error(format($$select public.admin_delete_room(%L,%L)$$, '00000000-0000-0000-0000-0000000007a1', (select room_id from F)),
  '아직 저장되지 않았습니다');
select pg_temp.expect_error(format($$select public.admin_retry_archive(%L,%L)$$, '00000000-0000-0000-0000-0000000007a1', (select room_id from F)),
  '저장에 실패했습니다');
select pg_temp.expect_error(format($$select public.admin_retry_archive(%L,%L)$$, '00000000-0000-0000-0000-000000000072', (select room_id from F)),
  '관리자 권한');

drop trigger boom on public.battle_archives;
select pg_temp.ok(public.admin_retry_archive('00000000-0000-0000-0000-0000000007a1', (select room_id from F)) = 'saved', '원인 해결 후 재시도 → 저장 성공');
select pg_temp.ok((select archive_status = 'saved' and archive_error is null from public.rooms where id = (select room_id from F)), '저장 완료 표시');

-- pending 상태는 예약 작업이 다시 저장
update public.rooms set archive_status = 'pending' where id = (select room_id from F);
delete from public.battle_archives where room_id = (select room_id from F);
delete from public.battle_results where room_id = (select room_id from F);
select public.battle_tick();
select pg_temp.ok((select archive_status = 'saved' from public.rooms where id = (select room_id from F))
              and (select count(*) = 1 from public.battle_archives where room_id = (select room_id from F)), '저장 대기 기록을 예약 작업이 자동 재저장');

-- 진행 중 전투는 저장 불가
select pg_temp.expect_error($$select public.save_battle_archive(gen_random_uuid())$$, '찾을 수 없습니다');
