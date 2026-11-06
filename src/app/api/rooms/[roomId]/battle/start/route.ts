// 관리자: 전투 시작
import { assertUuid, handle, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId } = await params;
    await rpc("admin_start_battle", { p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID") });
    return { ok: true };
  });
}
