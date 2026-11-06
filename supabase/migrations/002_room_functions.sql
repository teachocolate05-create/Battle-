-- =====================================================================
-- 002_room_functions.sql : 관리자 인증 / 전투방 생성·삭제 / 입장·퇴장·강퇴
-- 실행 순서: 001_schema.sql 다음에 실행
-- 이 파일은 여러 번 실행해도 안전합니다 (create or replace).
--
-- 모든 함수는 서버(Next.js, secret key)에서만 호출할 수 있습니다.
-- 사용자에게 보여줄 오류는 errcode 'P0001' + 한국어 메시지로 발생시킵니다.
-- =====================================================================

-- 관리자인지 확인 (아니면 오류)
create or replace function public.assert_admin(p_user_id uuid)
returns void language plpgsql as $$
begin
  if p_user_id is null or not exists (select 1 from public.admins where user_id = p_user_id) then
    raise exception '관리자 권한이 필요합니다.' using errcode = 'P0001';
  end if;
end $$;

-- 관리자 등록 (관리자 코드 검증은 서버에서 끝난 뒤 호출)
create or replace function public.register_admin(p_user_id uuid)
returns void language plpgsql as $$
begin
  insert into public.admins (user_id) values (p_user_id) on conflict (user_id) do nothing;
end $$;

create or replace function public.unregister_admin(p_user_id uuid)
returns void language plpgsql as $$
begin
  delete from public.admins where user_id = p_user_id;
end $$;

-- 헷갈리는 글자(0,O,1,I,L)를 뺀 6자리 방 코드
create or replace function public.generate_room_code()
returns text language plpgsql as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  code text;
  i int;
begin
  loop
    code := '';
    for i in 1..6 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.rooms where room_code = code);
  end loop;
  return code;
end $$;

-- ---------------------------------------------------------------------
-- 전투방 생성
-- ---------------------------------------------------------------------
create or replace function public.admin_create_room(
  p_user_id       uuid,
  p_room_name     text,
  p_description   text,
  p_password      text,      -- null 또는 빈 문자열이면 비밀번호 없음
  p_max_players   int,
  p_turn_duration int
) returns jsonb language plpgsql as $$
declare
  v_room public.rooms;
  v_name text := btrim(coalesce(p_room_name, ''));
  v_pw   text := nullif(coalesce(p_password, ''), '');
begin
  perform public.assert_admin(p_user_id);

  if char_length(v_name) < 1 or char_length(v_name) > 50 then
    raise exception '전투방 이름은 1~50자로 입력하세요.' using errcode = 'P0001';
  end if;
  if char_length(coalesce(p_description, '')) > 500 then
    raise exception '설명은 500자 이하로 입력하세요.' using errcode = 'P0001';
  end if;
  if p_max_players is null or p_max_players < 1 or p_max_players > 10 then
    raise exception '최대 인원은 1~10명이어야 합니다.' using errcode = 'P0001';
  end if;
  if p_turn_duration not in (180, 300, 420) then
    raise exception '턴 제한 시간은 3분, 5분, 7분 중 하나여야 합니다.' using errcode = 'P0001';
  end if;
  if v_pw is not null and (char_length(v_pw) < 4 or char_length(v_pw) > 50) then
    raise exception '비밀번호는 4~50자로 입력하세요.' using errcode = 'P0001';
  end if;

  insert into public.rooms (room_code, room_name, description, has_password,
                            max_players, turn_duration, created_by)
  values (public.generate_room_code(), v_name, coalesce(p_description, ''), v_pw is not null,
          p_max_players, p_turn_duration, p_user_id)
  returning * into v_room;

  if v_pw is not null then
    insert into public.room_secrets (room_id, password_hash)
    values (v_room.id, extensions.crypt(v_pw, extensions.gen_salt('bf')));
  end if;

  return jsonb_build_object('id', v_room.id, 'room_code', v_room.room_code);
end $$;

-- ---------------------------------------------------------------------
-- 전투방 삭제 (진행 중이면 불가). 종료된 전투 기록(battle_archives)은 FK가 없어서 남습니다.
-- ---------------------------------------------------------------------
create or replace function public.admin_delete_room(p_user_id uuid, p_room_id uuid)
returns void language plpgsql as $$
declare
  v_room public.rooms;
begin
  perform public.assert_admin(p_user_id);

  select * into v_room from public.rooms where id = p_room_id for update;
  if not found then
    raise exception '전투방을 찾을 수 없습니다.' using errcode = 'P0001';
  end if;
  if v_room.status = 'in_progress' then
    raise exception '진행 중인 전투방은 삭제할 수 없습니다. 먼저 전투를 종료하세요.' using errcode = 'P0001';
  end if;

  delete from public.rooms where id = p_room_id;
end $$;

-- ---------------------------------------------------------------------
-- 게스트 입장 / 재접속
--  - 같은 사용자가 이미 이 방의 참가자면: 기존 캐릭터로 복구 (닉네임 무시)
--  - 나갔던 사용자: 다시 입장 가능 (기존 캐릭터 복구)
--  - 강퇴된 사용자: 입장 불가
--  - 새 참가자: 대기 중인 방만, 인원 제한/닉네임 중복 검사
-- ---------------------------------------------------------------------
create or replace function public.join_room(
  p_user_id  uuid,
  p_code     text,
  p_nickname text,
  p_password text
) returns jsonb language plpgsql as $$
declare
  v_room     public.rooms;
  v_member   public.room_members;
  v_nickname text := btrim(coalesce(p_nickname, ''));
  v_hash     text;
  v_count    int;
