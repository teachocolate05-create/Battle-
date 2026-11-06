// =====================================================================
// 7단계 자동 테스트 (실제 Supabase + 실행 중인 개발 서버 대상)
//   터미널 1: npm run dev     터미널 2: npm run test:stage7
// 전투 종료 → 자동 저장 → 보관함 목록/상세(로그·채팅·참가자·적군 등장) → 중복 저장 방지 → 방 삭제 후에도 유지 → 권한
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
  if (!cond) {
    console.error(`❌ 실패: ${name}`);
    process.exit(1);
  }
  passed++;
  console.log(`✅ ${name}`);
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

const admin = await makeUser();
const g1 = await makeUser();
await admin.call("/api/auth/admin", "POST", { code: env.ADMIN_CODE });
const name = `[자동테스트] 7단계 ${Date.now() % 100000}`;
const { data: room } = await admin.call("/api/rooms", "POST", { roomName: name, maxPlayers: 10, turnDuration: 180 });
const R = `/api/rooms/${room.id}`;
await g1.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "영웅" });
const pid = (await admin.call(`${R}/state`)).data.players[0].id;
await admin.call(`${R}/players/${pid}`, "PATCH", { min_attack: 50, max_attack: 50 });
const slime = (await admin.call(`${R}/enemies`, "POST", { name: "슬라임", max_hp: 40, appearance_message: "말랑한 슬라임이 튀어나왔다!" })).data.id;
await admin.call(`${R}/enemies`, "POST", { name: "숨은 보스", max_hp: 10 });
const herb = (await admin.call(`${R}/items`, "POST", { item_type: "heal", name: "약초", effect_value: 10 })).data.id;
await admin.call(`${R}/items/${herb}/grant`, "POST", { playerId: pid, quantity: 2 });
await admin.call(`${R}/chat`, "POST", { message: "옛날 옛적, 작은 마을에…" });
await admin.call(`${R}/enemies/${slime}/appear`, "POST");
await admin.call(`${R}/settings`, "PATCH", { first_side: "players" });
await admin.call(`${R}/battle/start`, "POST");
await g1.call(`${R}/actions`, "POST", { action_type: "item", item_id: herb });
await g1.call(`${R}/chat`, "POST", { message: "약초 먹을게!" });
await admin.call(`${R}/battle/resolve`, "POST");
await g1.call(`${R}/actions`, "POST", { action_type: "attack", target_id: slime });
await admin.call(`${R}/battle/resolve`, "POST");

let s = (await admin.call(`${R}/state`)).data;
ok(s.room.status === "in_progress", "적군이 남아 있으면(미등장 보스) 슬라임을 쓰러뜨려도 전투 계속");
ok((await admin.call(`${R}/battle/end`, "POST", { reason: "보스는 다음 시간에" })).status === 200, "관리자 강제 종료");
s = (await admin.call(`${R}/state`)).data;
ok(s.room.status === "ended" && s.room.archive_status === "saved", "종료와 동시에 자동 저장 완료 (저장 버튼 없이)");

const list = (await admin.call("/api/archives")).data.archives;
const item = list.find((a) => a.room_id === room.id);
ok(item && item.room_name_snapshot === name && item.result === "forced" && item.player_count === 1 && item.total_cycles >= 1,
  "보관함 목록: 날짜·방 이름·결과·사이클 수");
const det = (await admin.call(`/api/archives/${item.id}`)).data;
const d = det.archive_data;
ok(d.room.end_reason === "보스는 다음 시간에" && d.room.first_side === "players" && d.room.started_at && d.room.ended_at, "상세: 기본 정보 + 종료 사유");
ok(d.players[0].nickname === "영웅" && d.players[0].items_used[0]?.item_name === "약초" && d.players[0].damage_dealt === 40,
  "상세: 참가자 (사용 아이템, 누적 피해)");
const sl = d.enemies.find((e) => e.name === "슬라임");
const boss = d.enemies.find((e) => e.name === "숨은 보스");
ok(sl.appeared && sl.appearance_order === 1 && sl.appeared_at && sl.dead && !boss.appeared, "상세: 적군 등장 여부·순서·시각, 사망 여부");
ok(d.logs.some((l) => l.cycle_number === 1 && l.phase_number === 1 && l.content.includes("약초")) &&
   d.logs.some((l) => l.log_type === "battle_ended"), "상세: 사이클·단계별 전투 로그 + 종료 결과");
ok(d.chat.length === 2 && d.chat[0].message.includes("옛날") && d.events.some((e) => e.event_type === "enemy_appeared"),
  "상세: 채팅 기록과 시스템 메시지(적군 등장)");

ok((await admin.call(`${R}/archive/retry`, "POST")).data.status === "already_saved", "재시도해도 중복 저장 안 함");
ok((await admin.call("/api/archives")).data.archives.filter((a) => a.room_id === room.id).length === 1, "보관함에 1건만");

ok((await g1.call("/api/archives")).status === 403, "게스트는 보관함 접근 불가 (API)");
ok((await g1.call(`/api/archives/${item.id}`)).status === 403, "게스트는 기록 상세 접근 불가 (API)");
const { data: rls } = await g1.sb.from("battle_archives").select("id");
ok((rls ?? []).length === 0, "RLS: 게스트가 DB에서 직접 보관함을 읽을 수 없음");

ok((await admin.call(R, "DELETE")).status === 200, "전투방 삭제");
const after = (await admin.call(`/api/archives/${item.id}`)).data;
ok(after.archive_data?.room?.room_name === name, "방을 삭제해도 전투 기록은 보관함에 남음");
await admin.call("/api/auth/admin", "DELETE");
console.log(`\n🎉 7단계 테스트 ${passed}개 모두 통과`);
process.exit(0);
