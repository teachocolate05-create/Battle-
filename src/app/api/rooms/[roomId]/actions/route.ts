// 게스트: 행동 제출 (단계당 1회). 판정은 시간 종료 시 서버에서 일괄 처리.
import { assertUuid, handle, readObject, rpc, str } from "@/lib/api";
import { requireUser } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireUser(req);
    const { roomId } = await params;
    const body = await readObject(req);
    // 필요한 값만 골라서 전달 (그 외 값은 무시)
    const data = { action_type: str(body.action_type), target_id: str(body.target_id), item_id: str(body.item_id) };
    await rpc("submit_action", { p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID"), p_data: data });
    return { ok: true };
  });
}
