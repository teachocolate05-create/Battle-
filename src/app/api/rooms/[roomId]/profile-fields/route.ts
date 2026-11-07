// 관리자: 참가자가 채울 추가 프로필 항목 정의 (최대 5개)
import { ApiError, assertUuid, handle, readObject, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function PUT(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId } = await params;
    const body = await readObject(req);
    if (!Array.isArray(body.fields)) throw new ApiError(400, "잘못된 요청 형식입니다.");
    const fields = await rpc("admin_set_profile_fields", {
      p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID"), p_fields: body.fields,
    });
    return { fields };
  });
}
