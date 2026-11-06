// =====================================================================
// 3단계 자동 테스트 (실제 Supabase + 실행 중인 개발 서버 대상)
//   터미널 1: npm run dev     터미널 2: npm run test:stage3
// 능력치·HP 조정, 적군 5명 제한, 미등장 적군 비공개, 등장 연출, 아이템 지급, 선공 설정을 확인합니다.
// =====================================================================
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const env = {};
try {
  for (const line of readFileSync(new URL("../.env.local", import.meta.url), "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
} catch {
  console.error("❌ .env.local 파일이 없습니다.");
  process.exit(1);
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
const g2 = await makeUser();
ok((await admin.call("/api/auth/admin", "POST", { code: env.ADMIN_CODE })).status === 200, "관리자 인증");
const { data: room } = await admin.call("/api/rooms", "POST", { roomName: "[자동테스트] 3단계", maxPlayers: 10, turnDuration: 180 });
const R = `/api/rooms/${room.id}`;
await g1.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "전사" });
await g2.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "궁수" });
const st = async (u = admin) => (await u.call(`${R}/state`)).data;
const s0 = await st();
const p1 = s0.players.find((p) => p.display_name === "전사");
const p2 = s0.players.find((p) => p.display_name === "궁수");

try {
  // 플레이어 능력치
  ok((await admin.call(`${R}/players/${p1.id}`, "PATCH", { display_name: "전사 A", max_hp: 120, current_hp: 120, min_attack: 6, max_attack: 12, dodge_rate: 25, escape_rate: 10 })).status === 200, "능력치 저장");
  const s1 = await st(g1);
  ok(s1.me.player.max_hp === 120 && s1.me.player.min_attack === 6 && s1.me.player.display_name === "전사 A", "게스트 본인 화면에 새 능력치 반영");
  ok((await g1.call(`${R}/players/${p1.id}`, "PATCH", { max_hp: 9999 })).status === 403, "게스트는 능력치 수정 불가 (API)");
  const bad = await admin.call(`${R}/players/${p1.id}`, "PATCH", { min_attack: 20, max_attack: 10 });
  ok(bad.status === 400 && bad.data.error.includes("최소 공격력"), "잘못된 능력치 거부 (최소 > 최대)");
  ok((await admin.call(`${R}/players/${p2.id}/hp`, "POST", { hp: 40, reason: "함정" })).status === 200, "HP 직접 조정");
  const { data: hpLogs } = await admin.sb.from("battle_logs").select("content").eq("room_id", room.id).eq("log_type", "admin_hp");
  ok(hpLogs.some((l) => l.content.includes("함정")), "HP 변경 내역이 전투 로그에 기록됨");

  // 적군
  const e1 = (await admin.call(`${R}/enemies`, "POST", { name: "나무 허수아비", max_hp: 100, min_attack: 1, max_attack: 4 })).data.id;
  const e2 = (await admin.call(`${R}/enemies`, "POST", { name: "그림자 거인", max_hp: 300, appearance_message: "어둠 속에서 거대한 그림자가 모습을 드러냈다.", target_type: "specific", target_player_id: p2.id })).data.id;
  for (const n of ["적3", "적4", "적5"]) await admin.call(`${R}/enemies`, "POST", { name: n });
  const sixth = await admin.call(`${R}/enemies`, "POST", { name: "적6" });
  ok(sixth.status === 400 && sixth.data.error.includes("최대 5명"), "적군 6번째 등록 거부 (최대 5명)");
  ok((await st()).enemies.length === 5, "관리자는 등록된 적군 5명 모두 확인");
  ok((await st(g1)).enemies.length === 0, "등록만 된 적군은 게스트 API 응답에 없음");
  const { data: rlsEnemies } = await g1.sb.from("enemies").select("id").eq("room_id", room.id);
  ok((rlsEnemies ?? []).length === 0, "RLS: 게스트가 DB를 직접 조회해도 미등장 적군이 안 보임");

  // 실시간 + 등장
  await g1.sb.realtime.setAuth((await g1.sb.auth.getSession()).data.session.access_token);
  let ch;
  const got = new Promise((resolve) => {
    const t = setTimeout(() => resolve(null), 15000);
    ch = g1.sb
      .channel("s3-" + room.id)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "battle_events", filter: `room_id=eq.${room.id}` }, (p) => {
        clearTimeout(t);
        resolve(p.new);
      })
      .subscribe(async (status) => {
        if (status === "SUBSCRIBED") {
          await new Promise((r) => setTimeout(r, 1000));
          await admin.call(`${R}/enemies/${e1}/appear`, "POST");
        }
      });
  });
  const ev = await got;
  await g1.sb.removeChannel(ch);
  ok(ev && ev.event_message === "나무 허수아비가 등장했다!", "등장 실행 → 게스트가 실시간으로 시스템 이벤트 수신 (기본 문구)");
  const dup = await admin.call(`${R}/enemies/${e1}/appear`, "POST");
  ok(dup.status === 400 && dup.data.error.includes("이미 등장"), "중복 등장 방지");
  const appear2 = await admin.call(`${R}/enemies/${e2}/appear`, "POST");
  ok(appear2.data.message === "어둠 속에서 거대한 그림자가 모습을 드러냈다." && appear2.data.appearance_order === 2, "사용자 등장 문구 + 등장 순서 2");
  const gs = await st(g1);
  ok(gs.enemies.length === 2 && gs.enemies.every((e) => e.appearance_status === "appeared"), "게스트에게는 등장한 적군 2명만 보임");
  ok(gs.enemies.every((e) => e.target_player_id === null), "게스트에게 적군의 공격 대상 설정은 숨김");
  ok(gs.events.length === 2 && gs.events[0].event_message.includes("허수아비"), "시스템 이벤트 2개 시간순");
  ok((await admin.call(`${R}/enemies/${e1}`, "DELETE")).status === 400, "등장한 적군 삭제 불가");

  // 아이템
  const heal = (await admin.call(`${R}/items`, "POST", { item_type: "heal", name: "소형 회복약", description: "HP 20 회복", effect_value: 20 })).data.id;
  const bomb = (await admin.call(`${R}/items`, "POST", { item_type: "damage", name: "투척 폭탄", effect_value: 15 })).data.id;
  ok(heal && bomb, "아이템 2종 생성 (회복 / 고정 피해)");
  ok((await admin.call(`${R}/items`, "POST", { item_type: "buff", name: "x", effect_value: 1 })).status === 400, "지원하지 않는 아이템 종류 거부");
  await admin.call(`${R}/items/${heal}/grant`, "POST", { playerId: p1.id, quantity: 2 });
  ok((await admin.call(`${R}/items/${heal}/grant`, "POST", { playerId: p1.id, quantity: 1 })).data.total === 3, "아이템 지급 + 수량 누적");
  await admin.call(`${R}/items/${bomb}/grant`, "POST", { playerId: p2.id, quantity: 1 });
  const g1s = await st(g1);
  ok(g1s.inventory.length === 1 && g1s.inventory[0].quantity === 3, "전사는 자기 아이템만 보임 (회복약 ×3)");
  const { data: rlsInv } = await g1.sb.from("player_inventory").select("*").eq("room_id", room.id);
  ok(rlsInv.length === 1, "RLS: 남의 인벤토리 조회 불가");

  // 선공
  ok((await admin.call(`${R}/settings`, "PATCH", { first_side: "enemies", turn_duration: 300 })).status === 200, "선공 측 + 턴 시간 저장");
  const fin = await st(g2);
  ok(fin.room.first_side === "enemies" && fin.room.turn_duration === 300, "게스트 화면에 선공 설정 반영");
  ok((await g2.call(`${R}/settings`, "PATCH", { first_side: "players" })).status === 403, "게스트는 선공 설정 불가");
} finally {
  ok((await admin.call(R, "DELETE")).status === 200, "테스트 방 삭제");
  await admin.call("/api/auth/admin", "DELETE");
}
console.log(`\n🎉 3단계 테스트 ${passed}개 모두 통과`);
process.exit(0);
