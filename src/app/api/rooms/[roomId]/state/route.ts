// 방 전체 상태 (권한에 따라 DB 함수에서 걸러서 전달)
import { assertUuid, handle } from "@/lib/api";
import { requireUser } from "@/lib/auth";
import { buildRoomState } from "@/lib/roomState";

export async function GET(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireUser(req);
    const { roomId } = await params;
    return buildRoomState(assertUuid(roomId, "방 ID"), user.id);
  });
}
