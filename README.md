# ⚔ 턴제 전투 아레나 (1차 구현 완료)

🌐 **사이트: https://battle-arena-eta.vercel.app** · 관리자 화면: `/admin`

관리자가 채팅으로 스토리를 진행하다가 원하는 순간에 적군을 등장시키고, 플레이어들이 4단계 턴제 규칙으로 함께 싸우는 실시간 멀티플레이어 웹사이트입니다.

- 설계 문서: [`docs/DESIGN.md`](docs/DESIGN.md) (구조, DB, API, 전투 규칙)
- 기술: Next.js 15 · TypeScript · Supabase (PostgreSQL, Auth, Realtime) · Vercel

## 현재 진행 상황

| 단계 | 상태 |
|---|---|
| 1. 기본 프로젝트 (Next.js, Supabase 연결, 기본 UI) | ✅ 완료 |
| 2. 관리자 인증, 방 생성/코드/입장/인원 제한/참가자 관리 | ✅ 완료 |
| 3. 플레이어 능력치, 적군(최대 5명) 등록·등장 연출, 아이템 생성·지급, 선공 설정 | ✅ 완료 |
| 4. 턴제 전투 (4단계 사이클, 행동 제출, 서버 판정, 서버 타이머 + 자동 판정, 승패, 조기 판정, 강제 종료) | ✅ 완료 |
| 5. 전투 로그 (사이클별, [턴 + 반응턴] 묶음, 이전 기록 더 보기) | ✅ 완료 |
| 6. 실시간 채팅 (시스템 메시지, 스팸 방지, 읽기 전용, 탭 독립) | ✅ 완료 |
| 7. 전투 기록 자동 저장 + 기록 보관함 (목록, 상세: 로그·채팅·참가자·적군 등장) | ✅ 완료 |
| 8. 배포 준비(보안 헤더, 도쿄 리전, 운영 빌드 전체 테스트, 기기별 화면 점검) | ✅ 완료 |
| 8. Vercel 배포 (HTTPS, 도쿄 리전, main 브랜치 자동 배포) | ✅ 완료 — **https://battle-arena-eta.vercel.app** |

---

## 처음 설정하기 (사용자님이 직접 하는 작업)

### ① Supabase 프로젝트 만들기
1. https://supabase.com 접속 → 로그인 → **New project**
2. 이름 아무거나, 데이터베이스 비밀번호 입력(따로 보관), Region은 **Northeast Asia (Seoul)** 추천 → Create

### ② 익명 로그인 켜기 (필수)
대시보드 왼쪽 **Authentication → Sign In / Providers** → **Allow anonymous sign-ins** 켜기 → Save

> 게스트가 회원가입 없이 접속해도 브라우저마다 고유 ID가 생겨서, 새로고침해도 같은 캐릭터로 복구됩니다.

### ③ 데이터베이스 만들기 (SQL 실행)
왼쪽 **SQL Editor → New query** 에서 아래 파일 내용을 **순서대로** 하나씩 붙여넣고 **Run**:

1. `supabase/migrations/001_schema.sql` — 테이블, 보안(RLS), 실시간 설정
2. `supabase/migrations/002_room_functions.sql` — 방 생성/입장 등 서버 함수
3. `supabase/migrations/003_setup_functions.sql` — 능력치/적군/아이템/선공 설정 함수
4. `supabase/migrations/004_battle_engine.sql` — 전투 엔진 + 5초마다 자동 판정 예약(pg_cron)
5. `supabase/migrations/005_room_state.sql` — 화면 상태 조회 함수
6. `supabase/migrations/006_chat.sql` — 채팅 + 이전 기록 조회 함수
7. `supabase/migrations/007_archive.sql` — 전투 기록 자동 저장

주의사항
- 반드시 **번호 순서대로** 실행하세요.
- 001은 **한 번만** 실행합니다. 두 번 실행하면 "already exists" 오류가 나는데, 이미 만들어졌다는 뜻이므로 무시해도 됩니다.
- 002 이후 파일은 여러 번 실행해도 안전합니다.
- `supabase/tests/` 폴더의 파일은 테스트 전용입니다. **Supabase에서 실행하지 마세요.**

### ④ 환경 변수 설정
프로젝트 폴더에서 `.env.example` 을 복사해서 `.env.local` 을 만들고 값을 채웁니다.

```bash
cp .env.example .env.local
```

| 변수 | 어디서 찾나요 |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Project Settings → Data API → **Project URL** |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Project Settings → API Keys → **Publishable key** (예전 화면: `anon` `public`) |
| `SUPABASE_SECRET_KEY` | Project Settings → API Keys → **Secret key** (예전 화면: `service_role`) ⚠ 절대 공유 금지 |
| `ADMIN_CODE` | 직접 정하는 관리자 비밀 문구 (8자 이상 권장) |

### ⑤ 실행

```bash
npm install
```

```bash
npm run dev
```

브라우저에서 http://localhost:3000 접속 → 화면 아래에 **✅ 서버 연결 정상**이 보이면 1단계 확인 끝입니다.
❌ 가 보이면 그 줄에 적힌 안내대로 고치세요.

---

## 2단계 확인 방법

### 자동 테스트 (가상 사용자 4명)
`npm run dev` 를 켜 둔 상태에서 **다른 터미널**에서:

```bash
npm run test:stage2
```

`🎉 2단계 테스트 N개 모두 통과` 가 나오면 성공입니다. 입장, 인원 제한, 중복 닉네임, 강퇴, 보안(RLS), 실시간 알림을 실제 Supabase로 확인합니다. 테스트용 방은 자동으로 삭제됩니다.

