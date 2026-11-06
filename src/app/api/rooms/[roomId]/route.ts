// 관리자: 전투방 삭제 (종료된 전투 기록은 보관함에 남음)
import { assertUuid, handle, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function DELETE(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId } = await params;
    await rpc("admin_delete_room", { p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID") });
    return { ok: true };
  });
}
