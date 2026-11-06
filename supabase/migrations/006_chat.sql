-- =====================================================================
-- 006_chat.sql : 6단계 채팅 + 5단계 기록 페이지 조회
--   - send_chat: 채팅 전송 (300자, 빈 메시지 금지, 같은 방 활성 참가자/관리자만, 스팸 방지,
--                전투 종료 후 읽기 전용). 채팅은 전투 진행·행동 제출과 완전히 무관.
--   - get_room_history: 채팅 / 전투 로그를 오래된 순서로 페이지 단위 조회 ("이전 기록 더 보기")
-- 실행 순서: 005 다음. 여러 번 실행해도 안전합니다.
--
-- XSS: 메시지는 "글자 그대로" 저장하고, 화면(React)은 항상 텍스트로만 출력합니다(HTML 해석 안 함).
--      추가로 제어 문자·방향 바꾸기 문자 등 보이지 않는 문자를 제거합니다.
-- =====================================================================

create or replace function public.send_chat(p_user_id uuid, p_room_id uuid, p_message text)
returns jsonb language plpgsql as $$
declare
  v_room public.rooms;
  v_is_admin boolean := exists (select 1 from public.admins where user_id = p_user_id);
  v_member public.room_members;
  v_msg text;
  v_nick text;
  v_role text;
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
    v_nick := v_member.nickname;
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

  insert into public.chat_messages (room_id, sender_id, sender_role, nickname, message)
  values (p_room_id, p_user_id, v_role, v_nick, v_msg)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

-- ---------------------------------------------------------------------
-- 기록 조회 (관리자 또는 활성 참가자)
--   p_kind: 'chat' | 'logs'   p_before: 이 id 보다 오래된 것 (null = 최신부터)   p_limit: 최대 개수
--   결과: { items: [...오래된 순...], has_more: bool }  또는 { error }
--   채팅에는 보낸 사람 ID 대신 is_mine (내가 보낸 메시지인지) 만 포함
-- ---------------------------------------------------------------------
create or replace function public.get_room_history(
  p_user_id uuid, p_room_id uuid, p_kind text, p_before bigint, p_limit int
) returns jsonb language plpgsql stable as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_items jsonb;
  v_min bigint;
begin
  if not exists (select 1 from public.rooms where id = p_room_id) then
    return jsonb_build_object('error', 'not_found');
  end if;
  if not exists (select 1 from public.admins where user_id = p_user_id)
     and not exists (select 1 from public.room_members where room_id = p_room_id and user_id = p_user_id and status = 'active') then
    return jsonb_build_object('error', 'not_member');
  end if;

  if p_kind = 'chat' then
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'sender_role', x.sender_role, 'nickname', x.nickname,
                                                 'message', x.message, 'created_at', x.created_at,
                                                 'is_mine', x.sender_id = p_user_id) order by x.id), '[]'::jsonb),
           min(x.id)
      into v_items, v_min
      from (select * from public.chat_messages
             where room_id = p_room_id and (p_before is null or id < p_before)
             order by id desc limit v_limit) x;
    return jsonb_build_object('items', v_items,
      'has_more', v_min is not null and exists (select 1 from public.chat_messages where room_id = p_room_id and id < v_min));
  elsif p_kind = 'logs' then
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'cycle_number', x.cycle_number, 'phase_number', x.phase_number,
                                                 'phase_id', x.phase_id, 'actor_type', x.actor_type, 'actor_id', x.actor_id,
                                                 'target_type', x.target_type, 'target_id', x.target_id, 'log_type', x.log_type,
                                                 'content', x.content, 'data', x.data, 'created_at', x.created_at) order by x.id), '[]'::jsonb),
           min(x.id)
      into v_items, v_min
      from (select * from public.battle_logs
             where room_id = p_room_id and (p_before is null or id < p_before)
             order by id desc limit v_limit) x;
    return jsonb_build_object('items', v_items,
      'has_more', v_min is not null and exists (select 1 from public.battle_logs where room_id = p_room_id and id < v_min));
  end if;
  raise exception '알 수 없는 기록 종류입니다.' using errcode = 'P0001';
end $$;

-- 권한
revoke execute on all functions in schema public from public, anon, authenticated;
grant  execute on all functions in schema public to service_role;
grant  execute on function public.is_admin(), public.is_room_member(uuid),
                           public.can_view_room(uuid), public.is_my_player(uuid)
  to authenticated;
