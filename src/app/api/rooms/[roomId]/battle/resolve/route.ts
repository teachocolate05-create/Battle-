// 관리자: 조기 판정 (현재 플레이어 단계를 시간 종료 전에 판정)
import { assertUuid, handle, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId } = await params;
    await rpc("admin_resolve_now", { p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID") });
    return { ok: true };
  });
}
