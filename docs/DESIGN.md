# 멀티플레이어 턴제 전투 웹사이트 — 설계 문서

> v2 통합 수정 사항은 [`CHANGES_V2.md`](CHANGES_V2.md) 에 정리되어 있으며, 이 문서보다 우선합니다.
> (특히: 결과 공개 방식, 관리자의 판정 전 행동 열람, 관리자 메뉴 구성, 예약 작업 1초 주기)

이 문서는 전체 구조, 데이터베이스, 서버 API, 전투 규칙을 정의합니다.
이후 모든 단계(3~8단계)는 이 문서를 기준으로 구현합니다.

---

## 1. 전체 구조

```
브라우저 (PC/모바일)
 ├─ Supabase Auth (익명 로그인)  → 브라우저마다 고유 사용자 ID 발급, 새로고침해도 유지
 ├─ Supabase Realtime 구독       → "데이터가 바뀌었다" 신호 수신 (RLS로 같은 방 데이터만)
 └─ Next.js API 호출 (/api/...)   → 모든 쓰기/판정 요청
        │  Authorization: Bearer <사용자 토큰>
        ▼
Next.js 서버 (Vercel)
 ├─ 토큰 검증 → 사용자 확인, 관리자 여부 확인
 └─ Supabase DB 함수(RPC) 호출 (서버 전용 secret key 사용)
        ▼
Supabase PostgreSQL
 ├─ 테이블 + RLS (읽기만 허용, 쓰기는 서버 함수만 가능)
 ├─ 게임 판정 함수 (PL/pgSQL, 트랜잭션 + 행 잠금으로 중복 판정 방지)
 └─ pg_cron: 5초마다 battle_tick() 실행 → 제한 시간이 끝난 단계 자동 판정
```

### 왜 이렇게 설계했나

| 요구사항 | 해결 방법 |
|---|---|
| 판정은 반드시 서버에서 | HP·피해·회피·도주·타이머 계산은 모두 DB 함수에서 실행. 브라우저는 "행동 X를 제출" 요청만 보냄 |
| 클라이언트가 임의 변경 불가 | 모든 테이블에 RLS 적용, 브라우저용 키로는 **SELECT만** 가능. INSERT/UPDATE/DELETE 정책 없음 |
| 중복 판정 방지 | 판정 함수가 `SELECT ... FOR UPDATE`로 방을 잠그고, 단계 상태가 `open`일 때만 판정 |
| 서버 기준 타이머 | `battle_phases.started_at / ends_at`을 DB에 저장. pg_cron이 5초마다 만료 단계 판정. 브라우저 타이머는 표시용 |
| 판정 전 행동 비공개 | `actions` 테이블은 RLS로 **본인 행동만** 읽기 가능 (관리자 포함 타인 불가). 제출 여부는 행동 종류가 없는 `phase_submissions` 테이블로 공개 |
| 관리자 코드 비노출 | `ADMIN_CODE`는 서버 환경 변수. 브라우저 코드에 포함되지 않음 |
| 새로고침 복구 | 익명 로그인 세션이 브라우저에 저장됨 → 같은 사용자 ID로 방 상태 전체를 서버에서 다시 받아옴 |
| 미등장 적군 숨김 | `enemies` RLS: 게스트는 `appearance_status = 'appeared'`인 적군만 읽을 수 있음 (화면 숨김이 아닌 DB 차단) |

---

## 2. 폴더 구조

