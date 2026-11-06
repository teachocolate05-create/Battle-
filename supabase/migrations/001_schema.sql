-- =====================================================================
-- 001_schema.sql : 전체 테이블 + RLS(읽기 권한) + Realtime 설정
-- 실행 위치: Supabase 대시보드 > SQL Editor > New query > 붙여넣기 > Run
-- 주의: 처음 한 번만 실행하세요. (이미 테이블이 있으면 오류가 납니다)
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 관리자 (관리자 코드를 통과한 사용자)
-- ---------------------------------------------------------------------
create table public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 전투방
-- ---------------------------------------------------------------------
create table public.rooms (
  id                uuid primary key default gen_random_uuid(),
  room_code         text not null unique,
  room_name         text not null check (char_length(room_name) between 1 and 50),
  description       text not null default '' check (char_length(description) <= 500),
  has_password      boolean not null default false,
  status            text not null default 'waiting'
                    check (status in ('waiting', 'in_progress', 'ended')),
  max_players       int  not null default 10 check (max_players between 1 and 10),
  turn_duration     int  not null default 180 check (turn_duration in (180, 300, 420)),
  first_side        text check (first_side in ('players', 'enemies')),
  current_cycle     int  not null default 0,
  current_phase_id  uuid,
  battle_started_at timestamptz,
  battle_ended_at   timestamptz,
  result            text check (result in ('victory', 'defeat', 'all_escaped', 'forced')),
  end_reason        text,
  archive_status    text not null default 'none'
                    check (archive_status in ('none', 'pending', 'saved', 'failed')),
  archive_error     text,
  created_by        uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- 비밀번호 해시는 별도 테이블 (아무도 읽을 수 없음)
create table public.room_secrets (
  room_id       uuid primary key references public.rooms(id) on delete cascade,
  password_hash text not null
);

-- ---------------------------------------------------------------------
-- 참가자 (게스트). 관리자는 여기에 들어가지 않으므로 인원에 포함되지 않음.
-- ---------------------------------------------------------------------
create table public.room_members (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references public.rooms(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  nickname   text not null check (char_length(nickname) between 1 and 20),
  role       text not null default 'guest' check (role in ('guest')),
  status     text not null default 'active' check (status in ('active', 'left', 'kicked')),
  joined_at  timestamptz not null default now(),
  left_at    timestamptz,
  unique (room_id, user_id)            -- 한 사용자 = 한 방에 캐릭터 1개
);
-- 같은 방 활성 참가자끼리 닉네임 중복 금지 (대소문자 무시)
create unique index room_members_active_nickname_uq
  on public.room_members (room_id, lower(nickname)) where status = 'active';
create index room_members_user_idx on public.room_members (user_id);

-- ---------------------------------------------------------------------
-- 플레이어 캐릭터 (참가자 1명당 1개)
-- ---------------------------------------------------------------------
create table public.players (
  id                 uuid primary key default gen_random_uuid(),
  room_id            uuid not null references public.rooms(id) on delete cascade,
  member_id          uuid not null unique references public.room_members(id) on delete cascade,
  display_name       text not null check (char_length(display_name) between 1 and 20),
  max_hp             int  not null default 100 check (max_hp between 1 and 99999),
  current_hp         int  not null default 100 check (current_hp >= 0),
  min_attack         int  not null default 5   check (min_attack >= 0),
  max_attack         int  not null default 10  check (max_attack >= 0),
  dodge_rate         int  not null default 30  check (dodge_rate between 0 and 100),
  escape_rate        int  not null default 20  check (escape_rate between 0 and 100),
  status             text not null default 'alive' check (status in ('alive', 'dead', 'escaped')),
  total_damage_dealt int  not null default 0,
  total_damage_taken int  not null default 0,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (min_attack <= max_attack),
  check (current_hp <= max_hp)
);
create index players_room_idx on public.players (room_id);

-- ---------------------------------------------------------------------
-- 적군 (방당 최대 5명 — 등록 함수에서 검증)
-- ---------------------------------------------------------------------
create table public.enemies (
  id                 uuid primary key default gen_random_uuid(),
  room_id            uuid not null references public.rooms(id) on delete cascade,
  name               text not null check (char_length(name) between 1 and 30),
  description        text not null default '' check (char_length(description) <= 500),
  max_hp             int  not null default 100 check (max_hp between 1 and 99999),
  current_hp         int  not null default 100 check (current_hp >= 0),
  min_attack         int  not null default 1 check (min_attack >= 0),
  max_attack         int  not null default 4 check (max_attack >= 0),
  dodge_rate         int  not null default 0 check (dodge_rate between 0 and 100),
  defense            int  not null default 0 check (defense >= 0),
  target_type        text not null default 'random' check (target_type in ('all', 'random', 'specific')),
  target_player_id   uuid references public.players(id) on delete set null,
  appearance_message text not null default '' check (char_length(appearance_message) <= 300),
  appearance_status  text not null default 'registered' check (appearance_status in ('registered', 'appeared')),
  appearance_order   int,
  appeared_at        timestamptz,
  status             text not null default 'alive' check (status in ('alive', 'dead')),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (min_attack <= max_attack),
  check (current_hp <= max_hp)
);
create index enemies_room_idx on public.enemies (room_id);

-- ---------------------------------------------------------------------
-- 아이템 / 인벤토리
-- ---------------------------------------------------------------------
create table public.items (
  id           uuid primary key default gen_random_uuid(),
  room_id      uuid not null references public.rooms(id) on delete cascade,
  name         text not null check (char_length(name) between 1 and 30),
  description  text not null default '' check (char_length(description) <= 300),
  item_type    text not null check (item_type in ('heal', 'damage')),
  effect_value int  not null check (effect_value between 1 and 99999),
  created_at   timestamptz not null default now()
);
create index items_room_idx on public.items (room_id);

create table public.player_inventory (
  id        uuid primary key default gen_random_uuid(),
  room_id   uuid not null references public.rooms(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  item_id   uuid not null references public.items(id) on delete cascade,
  quantity  int  not null default 0 check (quantity >= 0),
  unique (player_id, item_id)
);
create index player_inventory_room_idx on public.player_inventory (room_id);

-- ---------------------------------------------------------------------
-- 사이클 / 단계
-- ---------------------------------------------------------------------
create table public.battle_cycles (
  id           uuid primary key default gen_random_uuid(),
  room_id      uuid not null references public.rooms(id) on delete cascade,
  cycle_number int  not null check (cycle_number >= 1),
  status       text not null default 'in_progress' check (status in ('in_progress', 'completed', 'aborted')),
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  unique (room_id, cycle_number)
);

create table public.battle_phases (
  id                   uuid primary key default gen_random_uuid(),
  room_id              uuid not null references public.rooms(id) on delete cascade,
  cycle_id             uuid not null references public.battle_cycles(id) on delete cascade,
  cycle_number         int  not null,
  phase_number         int  not null check (phase_number between 1 and 4),
  phase_type           text not null check (phase_type in ('turn', 'reaction')),
  acting_side          text not null check (acting_side in ('players', 'enemies')),
  response_to_phase_id uuid references public.battle_phases(id) on delete set null,
  started_at           timestamptz not null default now(),
  ends_at              timestamptz,            -- 플레이어 단계만 (서버 기준 마감 시각)
  resolved_at          timestamptz,
  status               text not null default 'open' check (status in ('open', 'resolved', 'aborted')),
  unique (cycle_id, phase_number)
);
create index battle_phases_room_idx on public.battle_phases (room_id);
create index battle_phases_open_idx on public.battle_phases (ends_at) where status = 'open';

alter table public.rooms
  add constraint rooms_current_phase_fk
  foreign key (current_phase_id) references public.battle_phases(id) on delete set null;

-- ---------------------------------------------------------------------
-- 행동 (판정 전에는 본인만 읽기 가능)
-- ---------------------------------------------------------------------
create table public.actions (
  id           uuid primary key default gen_random_uuid(),
  room_id      uuid not null references public.rooms(id) on delete cascade,
  phase_id     uuid not null references public.battle_phases(id) on delete cascade,
  player_id    uuid not null references public.players(id) on delete cascade,
  action_type  text not null check (action_type in ('attack', 'dodge', 'item', 'escape')),
  target_id    uuid,          -- 공격/피해 아이템 대상 적군
  item_id      uuid references public.items(id) on delete set null,
  submitted_at timestamptz not null default now(),
  resolved_at  timestamptz,
  status       text not null default 'submitted' check (status in ('submitted', 'resolved', 'invalid')),
  result       jsonb,
  unique (phase_id, player_id)          -- 단계당 1회, 최초 제출만 접수
);

-- 제출 여부만 공개 (행동 종류 없음)
create table public.phase_submissions (
  phase_id     uuid not null references public.battle_phases(id) on delete cascade,
  player_id    uuid not null references public.players(id) on delete cascade,
  room_id      uuid not null references public.rooms(id) on delete cascade,
  submitted_at timestamptz not null default now(),
  primary key (phase_id, player_id)
);
create index phase_submissions_room_idx on public.phase_submissions (room_id);

-- 적군 턴에 선언된 공격 → 플레이어 반응턴에 적용
create table public.pending_attacks (
  id                uuid primary key default gen_random_uuid(),
  room_id           uuid not null references public.rooms(id) on delete cascade,
  declared_phase_id uuid not null references public.battle_phases(id) on delete cascade,
  resolve_phase_id  uuid references public.battle_phases(id) on delete cascade,
  enemy_id          uuid not null references public.enemies(id) on delete cascade,
  target_player_id  uuid not null references public.players(id) on delete cascade,
  attack_power      int  not null,
  status            text not null default 'pending' check (status in ('pending', 'hit', 'dodged', 'cancelled')),
  damage            int,
  created_at        timestamptz not null default now()
);
create index pending_attacks_room_idx on public.pending_attacks (room_id);

-- ---------------------------------------------------------------------
-- 전투 로그 / 시스템 이벤트 / 채팅 (서로 분리)
-- ---------------------------------------------------------------------
create table public.battle_logs (
  id           bigint generated always as identity primary key,   -- 시간 순서 보장
  room_id      uuid not null references public.rooms(id) on delete cascade,
  cycle_id     uuid references public.battle_cycles(id) on delete set null,
  phase_id     uuid references public.battle_phases(id) on delete set null,
  cycle_number int,
  phase_number int,
  actor_type   text check (actor_type in ('player', 'enemy', 'admin', 'system')),
  actor_id     uuid,
  target_type  text check (target_type in ('player', 'enemy')),
  target_id    uuid,
  log_type     text not null,
  content      text not null,
  data         jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);
create index battle_logs_room_idx on public.battle_logs (room_id, id);

create table public.battle_events (
  id            bigint generated always as identity primary key,
  room_id       uuid not null references public.rooms(id) on delete cascade,
  enemy_id      uuid references public.enemies(id) on delete set null,
  event_type    text not null,   -- enemy_appeared, battle_started, battle_ended ...
  event_message text not null,
  event_data    jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);
create index battle_events_room_idx on public.battle_events (room_id, id);

create table public.chat_messages (
  id          bigint generated always as identity primary key,
  room_id     uuid not null references public.rooms(id) on delete cascade,
  sender_id   uuid not null,
  sender_role text not null check (sender_role in ('guest', 'admin')),
  nickname    text not null,
  message     text not null check (char_length(message) between 1 and 300),
  created_at  timestamptz not null default now()
);
create index chat_messages_room_idx on public.chat_messages (room_id, id);

-- ---------------------------------------------------------------------
-- 종료된 전투 기록 (rooms 와 FK 없음 → 방을 삭제해도 남음)
-- ---------------------------------------------------------------------
create table public.battle_results (
  id               uuid primary key default gen_random_uuid(),
  room_id          uuid not null unique,         -- 중복 저장 방지
  result           text not null,
  total_cycles     int  not null default 0,
  total_phases     int  not null default 0,
  duration_seconds int  not null default 0,
  result_data      jsonb not null default '{}'::jsonb,
  saved_at         timestamptz not null default now()
);

create table public.battle_archives (
  id                 uuid primary key default gen_random_uuid(),
  room_id            uuid not null unique,       -- 중복 저장 방지
  battle_result_id   uuid not null references public.battle_results(id) on delete cascade,
  room_name_snapshot text not null,
  started_at         timestamptz,
  ended_at           timestamptz,
  result             text not null,
  first_side         text,
  archive_data       jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now()
);
create index battle_archives_created_idx on public.battle_archives (created_at desc);

-- =====================================================================
-- RLS 도우미 함수
-- =====================================================================
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public.is_room_member(p_room_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.room_members
    where room_id = p_room_id and user_id = auth.uid() and status = 'active'
  );
$$;

create or replace function public.can_view_room(p_room_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.is_room_member(p_room_id);
$$;

create or replace function public.is_my_player(p_player_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.players p
    join public.room_members m on m.id = p.member_id
    where p.id = p_player_id and m.user_id = auth.uid() and m.status = 'active'
  );
$$;

-- =====================================================================
-- RLS: 모든 테이블 활성화. 브라우저에는 SELECT 정책만 존재 (쓰기 불가)
-- =====================================================================
alter table public.admins            enable row level security;
alter table public.rooms             enable row level security;
alter table public.room_secrets      enable row level security;
alter table public.room_members      enable row level security;
alter table public.players           enable row level security;
alter table public.enemies           enable row level security;
alter table public.items             enable row level security;
alter table public.player_inventory  enable row level security;
alter table public.battle_cycles     enable row level security;
alter table public.battle_phases     enable row level security;
alter table public.actions           enable row level security;
alter table public.phase_submissions enable row level security;
alter table public.pending_attacks   enable row level security;
alter table public.battle_logs       enable row level security;
alter table public.battle_events     enable row level security;
alter table public.chat_messages     enable row level security;
alter table public.battle_results    enable row level security;
alter table public.battle_archives   enable row level security;

create policy admins_select_self on public.admins
  for select to authenticated using (user_id = auth.uid());

create policy rooms_select on public.rooms
  for select to authenticated using (public.can_view_room(id));

-- room_secrets: 정책 없음 → 아무도 읽을 수 없음

create policy room_members_select on public.room_members
  for select to authenticated using (public.can_view_room(room_id) or user_id = auth.uid());

create policy players_select on public.players
  for select to authenticated using (public.can_view_room(room_id));

-- 게스트는 등장한 적군만 볼 수 있음
create policy enemies_select on public.enemies
  for select to authenticated using (
    public.is_admin() or (public.is_room_member(room_id) and appearance_status = 'appeared')
  );

create policy items_select on public.items
  for select to authenticated using (public.can_view_room(room_id));

create policy player_inventory_select on public.player_inventory
  for select to authenticated using (public.is_admin() or public.is_my_player(player_id));

create policy battle_cycles_select on public.battle_cycles
  for select to authenticated using (public.can_view_room(room_id));

create policy battle_phases_select on public.battle_phases
  for select to authenticated using (public.can_view_room(room_id));

-- 행동: 본인 것만 (관리자도 타인의 행동 조회 불가)
create policy actions_select_own on public.actions
  for select to authenticated using (public.is_my_player(player_id));

create policy phase_submissions_select on public.phase_submissions
  for select to authenticated using (public.can_view_room(room_id));

create policy pending_attacks_select on public.pending_attacks
  for select to authenticated using (public.can_view_room(room_id));

create policy battle_logs_select on public.battle_logs
  for select to authenticated using (public.can_view_room(room_id));

create policy battle_events_select on public.battle_events
  for select to authenticated using (public.can_view_room(room_id));

create policy chat_messages_select on public.chat_messages
  for select to authenticated using (public.can_view_room(room_id));

create policy battle_results_select on public.battle_results
  for select to authenticated using (public.is_admin());

create policy battle_archives_select on public.battle_archives
  for select to authenticated using (public.is_admin());

-- 익명(로그인 전) 역할은 아무 테이블도 못 읽게
revoke all on all tables in schema public from anon;

-- =====================================================================
-- Realtime: 변경 알림을 받을 테이블 등록 (RLS가 적용되어 같은 방 데이터만 전달)
-- =====================================================================
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array[
      'rooms', 'room_members', 'players', 'enemies', 'items', 'player_inventory',
      'battle_phases', 'phase_submissions', 'pending_attacks',
      'battle_logs', 'battle_events', 'chat_messages'
    ] loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
      ) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;
