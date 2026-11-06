// 관리자: 플레이어에게 아이템 지급
import { assertUuid, handle, int, readObject, rpc, str } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string; itemId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId, itemId } = await params;
    const body = await readObject(req);
    const total = await rpc<number>("admin_grant_item", {
      p_user_id: user.id,
      p_room_id: assertUuid(roomId, "방 ID"),
      p_item_id: assertUuid(itemId, "아이템 ID"),
      p_player_id: assertUuid(str(body.playerId), "플레이어 ID"),
      p_quantity: int(body.quantity),
    });
    return { total };
  });
}
