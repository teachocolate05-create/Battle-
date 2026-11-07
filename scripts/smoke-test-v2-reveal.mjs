// =====================================================================
// v2 4단계 자동 테스트: 행동 선언 → 5초 후 최종 결과 공개 (서버 기준)
//   npm run test:v2-reveal  (또는 node scripts/smoke-test-v2-reveal.mjs https://사이트주소)
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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const admin = await makeUser(), g1 = await makeUser(), g2 = await makeUser();
await admin.call("/api/auth/admin", "POST", { code: env.ADMIN_CODE });
const { data: room } = await admin.call("/api/rooms", "POST", { roomName: "[자동테스트] v2 결과 공개", maxPlayers: 10, turnDuration: 180 });
const R = `/api/rooms/${room.id}`;
await g1.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "기사" });
await g2.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "궁수" });
const st = async (u) => (await u.call(`${R}/state`)).data;
try {
  const ps = (await st(admin)).players;
  for (const p of ps) await admin.call(`${R}/players/${p.id}`, "PATCH", { min_attack: 7, max_attack: 7, dodge_rate: 100 });
  const golem = (await admin.call(`${R}/enemies`, "POST", { name: "골렘", max_hp: 100, min_attack: 4, max_attack: 4, target_type: "all" })).data.id;
  await admin.call(`${R}/enemies/${golem}/appear`, "POST");
  await admin.call(`${R}/settings`, "PATCH", { first_side: "players" });
  await admin.call(`${R}/battle/start`, "POST");
  await g1.call(`${R}/actions`, "POST", { action_type: "attack", target_id: golem });
  await g2.call(`${R}/actions`, "POST", { action_type: "dodge" });
  await admin.call(`${R}/battle/resolve`, "POST");

  // ---- 선언 직후: 행동만 공개, 결과 없음 ----
  let s = await st(g2);
  const left = (new Date(s.phase.reveal_at) - new Date(s.serverNow)) / 1000;
  ok(s.phase.status === "declared" && s.phase.phase_number === 2 && left > 3 && left <= 5.2, `행동 선언 완료 · 서버 기준 결과 공개까지 ${left.toFixed(1)}초`);
  ok(s.logs.some((l) => l.stage === "declare" && l.content === "기사가 골렘을 공격했다.") &&
     s.logs.some((l) => l.stage === "declare" && l.content === "궁수가 회피를 시도했다.") &&
     s.logs.some((l) => l.stage === "declare" && l.content === "골렘이 기사를 공격했다."), "선언: 플레이어 행동 + 적군 반응 행동 공개");
  ok(!s.logs.some((l) => l.stage === "result") && !s.logs.some((l) => l.stage === "declare" && /[0-9]/.test(l.content)), "선언 중에는 결과·숫자 없음");
  ok(s.players.every((p) => p.current_hp === 100) && s.enemies[0].current_hp === 100, "결과 공개 전 HP 변화 없음 (서버 응답 기준)");
  const raw = JSON.stringify(s);
  ok(!raw.includes('"damage"') && !raw.includes('"dodged"'), "공개 전 응답 어디에도 피해량·회피 결과 없음");

  // ---- 여러 곳에서 동시에 판정 요청해도 일찍 공개되지 않음 ----
  const ticks = await Promise.all([g1, g2, admin, g1, g2].map((u) => u.call(`${R}/battle/tick`, "POST")));
  ok(ticks.every((t) => t.status === 200 && t.data.resolved === 0), "공개 시각 전 동시 요청 5건 → 모두 무시");
  ok((await admin.call(`${R}/battle/resolve`, "POST")).data.error?.includes("5초"), "관리자도 5초 대기를 건너뛸 수 없음");

  // ---- 브라우저 요청 없이 서버 예약 작업만으로 공개되는지 (요청은 상태 조회만) ----
  for (let i = 0; i < 30 && s.phase.status === "declared"; i++) { await sleep(500); s = await st(g1); }
  const declAt = new Date(s.logs.find((l) => l.content === "골렘이 기사를 공격했다.").created_at);
  const revealLog = s.logs.find((l) => l.log_type === "reveal");
  const gap = (new Date(revealLog.created_at) - declAt) / 1000;
  ok(gap >= 5 && gap < 7.5, `서버가 선언 후 ${gap.toFixed(1)}초에 결과 공개 (목표 5초, 예약 작업 1초 간격)`);
  ok(s.logs.some((l) => l.stage === "result" && l.content.startsWith("기사의 공격 적중! (공격력 7)")) &&
     s.logs.some((l) => l.stage === "result" && l.log_type === "damage" && l.content.includes("기사가 4의 피해")) &&
     s.logs.some((l) => l.stage === "result" && l.log_type === "dodge_success" && l.content.startsWith("궁수가 골렘의 공격(공격력 4)을 회피했다!")), "결과: 공격력·피해·HP 변화·회피 성공 공개");
  ok(s.enemies[0].current_hp === 93 && s.players.find((p) => p.display_name === "기사").current_hp === 96 && s.players.find((p) => p.display_name === "궁수").current_hp === 100, "결과 공개 후 HP 갱신 (회피한 궁수는 그대로)");
  ok(s.logs.filter((l) => l.log_type === "reveal").length === 1, "같은 구간은 한 번만 판정");
  ok(s.phase.phase_number === 4 && s.phase.status === "open" && s.pendingAttacks.length === 2 && s.pendingAttacks.every((a) => a.attack_power === null),
    "다음 구간: 적군 공격 예고(공격력은 결과 공개 때 결정) → 플레이어 반응턴");

  // ---- 새로 접속해도 같은 상태 ----
  const again = await st(g2);
  ok(again.phase.id === s.phase.id && again.logs.length === s.logs.length, "재접속(새로 조회)해도 같은 진행 상태");

  // ---- 결과 공개 대기 중 강제 종료 → 공개 취소 ----
  await g2.call(`${R}/actions`, "POST", { action_type: "dodge" });
  await admin.call(`${R}/battle/resolve`, "POST");
  ok((await st(admin)).phase.status === "declared", "4단계 선언 → 결과 대기");
  await admin.call(`${R}/battle/end`, "POST", { reason: "대기 중 종료 테스트" });
  await sleep(7000);
  const fin = await st(g1);
  ok(fin.room.status === "ended" && fin.logs.filter((l) => l.log_type === "reveal").length === 1 &&
     fin.players.find((p) => p.display_name === "기사").current_hp === 96, "강제 종료 → 대기 중이던 결과 공개는 취소 (판정하지 않음)");
} finally {
  await admin.call(`${R}/battle/end`, "POST", { reason: "테스트" });
  await admin.call(R, "DELETE");
  await admin.call("/api/auth/admin", "DELETE");
}
console.log(`\n🎉 v2 결과 공개 테스트 ${passed}개 모두 통과`);
process.exit(0);
