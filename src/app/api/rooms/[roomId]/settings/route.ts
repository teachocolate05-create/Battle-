// 관리자: 선공 측 / 턴 제한 시간 설정 (전투 시작 전에만)
import { assertUuid, handle, readObject, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function PATCH(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId } = await params;
    await rpc("admin_update_room_settings", {
      p_user_id: user.id,
      p_room_id: assertUuid(roomId, "방 ID"),
      p_data: await readObject(req),
    });
    return { ok: true };
  });
}
