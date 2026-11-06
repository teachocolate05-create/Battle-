// 관리자: 플레이어 현재 HP 직접 조정 (전투 로그에 기록됨)
import { assertUuid, handle, int, readObject, rpc, str } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string; playerId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId, playerId } = await params;
    const body = await readObject(req);
    await rpc("admin_set_player_hp", {
      p_user_id: user.id,
      p_room_id: assertUuid(roomId, "방 ID"),
      p_player_id: assertUuid(playerId, "플레이어 ID"),
      p_hp: int(body.hp),
      p_reason: str(body.reason).slice(0, 100),
    });
    return { ok: true };
  });
}