```
battle-arena/
├─ docs/DESIGN.md                  ← 이 문서
├─ supabase/
│  ├─ migrations/                  ← Supabase SQL Editor에서 번호 순서대로 실행
│  │  ├─ 001_schema.sql            (전체 테이블 + RLS + Realtime)      [2단계]
│  │  ├─ 002_room_functions.sql    (방 생성/입장/퇴장/강퇴 함수)       [2단계]
│  │  ├─ 003_setup_functions.sql   (능력치/적군/아이템/선공)           [3단계]
│  │  ├─ 004_battle_engine.sql     (사이클/단계/판정/승패 + pg_cron 5초 예약)  [4단계]
│  │  ├─ 005_room_state.sql        (방 상태를 한 번의 질의로 조립)       [4단계]
│  │  ├─ 006_chat.sql              (채팅 전송/스팸 방지 + 기록 페이지 조회) [5·6단계]
│  │  └─ 007_archive.sql           (자동 기록 저장 + 재시도 + 삭제 보호)   [7단계]
│  └─ tests/                       ← 로컬 PostgreSQL로 함수 동작 검증용
├─ src/
│  ├─ app/
│  │  ├─ page.tsx                  게스트 입장 화면 (홈)
│  │  ├─ room/[roomId]/page.tsx    게스트 전투방 화면
│  │  ├─ admin/page.tsx            관리자 로그인 + 전투방 목록/생성
│  │  ├─ admin/rooms/[roomId]/     관리자 전투방 관리 화면
│  │  └─ api/                      서버 API (아래 5장)
│  ├─ components/                  공통 UI (카드, 탭, HP 바 등)
│  └─ lib/
│     ├─ supabase/client.ts        브라우저용 Supabase (publishable key)
│     ├─ supabase/admin.ts         서버 전용 Supabase (secret key, 브라우저 번들에 포함 불가)
│     ├─ auth.ts                   서버: 요청 토큰 검증, 관리자 확인
│     ├─ api.ts                    서버: 응답/에러 처리 공통 함수
│     ├─ apiClient.ts              브라우저: 토큰 붙여서 API 호출
│     └─ types.ts                  공통 타입
└─ .env.local                      환경 변수 (git에 올리지 않음)
```

---

## 3. 데이터베이스 설계

요청서 17장의 테이블을 기본으로 하고, 보안과 판정을 위해 몇 개를 추가했습니다.

### 추가/변경한 부분과 이유

| 변경 | 이유 |
|---|---|
| `admins` 추가 | 관리자 코드를 통과한 사용자 ID를 저장. 서버와 RLS가 관리자 여부를 판단 |
| `room_secrets` 추가 (password_hash 이동) | `rooms`는 참가자가 읽을 수 있으므로 비밀번호 해시를 별도 테이블(아무도 못 읽음)로 분리 |
| `phase_submissions` 추가 | "제출 완료/대기"만 공개하기 위한 테이블. 행동 종류 없음 |
| `pending_attacks` 추가 | 적군 턴에 선언된 공격. 플레이어 반응턴(회피/도주)의 결과를 반영해 적용 |
| `battle_logs.data`, `battle_events.event_data` (jsonb) | 공격력, 회피 결과, HP 변화 등 상세 수치 저장 → 기록 보관함에서 재사용 |
| `battle_results`, `battle_archives`는 rooms와 FK 없음 | 방을 삭제해도 기록이 지워지지 않도록 |
| `rooms`에 전투 진행 컬럼 추가 | current_cycle, current_phase_id, battle_started_at/ended_at, result, end_reason, archive_status |
| `players`에 display_name, 누적 피해 컬럼 | 플레이어 이름 설정, 기록 저장용 누적 피해량 |
| `enemies`에 appearance_order | 등장 순서 기록 |

### 테이블 목록 (상세는 `supabase/migrations/001_schema.sql`)

