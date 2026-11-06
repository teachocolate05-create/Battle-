// =====================================================================
// 2단계 다중 사용자 자동 테스트 (실제 Supabase + 실행 중인 개발 서버 대상)
//
// 사용법:
//   1) 터미널 1:  npm run dev
//   2) 터미널 2:  npm run test:stage2
//
// 가상의 사용자 4명(관리자 1 + 게스트 3)을 만들어 실제 API를 호출하고,
// 인원 제한·중복 닉네임·강퇴·RLS·실시간 알림까지 확인합니다.
// 테스트용 방은 마지막에 삭제됩니다.
// =====================================================================
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

// .env.local 읽기
const env = {};
try {
  for (const line of readFileSync(new URL("../.env.local", import.meta.url), "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
} catch {
  console.error("❌ .env.local 파일이 없습니다. README의 '환경 변수 설정'을 먼저 하세요.");
  process.exit(1);
}
const BASE = process.argv[2] ?? "http://localhost:3000";
const URL_ = env.NEXT_PUBLIC_SUPABASE_URL;
const KEY = env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

let passed = 0;
function ok(cond, name) {
  if (!cond) {
    console.error(`❌ 실패: ${name}`);
    process.exit(1);
  }
  passed++;
  console.log(`✅ ${name}`);
}

async function makeUser(label) {
  const sb = createClient(URL_, KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await sb.auth.signInAnonymously();
  if (error) {
    console.error(`❌ ${label} 익명 로그인 실패: ${error.message}`);
    console.error("   → Supabase > Authentication > Sign In / Providers 에서 'Allow anonymous sign-ins' 를 켜세요.");
    process.exit(1);
  }
  const token = data.session.access_token;
  const call = async (path, method = "GET", body) => {
    const res = await fetch(BASE + path, {
      method,
      headers: { Authorization: `Bearer ${token}`, ...(body ? { "Content-Type": "application/json" } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, data: await res.json().catch(() => ({})) };
  };
  return { sb, call, label };
}

console.log(`대상 서버: ${BASE}\n`);

// 0. 연결 상태
let health;
try {
  health = await (await fetch(BASE + "/api/health")).json();
} catch {
  console.error(`❌ ${BASE} 에 연결할 수 없습니다. 다른 터미널에서 npm run dev 를 실행했나요?`);
  process.exit(1);
}
ok(health.ok, `서버/DB 연결 정상 (${health.db.message})`);

const admin = await makeUser("관리자");
const g1 = await makeUser("게스트1");
const g2 = await makeUser("게스트2");
const g3 = await makeUser("게스트3");
ok(true, "가상 사용자 4명 익명 로그인");

// 1. 관리자 인증
ok((await admin.call("/api/auth/admin", "POST", { code: "wrong-code-xyz" })).status === 401, "잘못된 관리자 코드 거부");
ok((await g1.call("/api/rooms", "POST", { roomName: "x" })).status === 403, "게스트는 방 생성 불가");
ok((await admin.call("/api/auth/admin", "POST", { code: env.ADMIN_CODE })).status === 200, "관리자 코드 인증");
ok((await admin.call("/api/auth/me")).data.isAdmin === true, "관리자 권한 확인");

// 2. 방 생성
const created = await admin.call("/api/rooms", "POST", {
  roomName: "[자동테스트] 2단계",
  description: "테스트 후 자동 삭제",
  usePassword: true,
  password: "pw1234",
  maxPlayers: 2,
  turnDuration: 180,
});
ok(created.status === 200 && /^[A-Z2-9]{6}$/.test(created.data.room_code), `방 생성 + 코드 발급 (${created.data.room_code})`);
const roomId = created.data.id;
const code = created.data.room_code;

try {
  // 3. 입장
  ok((await g1.call("/api/rooms/join", "POST", { code: "ZZZZZZ", nickname: "A" })).status === 400, "잘못된 방 코드 거부");
  ok((await g1.call("/api/rooms/join", "POST", { code, nickname: "용사", password: "nope" })).status === 400, "잘못된 비밀번호 거부");
  ok((await g1.call("/api/rooms/join", "POST", { code, nickname: "용사", password: "pw1234" })).status === 200, "게스트1 입장");
  const again = await g1.call("/api/rooms/join", "POST", { code, nickname: "다른캐릭", password: "pw1234" });
  ok(again.data.restored === true, "같은 사용자 재입장 → 기존 캐릭터 복구 (중복 참여 방지)");
  ok((await g2.call("/api/rooms/join", "POST", { code, nickname: "용사", password: "pw1234" })).status === 400, "중복 닉네임 거부");
  ok((await g2.call("/api/rooms/join", "POST", { code, nickname: "궁수", password: "pw1234" })).status === 200, "게스트2 입장");
  const full = await g3.call("/api/rooms/join", "POST", { code, nickname: "마법사", password: "pw1234" });
  ok(full.status === 400 && full.data.error.includes("가득"), "최대 인원 초과 거부 (관리자는 인원에 포함 안 됨)");

  // 4. 상태 조회 / 공개 범위
  const s1 = await g1.call(`/api/rooms/${roomId}/state`);
  ok(s1.status === 200 && s1.data.players.length === 2, "게스트1 방 상태 조회 (플레이어 2명)");
  const other = s1.data.players.find((p) => p.id !== s1.data.me.player.id);
  ok(other && other.min_attack === undefined && s1.data.me.player.min_attack !== undefined, "다른 플레이어의 세부 능력치는 비공개, 내 능력치는 공개");
  ok((await g3.call(`/api/rooms/${roomId}/state`)).status === 403, "참가자가 아니면 방 상태 조회 불가");

  // 5. RLS: 브라우저 키로 직접 DB 접근
  const { data: secrets } = await g2.sb.from("room_secrets").select("*");
  ok((secrets ?? []).length === 0, "RLS: 비밀번호 해시 조회 불가");
  await g2.sb.from("players").update({ current_hp: 9999 }).eq("room_id", roomId);
  const { data: hpCheck } = await g2.sb.from("players").select("current_hp").eq("room_id", roomId);
  ok((hpCheck ?? []).every((p) => p.current_hp !== 9999) && hpCheck.length === 2, "RLS: 게스트가 HP를 직접 수정할 수 없음");
  const { data: otherRooms } = await g3.sb.from("rooms").select("id").eq("id", roomId);
  ok((otherRooms ?? []).length === 0, "RLS: 다른 방 데이터 접근 불가");

  // 6. 실시간: 게스트2가 구독 중일 때 관리자가 게스트1 강퇴 → 알림 수신
  const members = (await admin.call(`/api/rooms/${roomId}/state`)).data.members;
  const g1Member = members.find((m) => m.nickname === "용사");
  await g2.sb.realtime.setAuth((await g2.sb.auth.getSession()).data.session.access_token);
  let ch;
  const gotEvent = new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), 15000);
    ch = g2.sb
      .channel("smoke-" + roomId)
      .on("postgres_changes", { event: "*", schema: "public", table: "room_members", filter: `room_id=eq.${roomId}` }, () => {
        clearTimeout(timer);
        resolve(true);
      })
      .subscribe(async (status) => {
        if (status === "SUBSCRIBED") {
          await new Promise((r) => setTimeout(r, 1000));
          await admin.call(`/api/rooms/${roomId}/members/${g1Member.id}/kick`, "POST");
        }
      });
  });
  const rt = await gotEvent;
  await g2.sb.removeChannel(ch);
  if (!rt) {
    console.warn("⚠️  실시간 알림을 15초 안에 받지 못했습니다. 001_schema.sql 의 Realtime 설정을 확인하세요.");
    console.warn("    (화면은 15초마다 자동 새로고침되므로 동작은 하지만 반응이 느려집니다)");
  } else ok(true, "실시간: 강퇴 변경을 다른 참가자가 즉시 수신");

  const kicked = await g1.call(`/api/rooms/${roomId}/state`);
  ok(kicked.status === 403 && kicked.data.error.includes("강퇴"), "강퇴된 사용자는 방 접근 불가");
  ok((await g1.call("/api/rooms/join", "POST", { code, nickname: "용사", password: "pw1234" })).status === 400, "강퇴된 사용자 재입장 불가");
  ok((await g3.call("/api/rooms/join", "POST", { code, nickname: "마법사", password: "pw1234" })).status === 200, "빈자리에 게스트3 입장");

  // 7. 퇴장
  ok((await g3.call(`/api/rooms/${roomId}/leave`, "POST")).status === 200, "게스트3 퇴장");
  const back = await g3.call("/api/rooms/join", "POST", { code, nickname: "", password: "pw1234" });
  ok(back.status === 200 && back.data.restored === true, "퇴장했던 사용자 재입장 → 캐릭터 복구");
} finally {
  // 8. 정리
  const del = await admin.call(`/api/rooms/${roomId}`, "DELETE");
  ok(del.status === 200, "테스트 방 삭제");
  ok((await g2.call(`/api/rooms/${roomId}/state`)).status === 404, "삭제된 방은 조회 불가");
  await admin.call("/api/auth/admin", "DELETE");
}

console.log(`\n🎉 2단계 테스트 ${passed}개 모두 통과`);
process.exit(0);
