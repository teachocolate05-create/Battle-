// 관리자: 적군 수정 / 삭제(미등장 적군만)
import { assertUuid, handle, readObject, rpc } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";

type Ctx = { params: Promise<{ roomId: string; enemyId: string }> };

export async function PATCH(req: Request, { params }: Ctx) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId, enemyId } = await params;
    await rpc("admin_save_enemy", {
      p_user_id: user.id,
      p_room_id: assertUuid(roomId, "방 ID"),
      p_enemy_id: assertUuid(enemyId, "적군 ID"),
      p_data: await readObject(req),
    });
    return { ok: true };
  });
}

export async function DELETE(req: Request, { params }: Ctx) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const { roomId, enemyId } = await params;
    await rpc("admin_delete_enemy", {
      p_user_id: user.id,
      p_room_id: assertUuid(roomId, "방 ID"),
      p_enemy_id: assertUuid(enemyId, "적군 ID"),
    });
    return { ok: true };
  });
}
