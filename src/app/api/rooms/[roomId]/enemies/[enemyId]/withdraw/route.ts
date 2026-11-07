// 관리자: 적군 퇴장 (전장에서 물러남 — 공격하지도 받지도 않음, 다시 등장시킬 수 있음)
import { assertUuid, handle, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string; enemyId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId, enemyId } = await params;
    return rpc("admin_withdraw_enemy", { p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID"), p_enemy_id: assertUuid(enemyId, "적군 ID") });
  });
}
