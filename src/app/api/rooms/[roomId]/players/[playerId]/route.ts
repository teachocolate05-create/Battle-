// 관리자: 플레이어 능력치 수정 (전투 중에는 현재 HP만)
import { assertUuid, handle, readObject, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function PATCH(req: Request, { params }: { params: Promise<{ roomId: string; playerId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId, playerId } = await params;
    await rpc("admin_update_player", {
      p_user_id: user.id,
      p_room_id: assertUuid(roomId, "방 ID"),
      p_player_id: assertUuid(playerId, "플레이어 ID"),
      p_data: await readObject(req),
    });
    return { ok: true };
  });
}
