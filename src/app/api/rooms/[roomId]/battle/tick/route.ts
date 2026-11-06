// 참가자/관리자: 타이머가 0초가 되면 호출 → 서버가 DB 시각으로 만료 여부를 직접 확인해서 판정
// (pg_cron 이 5초마다 같은 일을 하므로, 이 요청은 반응 속도를 높이는 보조 수단입니다)
import { assertUuid, handle, rpc } from "@/lib/api";
import { requireUser } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireUser(req);
    const { roomId } = await params;
    const resolved = await rpc<number>("room_tick", { p_user_id: user.id, p_room_id: assertUuid(roomId, "방 ID") });
    return { resolved };
  });
}
