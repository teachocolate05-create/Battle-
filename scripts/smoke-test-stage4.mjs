// =====================================================================
// 4단계 자동 테스트 (실제 Supabase + 실행 중인 개발 서버 대상)
//   터미널 1: npm run dev     터미널 2: npm run test:stage4
// 전투 시작 → 행동 제출(비공개) → 조기 판정 → 3개 단계 연속 판정 → 반응턴
// → [브라우저 요청 없이] 서버 예약 작업(pg_cron)이 제한 시간 종료 후 자동 판정 → 강제 종료
// ※ 제한 시간(3분)을 실제로 기다리므로 약 3~4분 걸립니다.
// =====================================================================
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const env = {};
for (const line of readFileSync(new URL("../.env.local", import.meta.url), "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
  if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
}
const BASE = process.argv[2] ?? "http://localhost:3000";
const SKIP_WAIT = process.argv.includes("--skip-wait");
let passed = 0;
function ok(cond, name) {
  if (!cond) {
    console.error(`❌ 실패: ${name}`);
    process.exit(1);
  }
  passed++;
  console.log(`✅ ${name}`);
}
/** 결과 공개(행동 선언 5초 뒤)를 기다림 — 서버 예약 작업이 처리 */
async function waitReveal(u, R) {
  for (let i = 0; i < 40; i++) {
    const s = (await u.call(`${R}/state`)).data;
    if (s.phase?.status !== "declared") return s;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("결과 공개가 15초 안에 되지 않았습니다");
}

async function makeUser() {
  const sb = createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await sb.auth.signInAnonymously();
  if (error) throw new Error("익명 로그인 실패: " + error.message);
  const token = data.session.access_token;
  const call = async (path, method = "GET", body) => {
    const res = await fetch(BASE + path, {
      method,
      headers: { Authorization: `Bearer ${token}`, ...(body ? { "Content-Type": "application/json" } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, data: await res.json().catch(() => ({})) };
  };
  return { sb, call };
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const admin = await makeUser();
const g1 = await makeUser();
const g2 = await makeUser();
await admin.call("/api/auth/admin", "POST", { code: env.ADMIN_CODE });
const { data: room } = await admin.call("/api/rooms", "POST", { roomName: "[자동테스트] 4단계", maxPlayers: 10, turnDuration: 180 });
const R = `/api/rooms/${room.id}`;
await g1.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "기사" });
await g2.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "도적" });
const st = async (u = admin) => (await u.call(`${R}/state`)).data;
const s0 = await st();
const pid = (n) => s0.players.find((p) => p.display_name === n).id;
await admin.call(`${R}/players/${pid("기사")}`, "PATCH", { min_attack: 10, max_attack: 10, dodge_rate: 100, escape_rate: 0 });
await admin.call(`${R}/players/${pid("도적")}`, "PATCH", { min_attack: 5, max_attack: 5, dodge_rate: 0, escape_rate: 0 });
const scare = (await admin.call(`${R}/enemies`, "POST", { name: "허수아비", max_hp: 30, min_attack: 3, max_attack: 3, dodge_rate: 0, defense: 2, target_type: "all" })).data.id;
await admin.call(`${R}/enemies`, "POST", { name: "숨은 적", max_hp: 10 });
await admin.call(`${R}/enemies/${scare}/appear`, "POST");

try {
  ok((await admin.call(`${R}/battle/start`, "POST")).data.error?.includes("선공 측"), "선공 측 미설정 시 시작 거부");
  await admin.call(`${R}/settings`, "PATCH", { first_side: "players" });
  ok((await g1.call(`${R}/battle/start`, "POST")).status === 403, "게스트는 전투 시작 불가");
  ok((await admin.call(`${R}/battle/start`, "POST")).status === 200, "전투 시작");
  let s = await st(g1);
  const left = (new Date(s.phase.ends_at) - new Date(s.serverNow)) / 1000;
  ok(s.room.status === "in_progress" && s.phase.phase_number === 1 && s.phase.acting_side === "players" && left > 170 && left <= 180,
    `1사이클 1단계 플레이어 선공턴, 서버 기준 남은 시간 ${Math.round(left)}초`);

  // 행동 제출
  ok((await g1.call(`${R}/actions`, "POST", { action_type: "attack", target_id: scare })).status === 200, "기사: 공격 제출");
  const dup = await g1.call(`${R}/actions`, "POST", { action_type: "dodge" });
  ok(dup.status === 400 && dup.data.error.includes("이미"), "같은 단계 중복 제출 거부");
  ok((await g2.call(`${R}/actions`, "POST", { action_type: "dodge" })).status === 200, "도적: 회피 제출");
  const sg2 = await st(g2);
  ok(sg2.myAction?.action_type === "dodge" && sg2.submissions.length === 2, "본인 행동은 보이고, 제출 여부는 2명 모두 표시");
  const sad = await st(admin);
  ok(sad.myAction === null && sad.submissions.length === 2, "관리자: 제출 여부만 보이고 행동 종류는 안 보임");
  const { data: rlsActs } = await g2.sb.from("actions").select("action_type").eq("room_id", room.id);
  ok(rlsActs.length === 1 && rlsActs[0].action_type === "dodge", "RLS: DB 직접 조회해도 남의 행동은 안 보임");
  ok(!JSON.stringify(sg2).includes('"attack"'), "판정 전 게스트 응답 어디에도 기사의 행동 종류 없음");

  // 조기 판정 → 1(플레이어) 2(적 반응) 3(적 후공) 판정, 4단계 열림
  ok((await g1.call(`${R}/battle/resolve`, "POST")).status === 403, "게스트는 조기 판정 불가");
  ok((await admin.call(`${R}/battle/resolve`, "POST")).status === 200, "관리자 조기 판정 (행동 조기 마감)");
  const decl = (await st(g1));
  ok(decl.phase.status === "declared" && decl.players.every((p) => p.current_hp === 100) && !decl.logs.some((l) => l.stage === "result"),
    "행동 선언만 공개, 결과 공개 전에는 HP 변화·결과 없음");
  await waitReveal(admin, R);
  s = await st(g1);
  const hp = (n) => s.players.find((p) => p.display_name === n)?.current_hp ?? s.enemies.find((e) => e.name === n)?.current_hp;
  ok(s.phase.phase_number === 4 && s.phase.acting_side === "players" && s.phase.phase_type === "reaction", "4단계 플레이어 반응턴으로 진행");
  ok(hp("허수아비") === 22, "공격 10 - 방어력 2 = 8 피해 → 허수아비 22");
  ok(hp("기사") === 97 && hp("도적") === 97, "적 반응턴 반격 3 (도적 회피 0% 실패)");
  ok(s.pendingAttacks.length === 2, "적 후공턴 공격 선언 2건이 반응턴 화면에 표시");
  ok(s.logs.some((l) => l.content === "기사가 허수아비를 공격했다.") && s.logs.some((l) => l.content.includes("기사의 공격 적중! (공격력 10")) && s.logs.some((l) => l.content === "도적이 회피를 시도했다."),
    "행동 선언 → 5초 뒤 결과(공격력·피해) 공개");
  ok(!s.enemies.some((e) => e.name === "숨은 적"), "미등장 적군은 전투 중에도 게스트에게 비공개");
  ok((await g1.call(`${R}/actions`, "POST", { action_type: "dodge" })).status === 200, "기사: 반응턴 회피 제출");

  if (SKIP_WAIT) {
    await admin.call(`${R}/battle/resolve`, "POST");
    await waitReveal(admin, R);
  } else {
    // 서버 예약 작업만으로 판정되는지 확인 (이 스크립트는 tick 요청을 보내지 않음)
    const ends = new Date(s.phase.ends_at).getTime() - new Date(s.serverNow).getTime();
    console.log(`⏳ 제한 시간 종료까지 약 ${Math.round(ends / 1000)}초 대기 (브라우저 요청 없이 서버가 자동 판정하는지 확인)…`);
    await sleep(Math.max(0, ends) + 2000);
    let resolved = false;
    for (let i = 0; i < 12 && !resolved; i++) {
      const x = await st(admin);
      resolved = x.room.current_cycle === 2;
      if (!resolved) await sleep(2000);
    }
    ok(resolved, "제한 시간 종료 → 서버 예약 작업(pg_cron)이 자동 판정, 2사이클로 진행");
  }
  s = await st(g1);
  ok(s.players.find((p) => p.display_name === "기사").current_hp === 97, "기사 반응턴 회피 성공(100%) → 피해 무효");
  ok(s.players.find((p) => p.display_name === "도적").current_hp === 94, "도적 미제출 → 자동 행동 없이 피해 3");
  ok(s.logs.some((l) => l.log_type === "no_action" && l.content.includes("도적")), "미제출 기록");

  // 강제 종료
  ok((await admin.call(`${R}/battle/end`, "POST", { reason: "자동 테스트 종료" })).status === 200, "강제 종료");
  s = await st(g2);
  ok(s.room.status === "ended" && s.room.result === "forced" && s.room.end_reason === "자동 테스트 종료", "결과·사유 기록");
  ok(s.events.some((e) => e.event_type === "battle_ended"), "종료 시스템 메시지");
  const late = await g2.call(`${R}/actions`, "POST", { action_type: "dodge" });
  ok(late.status === 400 && late.data.error.includes("종료"), "종료된 전투에 행동 제출 거부");
  ok((await admin.call(`${R}/battle/end`, "POST", { reason: "x" })).status === 400, "종료 중복 요청 거부");
} finally {
  const del = await admin.call(R, "DELETE");
  ok(del.status === 200, "테스트 방 삭제");
  await admin.call("/api/auth/admin", "DELETE");
}
console.log(`\n🎉 4단계 테스트 ${passed}개 모두 통과`);
process.exit(0);
