// 관리자 코드 확인 → 현재 사용자(브라우저)를 관리자로 등록 / 해제
import { createHash, timingSafeEqual } from "node:crypto";
import { ApiError, handle, readJson, rpc, str } from "@/lib/api";
import { requireAdmin, requireUser } from "@/lib/auth";

function sameSecret(a: string, b: string) {
  // 길이와 무관하게 일정한 시간으로 비교 (추측 공격 방지)
  const ha = createHash("sha256").update(a).digest();
  const hb = createHash("sha256").update(b).digest();
  return timingSafeEqual(ha, hb);
}

export async function POST(req: Request) {
  return handle(async () => {
    const user = await requireUser(req);
    const body = await readJson(req);
    const code = str(body.code).trim();
    const adminCode = process.env.ADMIN_CODE;
    if (!adminCode) throw new ApiError(500, "서버에 ADMIN_CODE 환경 변수가 설정되지 않았습니다.");
    if (!code || !sameSecret(code, adminCode)) {
      await new Promise((r) => setTimeout(r, 700)); // 무차별 대입 속도 늦추기
      throw new ApiError(401, "관리자 코드가 올바르지 않습니다.");
    }
    await rpc("register_admin", { p_user_id: user.id });
    return { ok: true };
  });
}

export async function DELETE(req: Request) {
  return handle(async () => {
    const user = await requireAdmin(req);
    await rpc("unregister_admin", { p_user_id: user.id });
    return { ok: true };
  });
}