begin
  if p_user_id is null then
    raise exception '로그인 정보가 없습니다. 새로고침 후 다시 시도하세요.' using errcode = 'P0001';
  end if;

  -- 방 행을 잠가서 동시에 여러 명이 입장해도 인원 검사가 정확하도록 함
  select * into v_room from public.rooms
   where room_code = upper(btrim(coalesce(p_code, '')))
   for update;
  if not found then
    raise exception '존재하지 않는 방 코드입니다.' using errcode = 'P0001';
  end if;

  select * into v_member from public.room_members
   where room_id = v_room.id and user_id = p_user_id;

  -- 이미 참가 중 → 그대로 복구
  if found and v_member.status = 'active' then
    return jsonb_build_object('room_id', v_room.id, 'member_id', v_member.id, 'restored', true);
  end if;

  if found and v_member.status = 'kicked' then
    raise exception '이 방에서 강퇴되어 다시 입장할 수 없습니다.' using errcode = 'P0001';
  end if;

  -- 비밀번호 확인 (재입장 포함)
  if v_room.has_password then
    select password_hash into v_hash from public.room_secrets where room_id = v_room.id;
    if p_password is null or p_password = ''
       or v_hash is null or extensions.crypt(p_password, v_hash) <> v_hash then
      raise exception '비밀번호가 올바르지 않습니다.' using errcode = 'P0001';
    end if;
  end if;

  if v_member.id is null and v_room.status <> 'waiting' then
    raise exception '이미 전투가 시작되었거나 종료된 방에는 새로 입장할 수 없습니다.' using errcode = 'P0001';
  end if;
  if v_member.id is not null and v_room.status = 'ended' then
    raise exception '이미 종료된 전투방입니다.' using errcode = 'P0001';
  end if;

  -- 인원 제한 (관리자는 room_members에 없으므로 포함되지 않음)
  select count(*) into v_count from public.room_members
   where room_id = v_room.id and status = 'active';
  if v_count >= v_room.max_players then
    raise exception '전투방 인원이 가득 찼습니다. (최대 %명)', v_room.max_players using errcode = 'P0001';
  end if;

  -- 나갔던 사용자 재입장: 기존 닉네임/캐릭터 복구
  if v_member.id is not null then
    if exists (select 1 from public.room_members
                where room_id = v_room.id and status = 'active'
                  and lower(nickname) = lower(v_member.nickname)) then
      raise exception '기존 닉네임(%)을 다른 참가자가 사용 중입니다.', v_member.nickname using errcode = 'P0001';
    end if;
    update public.room_members set status = 'active', left_at = null
     where id = v_member.id returning * into v_member;
    return jsonb_build_object('room_id', v_room.id, 'member_id', v_member.id, 'restored', true);
  end if;

  -- 새 참가자
  if char_length(v_nickname) < 1 or char_length(v_nickname) > 20 then
    raise exception '닉네임은 1~20자로 입력하세요.' using errcode = 'P0001';
  end if;
  if v_nickname ~ '[<>]' then
    raise exception '닉네임에 < > 문자는 사용할 수 없습니다.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.room_members
              where room_id = v_room.id and status = 'active'
                and lower(nickname) = lower(v_nickname)) then
    raise exception '이미 사용 중인 닉네임입니다.' using errcode = 'P0001';
  end if;

  insert into public.room_members (room_id, user_id, nickname)
  values (v_room.id, p_user_id, v_nickname)
  returning * into v_member;

  -- 기본 능력치로 캐릭터 생성 (관리자가 3단계 화면에서 수정)
  insert into public.players (room_id, member_id, display_name)
  values (v_room.id, v_member.id, v_nickname);

  return jsonb_build_object('room_id', v_room.id, 'member_id', v_member.id, 'restored', false);
end $$;

-- ---------------------------------------------------------------------
-- 스스로 퇴장
-- ---------------------------------------------------------------------
create or replace function public.leave_room(p_user_id uuid, p_room_id uuid)
returns void language plpgsql as $$
begin
  if exists (select 1 from public.rooms where id = p_room_id and status = 'in_progress') then
    raise exception '전투 중에는 퇴장할 수 없습니다. 전투에서 벗어나려면 [도망] 행동을 사용하세요.' using errcode = 'P0001';
  end if;
  update public.room_members
     set status = 'left', left_at = now()
   where room_id = p_room_id and user_id = p_user_id and status = 'active';
  if not found then
    raise exception '참가 중인 방이 아닙니다.' using errcode = 'P0001';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 관리자 강퇴
-- ---------------------------------------------------------------------
create or replace function public.admin_kick_member(p_user_id uuid, p_room_id uuid, p_member_id uuid)
returns void language plpgsql as $$
begin
  perform public.assert_admin(p_user_id);
  update public.room_members
     set status = 'kicked', left_at = now()
   where id = p_member_id and room_id = p_room_id and status <> 'kicked';
  if not found then
    raise exception '참가자를 찾을 수 없습니다.' using errcode = 'P0001';
  end if;
end $$;

-- =====================================================================
-- 권한: public 스키마의 모든 함수는 서버(service_role)만 실행 가능.
-- 단, RLS 정책에서 쓰는 도우미 함수는 로그인 사용자도 실행할 수 있어야 함.
-- (이 블록은 이후 마이그레이션 파일 끝에도 반복됩니다)
-- =====================================================================
revoke execute on all functions in schema public from public, anon, authenticated;
grant  execute on all functions in schema public to service_role;
grant  execute on function public.is_admin(), public.is_room_member(uuid),
                           public.can_view_room(uuid), public.is_my_player(uuid)
  to authenticated;
