// =====================================================================
// v2 5단계 자동 테스트: 채팅 이름·색 / 관리자 메시지 구분 / 채팅·로그 분리 / 기록 보관(v2)
//   npm run test:v2-chat  (또는 node scripts/smoke-test-v2-chat.mjs https://사이트주소)
// =====================================================================
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const env = {};
for (const line of readFileSync(new URL("../.env.local", import.meta.url), "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
  if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
}
const BASE = process.argv[2] ?? "http://localhost:3000";
let passed = 0;
function ok(cond, name) {
  if (!cond) { console.error(`❌ 실패: ${name}`); process.exit(1); }
  passed++; console.log(`✅ ${name}`);
}
async function makeUser() {
  const sb = createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await sb.auth.signInAnonymously();
  if (error) throw new Error("익명 로그인 실패: " + error.message);
  const token = data.session.access_token;
  const call = async (path, method = "GET", body) => {
    const res = await fetch(BASE + path, { method, headers: { Authorization: `Bearer ${token}`, ...(body ? { "Content-Type": "application/json" } : {}) }, body: body ? JSON.stringify(body) : undefined });
    return { status: res.status, data: await res.json().catch(() => ({})) };
  };
  return { sb, call };
}
async function waitReveal(u, R) {
  for (let i = 0; i < 40; i++) {
    const s = (await u.call(`${R}/state`)).data;
    if (s.phase?.status !== "declared") return s;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("결과 공개가 15초 안에 되지 않았습니다");
}
const admin = await makeUser(), g1 = await makeUser();
await admin.call("/api/auth/admin", "POST", { code: env.ADMIN_CODE });
const name = `[자동테스트] v2 채팅·기록 ${Date.now() % 100000}`;
const { data: room } = await admin.call("/api/rooms", "POST", { roomName: name, maxPlayers: 10, turnDuration: 180 });
const R = `/api/rooms/${room.id}`;
await g1.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "kim" });
const st = async (u) => (await u.call(`${R}/state`)).data;
let archiveId = null;
try {
  await g1.call(`${R}/profile`, "PATCH", { display_name: "불꽃 마법사", name_color: "#ff8a80", bio: "불을 다룬다" });
  await g1.call(`${R}/chat`, "POST", { message: "준비됐어!" });
  await admin.call(`${R}/chat`, "POST", { message: "어둠이 내려앉는다…" });
  let s = await st(g1);
  const mine = s.chat.find((c) => c.message === "준비됐어!");
  const adm = s.chat.find((c) => c.sender_role === "admin");
  ok(mine.nickname === "불꽃 마법사" && mine.name_color === "#ff8a80", "참가자 채팅: 캐릭터 이름 + 설정한 이름 색");
  ok(adm && adm.nickname === "관리자" && !adm.name_color, "관리자 메시지는 역할로 구분 (화면에서 본문만 회색)");

  const slime = (await admin.call(`${R}/enemies`, "POST", { name: "슬라임", max_hp: 1 })).data.id;
  await admin.call(`${R}/enemies/${slime}/appear`, "POST");
  await admin.call(`${R}/settings`, "PATCH", { first_side: "players" });
  await admin.call(`${R}/battle/start`, "POST");
  await g1.call(`${R}/actions`, "POST", { action_type: "attack", target_id: slime });
  await g1.call(`${R}/chat`, "POST", { message: "간다!" });
  s = await st(g1);
  ok(s.submissions.length === 1 && s.chat.length === 3, "채팅과 행동 제출은 별개 (채팅해도 행동 그대로)");
  ok(!s.logs.some((l) => l.content.includes("간다!")) && !s.chat.some((c) => c.message.includes("공격했다")), "채팅 데이터와 전투 로그 데이터 분리");
  await admin.call(`${R}/battle/resolve`, "POST");
  s = await waitReveal(admin, R);
  ok(s.room.status === "ended" && s.room.archive_status === "saved", "승리 → 자동 저장");
  const ro = await g1.call(`${R}/chat`, "POST", { message: "끝!" });
  ok(ro.status === 400 && ro.data.error.includes("읽기 전용"), "종료 후 채팅 읽기 전용");

  const list = (await admin.call("/api/archives")).data.archives;
  archiveId = list.find((a) => a.room_id === room.id).id;
  const d = (await admin.call(`/api/archives/${archiveId}`)).data.archive_data;
  ok(d.version === 2, "기록 v2 형식");
  ok(d.players[0].name_color === "#ff8a80" && d.players[0].bio === "불을 다룬다" && d.players[0].profile_locked_at, "기록: 참가자 프로필·이름 색");
  ok(d.logs.some((l) => l.stage === "declare") && d.logs.some((l) => l.stage === "result"), "기록: 행동 선언 / 판정 결과 구분");
  ok(d.chat.length === 3 && d.chat.find((c) => c.message === "준비됐어!").name_color === "#ff8a80", "기록: 채팅(이름 색 포함) 별도 저장");
  ok(d.profile_history.length >= 1, "기록: 프로필 수정 내역");
} finally {
  await admin.call(`${R}/battle/end`, "POST", { reason: "테스트" });
  await admin.call(R, "DELETE");
  await admin.call("/api/auth/admin", "DELETE");
}
console.log(`\n🎉 v2 채팅·기록 테스트 ${passed}개 모두 통과`);
process.exit(0);
