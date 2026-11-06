// 이전 기록 더 보기: ?kind=chat|logs&before=<id>
import { ApiError, assertUuid, handle } from "@/lib/api";
import { requireUser } from "@/lib/auth";
import { getHistory } from "@/lib/roomState";

export async function GET(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireUser(req);
    const { roomId } = await params;
    const url = new URL(req.url);
    const kind = url.searchParams.get("kind");
    if (kind !== "chat" && kind !== "logs") throw new ApiError(400, "잘못된 기록 종류입니다.");
    const beforeRaw = url.searchParams.get("before");
    const before = beforeRaw && /^\d+$/.test(beforeRaw) ? Number(beforeRaw) : null;
    return getHistory(assertUuid(roomId, "방 ID"), user.id, kind, before);
  });
}
