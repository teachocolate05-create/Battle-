// =====================================================================
// v2 3단계 자동 테스트: 적군 퇴장·재등장 / 관리자의 판정 전 행동 열람 / 채팅 가리기 / 아이템 지급
//   npm run test:v2-admin  (또는 node scripts/smoke-test-v2-admin.mjs https://사이트주소)
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
const admin = await makeUser(), g1 = await makeUser(), g2 = await makeUser();
await admin.call("/api/auth/admin", "POST", { code: env.ADMIN_CODE });
const { data: room } = await admin.call("/api/rooms", "POST", { roomName: "[자동테스트] v2 관리자", maxPlayers: 10, turnDuration: 180 });
const R = `/api/rooms/${room.id}`;
await g1.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "전사" });
await g2.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "궁수" });
const st = async (u) => (await u.call(`${R}/state`)).data;
try {
  const ps = (await st(admin)).players;
  const p1 = ps.find((p) => p.display_name === "전사").id;
  const runner = (await admin.call(`${R}/enemies`, "POST", { name: "도망자", max_hp: 50 })).data.id;
  const potion = (await admin.call(`${R}/items`, "POST", { item_type: "heal", name: "물약", effect_value: 10 })).data.id;
  ok((await admin.call(`${R}/items/${potion}/grant`, "POST", { playerId: p1, quantity: 2 })).data.total === 2, "아이템 지급");

  ok((await admin.call(`${R}/enemies/${runner}/withdraw`, "POST")).status === 400, "등장 전 적군은 퇴장 불가");
  await admin.call(`${R}/enemies/${runner}/appear`, "POST");
  ok((await g1.call(`${R}/enemies/${runner}/withdraw`, "POST")).status === 403, "게스트는 적군 퇴장 불가");
  const w = await admin.call(`${R}/enemies/${runner}/withdraw`, "POST");
  ok(w.status === 200 && w.data.message.includes("물러났다"), "적군 퇴장");
  let gs = await st(g1);
  ok(gs.enemies.find((e) => e.id === runner)?.status === "withdrawn" && gs.events.some((e) => e.event_type === "enemy_withdrawn"), "참가자 화면: 퇴장 상태 + 시스템 메시지");
  ok((await admin.call(`${R}/enemies/${runner}/appear`, "POST")).data.message.includes("다시"), "퇴장한 적군 재등장");

  await admin.call(`${R}/settings`, "PATCH", { first_side: "players" });
  await admin.call(`${R}/battle/start`, "POST");
  await g1.call(`${R}/actions`, "POST", { action_type: "item", item_id: potion });
  await g2.call(`${R}/actions`, "POST", { action_type: "attack", target_id: runner });
  const as = await st(admin);
  ok(as.adminActions.length === 2 && as.adminActions.some((a) => a.action_type === "item" && a.item_id === potion), "관리자: 판정 전 각 참가자 행동 확인");
  gs = await st(g2);
  ok(gs.adminActions.length === 0 && !JSON.stringify(gs).includes('"item"') && gs.myAction.action_type === "attack", "게스트: 남의 행동 비공개, 내 행동만");
  const { data: rls } = await g2.sb.from("actions").select("action_type").eq("room_id", room.id);
  ok(rls.length === 1, "RLS: 게스트는 DB에서 자기 행동만");

  // 채팅 가리기
  const sent = (await g2.call(`${R}/chat`, "POST", { message: "부적절한 말" })).data.id;
  ok((await g1.call(`${R}/chat/${sent}/hide`, "POST", { hide: true })).status === 403, "게스트는 채팅 가리기 불가");
  ok((await admin.call(`${R}/chat/${sent}/hide`, "POST", { hide: true })).status === 200, "관리자 채팅 가리기");
  const gc = (await st(g1)).chat.find((c) => c.id === sent);
  ok(gc.hidden && gc.message === "(관리자가 가린 메시지)" && !gc.original, "참가자: 가려진 표시만 (원문 없음)");
  const { data: raw } = await g1.sb.from("chat_messages").select("message").eq("id", sent);
  ok(raw[0].message === "(관리자가 가린 메시지)", "DB 직접 조회로도 원문 볼 수 없음");
  ok((await st(admin)).chat.find((c) => c.id === sent).original === "부적절한 말", "관리자: 원문 확인");
  await admin.call(`${R}/chat/${sent}/hide`, "POST", { hide: false });
  ok((await st(g1)).chat.find((c) => c.id === sent).message === "부적절한 말", "가리기 해제 → 원문 복구");
} finally {
  await admin.call(`${R}/battle/end`, "POST", { reason: "테스트" });
  await admin.call(R, "DELETE");
  await admin.call("/api/auth/admin", "DELETE");
}
console.log(`\n🎉 v2 관리자 도구 테스트 ${passed}개 모두 통과`);
process.exit(0);
