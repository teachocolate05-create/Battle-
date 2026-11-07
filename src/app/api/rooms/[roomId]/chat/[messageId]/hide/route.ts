// 관리자: 채팅 메시지 가리기 / 가리기 해제 (원문은 관리자만 볼 수 있는 곳에 보관)
import { ApiError, assertUuid, handle, readObject, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string; messageId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId, messageId } = await params;
    if (!/^\d+$/.test(messageId)) throw new ApiError(400, "잘못된 메시지 ID입니다.");
    const body = await readObject(req);
    await rpc("admin_hide_chat", { p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID"), p_message_id: Number(messageId), p_hide: body.hide !== false });
    return { ok: true };
  });
}
