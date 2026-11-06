// 게스트: 퇴장 (전투 중에는 불가)
import { assertUuid, handle, rpc } from "@/lib/api";
import { requireUser } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireUser(req);
    const { roomId } = await params;
    await rpc("leave_room", { p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID") });
    return { ok: true };
  });
}
