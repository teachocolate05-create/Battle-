// 관리자: 참가자 프로필 수정 (전투 중에도 가능, 수정 내역 기록)
import { assertUuid, handle, readObject, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function PATCH(req: Request, { params }: { params: Promise<{ roomId: string; playerId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId, playerId } = await params;
    const changes = await rpc("admin_update_profile", {
      p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID"),
      p_player_id: assertUuid(playerId, "플레이어 ID"), p_data: await readObject(req),
    });
    return { changes };
  });
}
