// =====================================================================
// 5·6단계 자동 테스트 (실제 Supabase + 실행 중인 개발 서버 대상)
//   터미널 1: npm run dev     터미널 2: npm run test:stage56
// 채팅(실시간·검증·스팸·XSS·읽기 전용), 채팅과 전투의 독립성, 단계별 로그 기록, 이전 기록 페이지 조회
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
  return { sb, call, token };
}

const admin = await makeUser();
const g1 = await makeUser();
const g2 = await makeUser();
const outsider = await makeUser();
await admin.call("/api/auth/admin", "POST", { code: env.ADMIN_CODE });
const { data: room } = await admin.call("/api/rooms", "POST", { roomName: "[자동테스트] 5·6단계", maxPlayers: 10, turnDuration: 180 });
const R = `/api/rooms/${room.id}`;
await g1.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "기사" });
await g2.call("/api/rooms/join", "POST", { code: room.room_code, nickname: "궁수" });
const st = async (u) => (await u.call(`${R}/state`)).data;

try {
  // ---------- 채팅 + 실시간 ----------
  await g2.sb.realtime.setAuth(g2.token);
  let ch;
  const got = new Promise((resolve) => {
    const t = setTimeout(() => resolve(null), 15000);
    ch = g2.sb.channel("c56-" + room.id)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "chat_messages", filter: `room_id=eq.${room.id}` }, (p) => {
        clearTimeout(t);
        resolve(p.new);
      })
      .subscribe(async (s) => {
        if (s === "SUBSCRIBED") {
          await new Promise((r) => setTimeout(r, 1000));
          await admin.call(`${R}/chat`, "POST", { message: "깊은 숲속, 바람 소리만 들린다…" });
        }
      });
  });
  const ev = await got;
  await g2.sb.removeChannel(ch);
  ok(ev && ev.nickname === "관리자" && ev.sender_role === "admin", "관리자 스토리 채팅 → 게스트가 실시간 수신");
  ok((await g1.call(`${R}/chat`, "POST", { message: "이번 턴에는 공격할게!" })).status === 200, "게스트 채팅 전송");
  const xss = '<img src=x onerror="alert(1)"><script>alert(2)</script>';
  ok((await g2.call(`${R}/chat`, "POST", { message: xss })).status === 200, "HTML/스크립트가 섞인 메시지도 글자로 저장");
  let s1 = await st(g1);
  ok(s1.chat.length === 3 && s1.chat[1].is_mine === true && s1.chat[0].is_mine === false, "채팅 목록 + 내 메시지 표시");
  ok(s1.chat[2].message === xss && !JSON.stringify(s1.chat).includes("sender_id"), "메시지는 원문 그대로(화면에서 텍스트로만 출력), 보낸 사람 ID 비공개");
  const long = await g1.call(`${R}/chat`, "POST", { message: "가".repeat(301) });
  ok(long.status === 400 && long.data.error.includes("300자"), "300자 초과 거부");
  ok((await g1.call(`${R}/chat`, "POST", { message: "   " })).status === 400, "빈 메시지 거부");
  ok((await outsider.call(`${R}/chat`, "POST", { message: "끼어들기" })).status === 400, "다른 방 사람은 채팅 불가");
  ok((await outsider.call(`${R}/history?kind=chat`)).status === 403, "다른 방 사람은 채팅 기록 조회 불가");
  const { data: rlsChat } = await outsider.sb.from("chat_messages").select("id").eq("room_id", room.id);
  ok((rlsChat ?? []).length === 0, "RLS: 다른 방 채팅을 DB에서 직접 읽을 수 없음");
  for (const m of ["a", "b", "c", "d"]) await g1.call(`${R}/chat`, "POST", { message: m });
  const spam = await g1.call(`${R}/chat`, "POST", { message: "e" });
  ok(spam.status === 400 && spam.data.error.includes("너무 빠르게"), "스팸 방지 (10초에 5개)");

  // ---------- 채팅과 전투의 독립성 ----------
  const goblin = (await admin.call(`${R}/enemies`, "POST", { name: "고블린", max_hp: 40, target_type: "all" })).data.id;
  await admin.call(`${R}/chat`, "POST", { message: "그때, 덤불이 흔들렸다!" });
  await admin.call(`${R}/enemies/${goblin}/appear`, "POST");
  await admin.call(`${R}/settings`, "PATCH", { first_side: "players" });
  await admin.call(`${R}/battle/start`, "POST");
  ok((await g2.call(`${R}/chat`, "POST", { message: "나는 회피할게." })).status === 200, "전투 중 채팅 가능");
  let s2 = await st(g2);
  ok(s2.submissions.length === 0 && s2.myAction === null, "채팅을 보내도 행동 제출로 처리되지 않음");
  ok(s2.events.some((e) => e.event_type === "enemy_appeared") && s2.chat.some((c) => c.message.includes("덤불")),
    "적군 등장은 시스템 이벤트(별도 저장), 스토리는 채팅 — 분리 저장");
  ok(!s2.chat.some((c) => c.message.includes("등장했다")), "등장 메시지는 채팅 테이블에 중복 저장하지 않음");
  ok((await g2.call(`${R}/actions`, "POST", { action_type: "attack", target_id: goblin })).status === 200, "채팅 후에도 행동 제출 정상");

  // ---------- 5단계: 단계별 로그 ----------
  await admin.call(`${R}/battle/resolve`, "POST");
  s2 = await st(g1);
  const byPhase = (n) => s2.logs.filter((l) => l.cycle_number === 1 && l.phase_number === n && l.log_type !== "phase_started");
  ok(byPhase(1).length > 0 && byPhase(2).length > 0 && byPhase(3).length > 0, "1~3단계 로그가 단계 번호와 함께 따로 기록 (화면에서 2개씩 묶음 표시)");
  ok(s2.logs.filter((l) => l.log_type === "phase_started" && l.cycle_number === 1).length === 4, "단계 시작 기록 4개 (1사이클 4단계 진행 중)");
  ok(byPhase(1).some((l) => l.content.includes("궁수가 고블린을 공격했다")), "판정 후 행동 공개");
  ok(s2.logs.some((l) => l.log_type === "enemy_appeared"), "적군 등장 기록이 전투 로그에도 포함");

  // ---------- 이전 기록 페이지 조회 ----------
  const lastLog = s2.logs.at(-1).id;
  const hist = await g1.call(`${R}/history?kind=logs&before=${lastLog}`);
  ok(hist.status === 200 && hist.data.items.length === s2.logs.length - 1 && hist.data.items.every((l) => l.id < lastLog), "전투 로그 이전 기록 조회");
  const chist = await g1.call(`${R}/history?kind=chat&before=${s2.chat.at(-1).id}`);
  ok(chist.status === 200 && chist.data.items.length === s2.chat.length - 1, "채팅 이전 기록 조회");
  ok((await g1.call(`${R}/history?kind=secret`)).status === 400, "잘못된 기록 종류 거부");

  // ---------- 종료 → 읽기 전용 ----------
  await admin.call(`${R}/battle/end`, "POST", { reason: "테스트 종료" });
  const ro = await g1.call(`${R}/chat`, "POST", { message: "끝났나?" });
  ok(ro.status === 400 && ro.data.error.includes("읽기 전용"), "전투 종료 후 채팅 읽기 전용");
  ok((await st(g1)).chat.length >= 4, "종료 후에도 채팅 기록 열람 가능");
} finally {
  ok((await admin.call(R, "DELETE")).status === 200, "테스트 방 삭제");
  await admin.call("/api/auth/admin", "DELETE");
}
console.log(`\n🎉 5·6단계 테스트 ${passed}개 모두 통과`);
process.exit(0);
