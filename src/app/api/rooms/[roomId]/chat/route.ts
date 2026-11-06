// 채팅 전송 (관리자/활성 참가자). 전투 행동·판정과 완전히 무관합니다.
import { assertUuid, handle, readObject, rpc, str } from "@/lib/api";
import { requireUser } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireUser(req);
    const { roomId } = await params;
    const body = await readObject(req);
    // 300자 검사는 DB 함수에서 정확히 하고, 여기서는 지나치게 큰 요청만 차단
    const message = str(body.message).slice(0, 2000);
    return rpc("send_chat", { p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID"), p_message: message });
  });
}
