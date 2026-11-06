// 게스트: 방 코드로 입장 (이미 참가 중이면 기존 캐릭터로 복구)
import { handle, readJson, rpc, str } from "@/lib/api";
import { requireUser } from "@/lib/auth";

export async function POST(req: Request) {
  return handle(async () => {
    const user = await requireUser(req);
    const body = await readJson(req);
    return rpc<{ room_id: string; member_id: string; restored: boolean }>("join_room", {
      p_user_id: user.id,
      p_code: str(body.code),
      p_nickname: str(body.nickname),
      p_password: str(body.password) || null,
    });
  });
}
