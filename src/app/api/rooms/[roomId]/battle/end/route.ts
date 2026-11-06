// 관리자: 전투 강제 종료 (사유 기록)
import { assertUuid, handle, readObject, rpc, str } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId } = await params;
    const body = await readObject(req);
    await rpc("admin_end_battle", { p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID"), p_reason: str(body.reason) });
    return { ok: true };
  });
}
