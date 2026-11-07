// 참가자: 본인 프로필 수정 (전투 시작 전에만, 능력치는 수정 불가 — DB 함수에서 검증)
import { assertUuid, handle, readObject, rpc } from "@/lib/api";
import { requireUser } from "@/lib/auth";

export async function PATCH(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireUser(req);
    const { roomId } = await params;
    const changes = await rpc("update_my_profile", {
      p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID"), p_data: await readObject(req),
    });
    return { changes };
  });
}
