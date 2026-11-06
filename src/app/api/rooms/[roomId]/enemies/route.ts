// 관리자: 적군 등록 (방당 최대 5명 — DB 함수에서 검증). 등록만 하고 등장시키지는 않음.
import { assertUuid, handle, readObject, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId } = await params;
    const id = await rpc<string>("admin_save_enemy", {
      p_user_id: user.id,
      p_room_id: assertUuid(roomId, "방 ID"),
      p_enemy_id: null,
      p_data: await readObject(req),
    });
    return { id };
  });
}
