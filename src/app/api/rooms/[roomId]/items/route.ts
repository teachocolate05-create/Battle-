// 관리자: 아이템 생성 (HP 회복 / 적군 고정 피해)
import { assertUuid, handle, readObject, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

export async function POST(req: Request, { params }: { params: Promise<{ roomId: string }> }) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId } = await params;
    const id = await rpc<string>("admin_create_item", {
      p_user_id: user.id,
      p_room_id: assertUuid(roomId, "방 ID"),
      p_data: await readObject(req),
    });
    return { id };
  });
}