```
admins            user_id, created_at
rooms             id, room_code, room_name, description, has_password, status(waiting/in_progress/ended),
                  max_players, turn_duration(180/300/420초), first_side(players/enemies),
                  current_cycle, current_phase_id, battle_started_at, battle_ended_at,
                  result(victory/defeat/all_escaped/forced), end_reason, archive_status, created_by, created_at
room_secrets      room_id, password_hash                         ← 아무도 SELECT 불가
room_members      id, room_id, user_id, nickname, role, status(active/left/kicked), joined_at, left_at
players           id, room_id, member_id, display_name, max_hp, current_hp, min_attack, max_attack,
                  dodge_rate, escape_rate, status(alive/dead/escaped), total_damage_dealt, total_damage_taken
enemies           id, room_id, name, description, max_hp, current_hp, min_attack, max_attack,
                  dodge_rate, defense, target_type(all/random/specific), target_player_id,
                  appearance_message, appearance_status(registered/appeared), appearance_order,
                  appeared_at, status(alive/dead)
items             id, room_id, name, description, item_type(heal/damage), effect_value
player_inventory  id, room_id, player_id, item_id, quantity
battle_cycles     id, room_id, cycle_number, status, started_at, ended_at
battle_phases     id, room_id, cycle_id, cycle_number, phase_number(1~4), phase_type(turn/reaction),
                  acting_side(players/enemies), response_to_phase_id, started_at, ends_at, resolved_at, status
actions           id, room_id, phase_id, player_id, action_type(attack/dodge/item/escape),
                  target_id, item_id, submitted_at, resolved_at, status, result   ← 본인만 SELECT
phase_submissions phase_id, player_id, room_id, submitted_at      ← 제출 여부만 공개
pending_attacks   id, room_id, declared_phase_id, resolve_phase_id, enemy_id, target_player_id,
                  attack_power, status(pending/hit/dodged/cancelled), damage
battle_logs       id, room_id, cycle_id, phase_id, cycle_number, phase_number, actor_type, actor_id,
                  target_type, target_id, log_type, content, data, created_at
battle_events     id, room_id, enemy_id, event_type, event_message, event_data, created_at
chat_messages     id, room_id, sender_id, sender_role, nickname, message, created_at
battle_results    id, room_id(UNIQUE, FK 없음), result, total_cycles, total_phases, duration_seconds,
                  result_data, saved_at
battle_archives   id, room_id(UNIQUE, FK 없음), battle_result_id, room_name_snapshot, started_at,
                  ended_at, result, first_side, archive_data, created_at
```

### 데이터 분리 원칙
- 채팅 → `chat_messages` / 행동 → `actions` / 전투 로그 → `battle_logs` / 시스템 이벤트 → `battle_events` / 종료 기록 → `battle_results`, `battle_archives`
- 적군 등장 메시지는 `battle_events`에 저장하고, 채팅 화면은 `chat_messages` + `battle_events`를 시간순으로 합쳐서 보여줍니다 (채팅 테이블에 중복 저장하지 않음).

### RLS (읽기 권한) 요약
- 모든 테이블 RLS 활성화. 브라우저 키로는 **쓰기 정책이 하나도 없음** → 쓰기는 서버 함수만 가능.
- 같은 방의 활성 참가자 또는 관리자만 해당 방 데이터 읽기 가능.
- `enemies`: 게스트는 등장한 적군만.
- `actions`: 본인 행동만 (관리자도 불가).
- `player_inventory`: 본인 인벤토리 + 관리자.
- `room_secrets`: 아무도 불가.
- `battle_results`, `battle_archives`: 관리자만.

---

## 4. 전투 규칙 (서버 판정 기준)

### 4-1. 사이클과 단계
| 선공 | 1단계 | 2단계 | 3단계 | 4단계 |
|---|---|---|---|---|
| 플레이어 선공 | 플레이어 선공턴 | 적군 반응턴 | 적군 후공턴 | 플레이어 반응턴 |
| 적군 선공 | 적군 선공턴 | 플레이어 반응턴 | 플레이어 후공턴 | 적군 반응턴 |

- 화면 묶음: [1단계 + 2단계], [3단계 + 4단계] — 이를 "교환(exchange)"이라고 부릅니다.
- 플레이어 단계: 제한 시간(3/5/7분) 동안 행동 제출. 모두 제출해도 시간 종료까지 대기. 관리자 조기 판정 가능.
- 적군 단계: 제한 시간 없이 서버가 즉시 자동 판정 후 다음 단계로 진행.

### 4-2. 회피와 반응턴 (요청서의 모호한 부분을 이렇게 정했습니다)
"회피 효과는 해당 단계의 공격 판정에만 적용"을 다음과 같이 해석합니다.
**회피는 같은 교환(턴 + 반응턴) 안에서 그 플레이어가 받는 적군 공격에 적용됩니다.**

- **플레이어 턴 → 적군 반응턴**: 플레이어가 턴에서 회피를 선택하면, 바로 이어지는 적군 반응턴의 반격에 대해 회피 판정을 합니다.
- **적군 턴 → 플레이어 반응턴**: 적군 턴에서 적군은 공격 대상과 공격력을 **선언**합니다(`pending_attacks`, 로그 공개).
  플레이어는 반응턴에서 이 공격을 보고 회피/도주/공격/아이템을 선택합니다. 반응턴 판정 시 선언된 공격이 적용됩니다.

