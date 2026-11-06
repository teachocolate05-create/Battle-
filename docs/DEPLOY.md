# 배포 안내 (Vercel, HTTPS)

이 문서를 위에서부터 순서대로 따라 하면 `https://○○○.vercel.app` 주소로 누구나 접속할 수 있게 됩니다.
예상 소요 시간: 약 10~15분. 비용: Vercel Hobby(무료) 플랜으로 충분합니다.

> Supabase(데이터베이스)는 이미 설정이 끝나 있습니다. 여기서는 웹사이트만 Vercel에 올립니다.
> 자동 판정(5초마다)은 Supabase 안에서 돌기 때문에 Vercel 설정은 따로 필요 없습니다.

---

## 0단계. 코드를 main 브랜치에 합치기 (처음 한 번)

Vercel은 기본적으로 저장소의 **main** 브랜치를 배포합니다. 지금까지의 작업은 `claude/battle-site` 브랜치에 있습니다.

1. https://github.com/teachocolate05-create/Battle- 접속
2. 화면 위쪽 노란 띠의 **Compare & pull request** 버튼 클릭
   (안 보이면 **Pull requests** 탭 → **New pull request** → base: `main`, compare: `claude/battle-site` 선택)
3. **Create pull request** → 다음 화면에서 **Merge pull request** → **Confirm merge**

이제 main 브랜치에 전체 코드가 들어갔습니다.

---

## 1단계. Vercel 가입 / 로그인

1. https://vercel.com 접속 → **Sign Up** (이미 있으면 **Log In**)
2. **Continue with GitHub** 선택 → GitHub 로그인 → 권한 허용
3. 플랜을 물으면 **Hobby** 선택

## 2단계. 저장소 가져오기 (Import)

1. Vercel 대시보드 → **Add New…** → **Project**
2. **Import Git Repository** 목록에서 `Battle-` 옆의 **Import** 클릭
   - 목록에 없으면 **Adjust GitHub App Permissions** → `Battle-` 저장소 접근 허용 후 돌아오기
3. 설정 화면에서
   - **Framework Preset**: `Next.js` (자동 선택됨)
   - **Root Directory**: 그대로 (`./`)
   - Build / Output 설정: 건드리지 않음

## 3단계. 환경 변수 4개 입력 (가장 중요)

같은 화면의 **Environment Variables** 를 펼치고, 아래 4개를 **Key / Value** 로 하나씩 추가합니다.

| Key | Value를 어디서 복사하나요 |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://scnlrjiitdbnbvepytey.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Supabase 대시보드 → Project Settings → **API Keys** → **Publishable key** (`sb_publishable_…`) 의 복사 버튼 |
| `SUPABASE_SECRET_KEY` | 같은 화면 **Secret keys** → `default` 키의 눈 아이콘(Reveal) → 복사 (`sb_secret_…`) |
| `ADMIN_CODE` | 관리자 코드. **새로 길게** 정하는 것을 권장합니다 (예: 영문+숫자 16자 이상). 아래 참고 |

주의
- Key 이름은 **대소문자·밑줄까지 정확히** 똑같이 입력하세요.
- `SUPABASE_SECRET_KEY` 와 `ADMIN_CODE` 는 절대 다른 사람에게 보여주지 마세요. (이 둘은 서버에서만 쓰이고 브라우저로는 전달되지 않습니다)
- 관리자 코드: 지금 개발용 코드(`.env.local`)는 짧은 임시 코드입니다. 실제 서비스에서는 쉽게 추측할 수 없는 긴 코드를 쓰세요.
  나중에 바꾸려면 Vercel → 프로젝트 → **Settings → Environment Variables** 에서 수정 후 **Redeploy** 하면 됩니다.

## 4단계. 배포

1. **Deploy** 클릭 → 1~2분 기다림
2. "Congratulations!" 화면이 나오면 **Continue to Dashboard**
3. **Domains** 에 표시된 주소(예: `battle-xxxx.vercel.app`)가 사이트 주소입니다. HTTPS 는 자동입니다.

## 5단계. 동작 확인

1. 사이트 주소 접속 → 첫 화면 아래 **✅ 서버 연결 정상** 이 보이면 성공
   - ❌ 가 보이면 그 줄의 안내를 확인하세요. 대부분 환경 변수 오타입니다 → 수정 후 **Deployments → … → Redeploy**
2. `/admin` 접속 → 3단계에서 정한 관리자 코드 입력 → 전투방 생성
3. 휴대폰(데이터 또는 와이파이)으로 사이트 주소 접속 → 방 코드로 입장
4. (선택) 자동 테스트를 배포 사이트에 대고 실행:
   ```bash
   npm run test:all -- https://battle-xxxx.vercel.app
   ```
   ※ `.env.local` 의 `ADMIN_CODE` 가 Vercel 에 넣은 값과 같아야 합니다. 4단계 테스트는 3분을 실제로 기다립니다.
   ※ 테스트는 `[자동테스트]` 이름의 기록을 보관함에 남깁니다. (지우는 법은 README 참고)

---

## 이후 업데이트 방법

GitHub 의 main 브랜치에 새 코드가 합쳐지면 Vercel 이 **자동으로 다시 배포**합니다. 따로 할 일이 없습니다.
DB 변경(새 `supabase/migrations/*.sql`)이 있을 때는 Supabase SQL Editor 에서 해당 파일을 먼저 실행하세요.

## 알아두면 좋은 Supabase 설정

- **익명 로그인 횟수 제한**: 기본값은 같은 IP(같은 와이파이)에서 시간당 30회입니다.
  한 번 접속한 브라우저는 계속 같은 사용자로 기억되므로 보통은 충분하지만, 한 장소에서 많은 사람이 동시에 처음 접속한다면
  Supabase → **Authentication → Rate Limits** 에서 "anonymous users" 값을 늘릴 수 있습니다.
- **무료 플랜 일시 정지**: Supabase 무료 프로젝트는 일주일 이상 사용이 없으면 일시 정지될 수 있습니다.
  대시보드에서 **Restore** 를 누르면 다시 켜집니다 (데이터는 유지).

## 문제가 생기면

| 증상 | 원인 / 해결 |
|---|---|
| 첫 화면에 ❌ `SUPABASE_SECRET_KEY — 값이 없습니다` | 환경 변수 이름 오타 또는 누락 → 수정 후 Redeploy |
| ❌ `익명 로그인에 실패했습니다` | Supabase → Authentication → Sign In / Providers → **Allow anonymous sign-ins** 켜기 |
| 관리자 코드가 계속 틀렸다고 나옴 | Vercel 의 `ADMIN_CODE` 값 확인 (앞뒤 공백 주의) → 수정 후 Redeploy |
| 화면이 실시간으로 안 바뀌고 15초마다 바뀜 | 실시간 연결이 끊긴 상태(오른쪽 위 빨간 점). 네트워크 확인. 자동으로 다시 연결을 시도합니다 |
| 시간이 지나도 판정이 안 됨 | Supabase SQL Editor 에서 `select * from cron.job;` → `battle-tick` 이 있는지 확인. 없으면 `004_battle_engine.sql` 다시 실행 |
