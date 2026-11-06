// 관리자: 참가자 강퇴
import { assertUuid, handle, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string; memberId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId, memberId } = await params;
    await rpc("admin_kick_member", {
      p_user_id: user.id,
      p_room_id: assertUuid(roomId, "방 ID"),
      p_member_id: assertUuid(memberId, "참가자 ID"),
    });
    return { ok: true };
  });
}