### 4-3. 플레이어 단계 판정 순서
1. 도주 판정 (성공 시 이탈 → 이후 공격 대상 제외, 선언된 공격도 취소)
2. (적군 턴에 대한 반응턴일 때만) 선언된 적군 공격 적용 — 회피 선택자는 공격마다 회피율로 판정
3. 살아 있는 플레이어의 아이템 사용 (제출 순서대로)
4. 살아 있는 플레이어의 일반 공격 (제출 순서대로)
   공격력 = min~max 무작위 → 적군 회피 판정 → 방어력 차감 → 최종 피해(0 미만 불가) → HP 감소 → 사망 확인
- 적군 고정 피해 아이템은 회피/방어력 무시.
- 공격 대상 적군이 이미 사망했으면 그 공격은 무효 처리(로그에 기록).
- 미제출 플레이어는 아무 행동도 하지 않음(자동 공격/회피/도주 없음). 공격 대상은 될 수 있음.
- 단계 도중 사망한 플레이어의 남은 행동은 무효.

### 4-4. 적군 단계 판정
- 등장했고 살아 있는 적군만 행동. 각 적군 독립 판정.
- 대상: 생존 플레이어 전체 / 무작위 1명 / 특정 플레이어(사망·도주 시 무작위 1명으로 대체).
- 반응턴(플레이어 턴에 대한 반격): 즉시 피해 적용. 직전 플레이어 턴에서 회피를 선택한 대상은 회피 판정.
- 턴(선공/후공): 공격 선언만 하고, 다음 플레이어 반응턴에 적용.

### 4-4-1. 구현 세부 (4단계)
- 진행 엔진 `progress_room`: 방 행을 `FOR UPDATE`로 잠그고 → 판정할 단계가 있으면 판정 → 승패 확인 → 다음 단계 열기. 적군 단계는 연속 자동 처리.
  pg_cron(5초), 브라우저 타이머 0초 요청, 관리자 조기 판정이 동시에 와도 잠금 때문에 **한 번만** 판정됩니다.
- 판정 여부는 항상 DB 시각(`now()`)과 `ends_at`으로 결정. 브라우저 시계는 표시용.
- 행동 제출은 방 행을 `FOR SHARE`로 잠금 → 판정 도중에 제출이 끼어들 수 없음. `(phase_id, player_id)` UNIQUE로 최초 1회만 접수.
- 상태 조회 `get_room_state`: 하나의 SQL 문으로 전체 상태를 조립 → 한 시점의 스냅샷, 왕복 1회.
- 전투 중 강퇴된 플레이어는 참가자에서 제외(공격 대상 아님). 관리자 HP 조정·강퇴 후에도 승패를 즉시 확인.

### 4-4-2. 로그 표시와 채팅 (5·6단계)
- 서버는 단계마다 따로 기록(`battle_logs.cycle_number / phase_number`), 화면은 사이클 → [1+2단계], [3+4단계] 묶음 → 단계 순으로 표시. 최신 사이클만 펼침.
- 화면은 최근 로그 400개·채팅 200개를 받고, 그 이전은 "이전 기록 더 보기"로 페이지 조회.
- 채팅: 300자, 빈 메시지 금지, 10초에 5개 / 같은 내용 5초 내 반복 금지, 활성 참가자·관리자만, 전투 종료 후 읽기 전용.
  메시지는 원문 그대로 저장하고 화면은 항상 텍스트로 출력(HTML 해석 없음) + 보이지 않는 제어·방향 문자 제거.
- 적군 등장 등 시스템 메시지는 `battle_events`에만 저장, 채팅 화면에서 시간순으로 함께 표시(채팅 테이블에 중복 저장 안 함).
- 탭 독립: 상단 타이머/단계는 탭 바깥, 두 탭 모두 항상 렌더링(숨김만 전환). 채팅 탭에서도 행동 제출 패널 표시.
- 관리자 화면은 어떤 메뉴에서도 채팅이 옆(넓은 화면) 또는 아래(좁은 화면)에 보임 → 스토리 진행 중 바로 적군 등장 가능.

