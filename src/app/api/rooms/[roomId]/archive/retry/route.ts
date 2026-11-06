// 관리자: 전투 기록 저장 재시도 (자동 저장이 실패했을 때)
import { assertUuid, handle, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId } = await params;
    const status = await rpc<string>("admin_retry_archive", { p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID") });
    return { status };
  });
}
