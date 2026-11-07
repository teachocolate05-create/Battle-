// =====================================================================
// v2 2단계 자동 테스트: 전투 전 프로필 / 이름 색상 / 추가 항목 / 잠금 / 관리자 수정 / 수정 내역
//   npm run test:v2-profile  (또는 node scripts/smoke-test-v2-profile.mjs https://사이트주소)
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
const { data: room } = await admin.call("/api/rooms", "POST", { roomName: "[자동테스트] v2 프로필", maxPlayers: 10, turnDuration: 180 });
const R = `/api/rooms/${room.id}`;
await g1.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "하나" });
await g2.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "둘" });
try {
  const st0 = (await g1.call(`${R}/state`)).data;
  ok(st0.players.every((p) => /^#[0-9a-f]{6}$/.test(p.name_color)) && st0.players[0].name_color !== st0.players[1].name_color, "입장 시 서로 다른 이름 색 자동 배정");

  const f = await admin.call(`${R}/profile-fields`, "PUT", { fields: ["나이", "직업"] });
  ok(f.status === 200 && f.data.fields.length === 2, "관리자: 추가 프로필 항목 2개 설정");
  ok((await g1.call(`${R}/profile-fields`, "PUT", { fields: ["x"] })).status === 403, "게스트는 추가 항목 설정 불가");
  const ageKey = f.data.fields[0].key;

  const up = await g1.call(`${R}/profile`, "PATCH", { display_name: "빛의 기사", bio: "왕국의 기사", appearance: "은빛 갑옷", name_color: "#ffd54f", profile_extra: { [ageKey]: "27" }, max_hp: 9999 });
  ok(up.status === 200 && up.data.changes.display_name, "참가자: 본인 프로필 저장");
  const st1 = (await g2.call(`${R}/state`)).data;
  const knight = st1.players.find((p) => p.display_name === "빛의 기사");
  ok(knight && knight.bio === "왕국의 기사" && knight.name_color === "#ffd54f" && knight.profile_extra[ageKey] === "27", "다른 참가자 화면에 프로필·색상 반영");
  ok(knight.max_hp === 100 && knight.min_attack === undefined, "프로필 요청에 능력치를 넣어도 무시, 남의 능력치는 비공개");
  const dark = await g2.call(`${R}/profile`, "PATCH", { name_color: "#202020" });
  ok(dark.status === 400 && dark.data.error.includes("잘 보이지"), "어두운 색 거부");
  ok((await g2.call(`${R}/profile`, "PATCH", { display_name: "빛의 기사" })).status === 400, "같은 방 이름 중복 거부");
  ok((await g2.call(`${R}/players/${knight.id}/profile`, "PATCH", { bio: "해킹" })).status === 403, "게스트는 남의 프로필 수정 불가");
  const { error: rlsErr } = await g2.sb.from("players").update({ bio: "해킹" }).eq("id", knight.id);
  const after = (await g1.call(`${R}/state`)).data.me.player.bio;
  ok(after === "왕국의 기사", `DB 직접 수정 차단 (RLS)${rlsErr ? "" : ""}`);

  // 재접속 후 유지
  ok((await g1.call(`${R}/state`)).data.me.player.name_color === "#ffd54f", "재조회해도 색상 유지 (DB 저장)");

  // 전투 시작 → 잠금
  const e = (await admin.call(`${R}/enemies`, "POST", { name: "허수아비" })).data.id;
  await admin.call(`${R}/settings`, "PATCH", { first_side: "players" });
  await admin.call(`${R}/battle/start`, "POST");
  const locked = await g1.call(`${R}/profile`, "PATCH", { bio: "바꾸고 싶다" });
  ok(locked.status === 400 && locked.data.error.includes("확정"), "전투 시작 후 본인 프로필·색상 수정 불가");
  ok((await g1.call(`${R}/state`)).data.me.player.profile_locked_at, "프로필 확정 시각 기록");
  ok((await admin.call(`${R}/players/${knight.id}/profile`, "PATCH", { appearance: "부서진 갑옷" })).status === 200, "관리자는 전투 중에도 프로필 수정 가능");
  const hist = (await admin.call(`${R}/state`)).data.profileHistory;
  ok(hist.length === 2 && hist.some((h) => h.changed_by === "admin") && hist.some((h) => h.changed_by === "player"), "수정 내역 기록 (본인/관리자 구분)");
  ok((await g2.call(`${R}/state`)).data.profileHistory.length === 0, "게스트에게 수정 내역 비공개");
  void e;
} finally {
  await admin.call(`${R}/battle/end`, "POST", { reason: "테스트" });
  await admin.call(R, "DELETE");
  await admin.call("/api/auth/admin", "DELETE");
}
console.log(`\n🎉 v2 프로필 테스트 ${passed}개 모두 통과`);
process.exit(0);