### 4-4-3. 전투 기록 저장 (7단계)
- `end_battle`(승리·패배·전원 도주·강제 종료 공통) 마지막에 `try_save_archive` 자동 호출 → 관리자 조작 불필요.
- 저장 내용: `battle_results.result_data`(요약: 방·참가자·적군·아이템), `battle_archives.archive_data`(요약 + 단계·전투 로그·시스템 이벤트·채팅 전체).
- `room_id` UNIQUE + "이미 저장됨" 확인 → 중복 저장 없음.
- 저장 오류는 하위 트랜잭션에서 잡아서 전투 종료는 유지, `rooms.archive_status = 'failed'` + `archive_error` 기록 → 관리자 [기록 저장 재시도].
  `pending` 상태는 5초 예약 작업(battle_tick)이 다시 저장 시도.
- 종료됐지만 아직 저장되지 않은 방은 삭제 불가 (기록 유실 방지). 저장된 기록은 방 삭제와 무관하게 유지.

### 4-4-4. 배포 (8단계)
- `vercel.json`: 서버 함수 리전 `hnd1`(도쿄) — Supabase(ap-northeast-1, 도쿄)와 같은 지역이라 DB 왕복이 짧음.
- `next.config.ts`: 보안 헤더(CSP: 자기 사이트 + Supabase 로만 통신, iframe 금지, MIME 추측 금지 등). CSP 는 운영 빌드에만 적용.
- 실시간 연결 직후 3초·8초에 한 번 더 상태 확인 (실시간 서버가 막 깨어날 때의 알림 누락 대비). 기본 15초 주기 확인은 유지.

### 4-5. 종료 조건 (매 판정 단계 후 확인)
- 승리: 등록된 적군이 1명 이상이고, **모두 등장 + 모두 사망**.
- 패배: 생존 플레이어 0명 (전원 도주이고 사망자가 없으면 결과는 `all_escaped`).
- 강제 종료: 관리자, 사유 기록 (`forced`).
- 종료 시 남은 단계 중단, 새 적군 등장 불가, 채팅 읽기 전용, 기록 자동 저장.

### 4-6. 전투 설정 규칙 (3단계)
- 능력치: 대기 중에는 전부 수정 가능, 전투 중에는 **현재 HP만** (나머지는 2차 업데이트). HP 0 → 사망, 사망자 HP 회복 → 부활. 모든 HP 변경은 `battle_logs`에 기록.
- 적군: 방당 최대 5명. 등록 ≠ 등장. 등장은 대기 중(스토리 진행)·전투 중 모두 가능, 종료 후 불가. 이미 등장한 적군은 삭제 불가, 사망한 적군은 수정 불가.
- 등장 문구가 비어 있으면 "[이름]이/가 등장했다!" (받침에 맞는 조사 자동 선택).
- 게스트에게는 등장한 적군의 이름·설명·HP만 공개 (공격 대상 설정 등 전략 정보는 숨김).
- 아이템: HP 회복 / 적군 고정 피해 2종, 방당 30종, 지급 수량은 누적(최대 999). 삭제는 전투 시작 전에만.
- 선공 측·턴 시간: 전투 시작 전에만 변경 가능.

### 4-7. 방 운영 규칙 (1차)
- 한 방에서 전투는 1회. (방 재사용/재시작은 2차 확장 가능)
- 새 참가자 입장은 "대기 중"일 때만. 기존 참가자의 재접속은 언제나 가능.
- 강퇴된 사용자는 같은 방에 다시 입장할 수 없음. 스스로 나간 사용자는 다시 입장하면 기존 캐릭터를 복구.
- 진행 중인 전투방은 삭제 불가 (먼저 종료 → 기록 저장 후 삭제).

---

## 5. 서버 API

모든 요청: `Authorization: Bearer <익명 로그인 토큰>`. 관리자 API는 서버에서 `admins` 테이블로 재검증합니다.

