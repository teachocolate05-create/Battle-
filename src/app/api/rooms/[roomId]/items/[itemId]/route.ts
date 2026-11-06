// 관리자: 아이템 삭제 (전투 시작 전에만)
import { assertUuid, handle, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function DELETE(req: Request, { params }: { params: Promise<{ roomId: string; itemId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId, itemId } = await params;
    await rpc("admin_delete_item", {
      p_user_id: user.id,
      p_room_id: assertUuid(roomId, "방 ID"),
      p_item_id: assertUuid(itemId, "아이템 ID"),
    });
    return { ok: true };
  });
}
