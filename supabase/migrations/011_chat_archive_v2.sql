-- =====================================================================
-- 011_chat_archive_v2.sql : (v2 5단계) 채팅 표시 규칙 + 전투 기록 보강
--   - 채팅: 캐릭터 이름 + 이름 색(player_id 연결) / 관리자 메시지는 화면에서 본문만 회색
--   - 기록 보관: 참가자 프로필·이름 색·추가 항목 정의·프로필 수정 내역, 로그의 선언/결과 구분,
--               채팅의 이름 색과 가린 메시지 원문(관리자 전용 기록)까지 저장
-- 실행 순서: 010 다음. 여러 번 실행해도 안전합니다.
-- =====================================================================

alter table public.chat_messages add column if not exists player_id uuid references public.players(id) on delete set null;

-- 채팅 전송 (006 대체): 닉네임 대신 캐릭터 이름, player_id 저장
create or replace function public.send_chat(p_user_id uuid, p_room_id uuid, p_message text)
returns jsonb language plpgsql as $$
declare
  v_room public.rooms;
  v_is_admin boolean := exists (select 1 from public.admins where user_id = p_user_id);
  v_member public.room_members;
  v_msg text;
  v_nick text;
  v_role text;
  v_player_id uuid;
  v_recent int;
  v_id bigint;
begin
  select * into v_room from public.rooms where id = p_room_id;
  if not found then raise exception '전투방을 찾을 수 없습니다.' using errcode = 'P0001'; end if;

  if v_is_admin then
    v_nick := '관리자';
    v_role := 'admin';
  else
    select * into v_member from public.room_members where room_id = p_room_id and user_id = p_user_id;
    if not found then raise exception '이 전투방의 참가자가 아닙니다.' using errcode = 'P0001'; end if;
    if v_member.status <> 'active' then
      raise exception '퇴장했거나 강퇴된 사용자는 메시지를 보낼 수 없습니다.' using errcode = 'P0001';
    end if;
    -- 채팅에는 캐릭터 이름(프로필) 사용, 이름 색은 player_id 로 연결
    select id, display_name into v_player_id, v_nick from public.players where member_id = v_member.id;
    v_nick := coalesce(v_nick, v_member.nickname);
    v_role := 'guest';
  end if;

  if v_room.status = 'ended' then
    raise exception '전투가 종료되어 채팅은 읽기 전용입니다.' using errcode = 'P0001';
  end if;

  -- 보이지 않는 문자 제거, 줄바꿈은 공백으로, 앞뒤 공백 제거
  v_msg := coalesce(p_message, '');
  v_msg := regexp_replace(v_msg, '[\r\n\t]+', ' ', 'g');
  v_msg := regexp_replace(v_msg, '[\x00-\x1F\x7F​-‏‪-‮⁠-⁤⁦-⁩﻿]', '', 'g');
  v_msg := btrim(v_msg);
  if v_msg = '' then raise exception '메시지를 입력하세요.' using errcode = 'P0001'; end if;
  if char_length(v_msg) > 300 then raise exception '메시지는 300자 이하로 입력하세요.' using errcode = 'P0001'; end if;

  -- 간단한 스팸 방지: 10초에 5개까지, 같은 내용 5초 안에 반복 금지
  select count(*) into v_recent from public.chat_messages
   where room_id = p_room_id and sender_id = p_user_id and created_at > now() - interval '10 seconds';
  if v_recent >= 5 then
    raise exception '메시지를 너무 빠르게 보내고 있습니다. 잠시 후 다시 시도하세요.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.chat_messages
              where room_id = p_room_id and sender_id = p_user_id and message = v_msg
                and created_at > now() - interval '5 seconds') then
    raise exception '같은 메시지를 연속으로 보낼 수 없습니다.' using errcode = 'P0001';
  end if;

  insert into public.chat_messages (room_id, sender_id, sender_role, nickname, message, player_id)
  values (p_room_id, p_user_id, v_role, v_nick, v_msg, v_player_id)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;


