// =====================================================================
// 전체 자동 테스트: 1차(2~7단계) + v2(프로필·관리자 도구·결과 공개·채팅/기록)를 순서대로 실행
//   로컬:   npm run dev   (다른 터미널)  →  npm run test:all
//   배포본: npm run test:all -- https://내-사이트.vercel.app
//   빠르게: npm run test:all -- http://localhost:3000 --skip-wait   (4단계 3분 대기 생략)
// ※ .env.local 의 키와 관리자 코드는 배포 사이트와 같아야 합니다.
// =====================================================================
import { spawnSync } from "node:child_process";

const args = process.argv.slice(2);
const base = args.find((a) => a.startsWith("http")) ?? "http://localhost:3000";
const skipWait = args.includes("--skip-wait");
const stages = ["stage2", "stage3", "stage4", "stage56", "stage7", "v2-profile", "v2-admin", "v2-reveal", "v2-chat"];
const results = [];
for (const s of stages) {
  console.log(`\n━━━━━━━━ ${s} (${base}) ━━━━━━━━`);
  const extra = s === "stage4" && skipWait ? ["--skip-wait"] : [];
  const r = spawnSync(process.execPath, [`scripts/smoke-test-${s}.mjs`, base, ...extra], { stdio: "inherit" });
  results.push([s, r.status === 0]);
  if (r.status !== 0) break;
}
console.log("\n━━━━━━━━ 결과 ━━━━━━━━");
for (const [s, ok] of results) console.log(`${ok ? "✅" : "❌"} ${s}`);
const allOk = results.length === stages.length && results.every(([, ok]) => ok);
console.log(allOk ? "\n🎉 전체 테스트 통과" : "\n❌ 실패한 단계가 있습니다. 위 메시지를 확인하세요.");
process.exit(allOk ? 0 : 1);