| 메서드 | 경로 | 권한 | 설명 | 단계 |
|---|---|---|---|---|
| GET | /api/auth/me | 모두 | 관리자 여부, 참여 중인 방 | 2 ✅ |
| POST | /api/auth/admin | 모두 | 관리자 코드 확인 → 관리자 등록 | 2 ✅ |
| DELETE | /api/auth/admin | 관리자 | 관리자 권한 해제 | 2 ✅ |
| GET | /api/rooms | 관리자 | 전투방 목록 | 2 ✅ |
| POST | /api/rooms | 관리자 | 전투방 생성 + 코드 발급 | 2 ✅ |
| DELETE | /api/rooms/[roomId] | 관리자 | 전투방 삭제 | 2 ✅ |
| POST | /api/rooms/join | 게스트 | 방 코드로 입장 / 재접속 | 2 ✅ |
| GET | /api/rooms/[roomId]/state | 참가자/관리자 | 방 전체 상태 (권한별로 서버에서 필터링) | 2 ✅ (단계마다 확장) |
| POST | /api/rooms/[roomId]/leave | 게스트 | 퇴장 | 2 ✅ |
| POST | /api/rooms/[roomId]/members/[memberId]/kick | 관리자 | 강퇴 | 2 ✅ |
| PATCH | /api/rooms/[roomId]/players/[playerId] | 관리자 | 능력치/HP 수정 | 33 ✅ |
| POST/PATCH/DELETE | /api/rooms/[roomId]/enemies[...] | 관리자 | 적군 등록/수정/삭제 | 33 ✅ |
| POST | /api/rooms/[roomId]/enemies/[enemyId]/appear | 관리자 | 적군 등장 실행 | 33 ✅ |
| POST/DELETE | /api/rooms/[roomId]/items[...] | 관리자 | 아이템 생성/삭제 | 33 ✅ |
| POST | /api/rooms/[roomId]/items/[itemId]/grant | 관리자 | 아이템 지급 | 33 ✅ |
| PATCH | /api/rooms/[roomId]/settings | 관리자 | 선공 측, 턴 시간 등 | 33 ✅ |
| POST | /api/rooms/[roomId]/battle/start | 관리자 | 전투 시작 | 44 ✅ |
| POST | /api/rooms/[roomId]/battle/resolve | 관리자 | 조기 판정 | 44 ✅ |
| POST | /api/rooms/[roomId]/battle/end | 관리자 | 강제 종료 | 44 ✅ |
| POST | /api/rooms/[roomId]/battle/tick | 참가자 | 시간 만료 확인 요청 (서버가 시간 검사, 보조 수단) | 44 ✅ |
| POST | /api/rooms/[roomId]/actions | 게스트 | 행동 제출 | 44 ✅ |
| POST | /api/rooms/[roomId]/chat | 참가자/관리자 | 채팅 전송 | 6 ✅ |
| GET | /api/rooms/[roomId]/history?kind=chat\|logs&before= | 참가자/관리자 | 이전 채팅·로그 더 보기 | 5·6 ✅ |
| GET | /api/archives, /api/archives/[id] | 관리자 | 기록 보관함 | 7 ✅ |
| POST | /api/rooms/[roomId]/archive/retry | 관리자 | 기록 저장 재시도 | 7 ✅ |

---

## 6. 개발 단계와 진행 상황

| 단계 | 내용 | 상태 |
|---|---|---|
| 1 | Next.js + TypeScript + Supabase 연결 + 기본 UI | ✅ 완료 |
| 2 | 관리자 인증, 방 생성/코드/입장/인원 제한/참가자 관리 | ✅ 완료 |
| 3 | 능력치, 적군(최대 5), 등장 연출, 아이템, 선공 설정 | ✅ 완료 |
| 4 | 4단계 사이클, 행동 제출, 서버 판정, 타이머, 승패 | ✅ 완료 |
| 5 | 제출 현황, 판정 후 공개, 사이클별/묶음 로그 | ✅ 완료 |
| 6 | 실시간 채팅, 시스템 메시지, 탭 독립 | ✅ 완료 |
| 7 | 자동 기록 저장, 보관함 | ✅ 완료 |
| 8 | 테스트, Vercel 배포 | ✅ 완료 — https://battle-arena-eta.vercel.app |