### 직접 여러 명으로 확인
같은 브라우저는 같은 사용자로 인식되므로 **창 종류를 다르게** 여세요.

1. 일반 창: http://localhost:3000/admin → 관리자 코드 입력 → 전투방 생성 → 코드 복사
2. 시크릿 창: http://localhost:3000 → 닉네임 + 코드 입력 → 입장
3. 다른 브라우저(또는 휴대폰): 다른 닉네임으로 입장
4. 관리자 화면 **2. 참가자 관리**에 새로고침 없이 참가자가 나타나는지 확인
5. 강퇴 → 강퇴된 화면에 "강퇴되었습니다"가 표시되는지 확인
6. 게스트 창 새로고침 → 같은 캐릭터로 돌아오는지 확인

> 휴대폰으로 테스트하려면 PC와 같은 와이파이에서 `http://PC의IP:3000` 으로 접속하세요. (익명 로그인은 IP당 시간당 30회로 제한되므로, 테스트를 아주 많이 반복하면 잠시 막힐 수 있습니다.)

## 3단계 확인 방법

```bash
npm run test:stage3
```

직접 확인: 관리자 화면에서 **4. 적군 관리 → + 적군 등록** → 게스트 화면에는 아직 안 보이는지 확인 → **⚡ 등장시키기** → 게스트 화면에 큰 등장 배너와 적군 카드, 채팅 탭에 시스템 메시지가 나타나는지 확인.
**3. 플레이어 능력치**, **5. 아이템 관리(지급)** 도 게스트 화면에 새로고침 없이 반영됩니다.

## 4단계 확인 방법

```bash
npm run test:stage4
```

실제 3분 제한 시간이 끝날 때까지 기다려서, **브라우저 없이도 서버가 자동 판정하는지** 확인합니다. (약 4분 소요)
빨리 확인하려면 `npm run test:stage4 -- http://localhost:3000 --skip-wait` (조기 판정으로 대체)

직접 확인 순서 (창 3개: 관리자 + 게스트 2명)
1. 관리자: 적군 등록 → 등장 → **6. 선공 측 설정** 저장 → **7. 전투 진행 제어 → ⚔ 전투 시작**
2. 게스트: 상단 타이머 확인 → **일반 공격 → 대상 선택 → 제출**
3. 다른 게스트 화면에는 "행동 제출 완료"만 보이고, 무엇을 골랐는지는 안 보이는지 확인
4. 시간 종료(또는 관리자 **⏩ 조기 판정**) 후 전투 로그에 모든 행동과 결과가 공개되는지 확인
5. 적군 턴 다음 반응턴에 "⚠ 다가오는 적군의 공격" 카드가 나오는지, 회피·도망으로 대응되는지 확인

> 자동 판정: Supabase의 pg_cron 이 5초마다 `battle_tick()` 을 실행합니다. 004 를 실행하면 자동으로 등록됩니다.
> 확인: SQL Editor 에서 `select * from cron.job;` → `battle-tick` 이 보이면 정상.

## 5·6단계 확인 방법

```bash
npm run test:stage56
```

직접 확인: 관리자 화면 오른쪽(모바일은 아래) **💬 채팅 · 스토리 진행**에서 이야기를 쓰다가 **⚡ 등장시키기** →
게스트 채팅 탭에 일반 채팅과 구분된 시스템 메시지가 나오는지, 전투 탭에 있으면 채팅 탭에 빨간 숫자(안 읽은 메시지)가 뜨는지 확인.
게스트가 채팅 탭에 있어도 타이머가 흐르고 행동을 제출할 수 있습니다. 관리자 **8. 전투 로그**에서 사이클별 묶음 로그를 확인하세요.

## 7단계 확인 방법

```bash
npm run test:stage7
```

직접 확인: 전투를 끝까지 진행(또는 강제 종료) → **7. 전투 진행 제어**에 "✅ 전투 기록 저장 완료" →
관리자 홈 또는 **9. 전투 기록 보관함 → 📜 보관함 열기** → 상세 보기에서 전투 로그 / 채팅 기록 / 참가자 / 적군·등장 탭 확인.
저장이 실패하면 "❌ 전투 기록 저장 실패"와 **🔁 기록 저장 재시도** 버튼이 나옵니다.

> 참고: `npm run test:*` 자동 테스트는 이름이 `[자동테스트]`로 시작하는 전투 기록을 보관함에 남깁니다.
> (보관함 기록 삭제 기능은 요청서 1차 범위에 없어서, 필요하면 SQL Editor에서
> `delete from battle_results where id in (select battle_result_id from battle_archives where room_name_snapshot like '[자동테스트]%');` 로 지울 수 있습니다.)

## 전체 테스트 / 배포

```bash
npm run test:all
```

2·3·4·5·6·7단계 자동 테스트를 순서대로 실행합니다 (4단계 3분 대기 포함, 약 6분). 빠르게: `npm run test:all -- http://localhost:3000 --skip-wait`

배포는 [`docs/DEPLOY.md`](docs/DEPLOY.md) 를 따라 하세요.

### DB 함수 단독 테스트 (선택, 개발자용)
로컬 PostgreSQL이 있을 때만: `npm run test:db`

---

## 폴더 구조
```
supabase/migrations/   DB 마이그레이션 (번호 순서대로 실행)
supabase/tests/        로컬 DB 테스트
scripts/               실제 서버 대상 자동 테스트
src/app/               화면과 API (api/ 폴더 = 서버)
src/lib/               서버·브라우저 공통 코드
src/components/        UI 조각
docs/DESIGN.md         설계 문서
```
