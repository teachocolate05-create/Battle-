// 관리자: 적군 등장 실행 (등장 연출 메시지가 전투 화면/채팅에 시스템 메시지로 표시됨)
import { assertUuid, handle, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string; enemyId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId, enemyId } = await params;
    return rpc<{ appearance_order: number; message: string }>("admin_appear_enemy", {
      p_user_id: user.id,
      p_room_id: assertUuid(roomId, "방 ID"),
      p_enemy_id: assertUuid(enemyId, "적군 ID"),
    });
  });
}