-- 채팅 한 줄 → 화면용 JSON (009 대체): 이름 색 추가
create or replace function public.chat_json(c public.chat_messages, p_user_id uuid, p_admin boolean)
returns jsonb language sql stable as $$
  select jsonb_build_object('id', c.id, 'sender_role', c.sender_role, 'nickname', c.nickname,
                            'name_color', (select name_color from public.players where id = c.player_id),
                            'message', c.message, 'hidden', c.hidden_at is not null,
                            'original', case when p_admin and c.hidden_at is not null
                                             then (select original from public.chat_moderation where message_id = c.id) end,
                            'created_at', c.created_at, 'is_mine', c.sender_id = p_user_id)
$$;

-- ---------------------------------------------------------------------
-- 기록 보강: 기존 저장(save_battle_archive) 직후 같은 처리 단위에서 v2 항목 추가
-- ---------------------------------------------------------------------
create or replace function public.enrich_archive_v2(p_room_id uuid)
returns void language plpgsql as $$
declare
  v_profiles jsonb;
  v_extra jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'nickname', m.nickname, 'display_name', p.display_name, 'name_color', p.name_color,
           'bio', p.bio, 'appearance', p.appearance, 'profile_extra', p.profile_extra,
           'profile_locked_at', p.profile_locked_at) order by m.joined_at), '[]'::jsonb)
    into v_profiles
    from public.players p join public.room_members m on m.id = p.member_id where p.room_id = p_room_id;

  v_extra := jsonb_build_object(
    'version', 2,
    'profiles', v_profiles,
    'profile_fields', (select profile_fields from public.rooms where id = p_room_id),
    'profile_history', coalesce((select jsonb_agg(jsonb_build_object(
          'player_name', p.display_name, 'changed_by', h.changed_by, 'changes', h.changes, 'created_at', h.created_at) order by h.id)
        from public.profile_history h join public.players p on p.id = h.player_id where h.room_id = p_room_id), '[]'::jsonb),
    -- 로그: 행동 선언(declare) / 판정 결과(result) / 기타(info) 구분 포함
    'logs', coalesce((select jsonb_agg(to_jsonb(l) - 'room_id' order by l.id) from public.battle_logs l where l.room_id = p_room_id), '[]'::jsonb),
    -- 채팅: 이름 색 + 가린 메시지 원문 (보관함은 관리자 전용)
    'chat', coalesce((select jsonb_agg(jsonb_build_object(
          'id', c.id, 'sender_role', c.sender_role, 'nickname', c.nickname,
          'name_color', (select name_color from public.players where id = c.player_id),
          'message', coalesce((select original from public.chat_moderation where message_id = c.id), c.message),
          'hidden', c.hidden_at is not null, 'created_at', c.created_at) order by c.id)
        from public.chat_messages c where c.room_id = p_room_id), '[]'::jsonb)
  );

  update public.battle_archives a
     set archive_data = a.archive_data || v_extra || jsonb_build_object('players',
           (select coalesce(jsonb_agg(pl || coalesce((select pr from jsonb_array_elements(v_profiles) pr where pr->>'nickname' = pl->>'nickname' limit 1), '{}'::jsonb)), '[]'::jsonb)
              from jsonb_array_elements(a.archive_data -> 'players') pl))
   where a.room_id = p_room_id and not (a.archive_data ? 'version');
  update public.battle_results r
     set result_data = r.result_data || jsonb_build_object('profiles', v_profiles, 'version', 2)
   where r.room_id = p_room_id and not (r.result_data ? 'version');
end $$;

create or replace function public.try_save_archive(p_room_id uuid)
returns text language plpgsql as $$
declare
  v_status text;
begin
  begin
    v_status := public.save_battle_archive(p_room_id);
    perform public.enrich_archive_v2(p_room_id);
  exception when others then
    update public.rooms set archive_status = 'failed', archive_error = left(sqlerrm, 500) where id = p_room_id;
    raise warning '전투 기록 저장 실패 (room %): %', p_room_id, sqlerrm;
    return 'failed';
  end;
  return v_status;
end $$;

-- 권한
revoke execute on all functions in schema public from public, anon, authenticated;
grant  execute on all functions in schema public to service_role;
grant  execute on function public.is_admin(), public.is_room_member(uuid),
                           public.can_view_room(uuid), public.is_my_player(uuid)
  to authenticated;
