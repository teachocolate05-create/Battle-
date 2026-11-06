// 내 정보: 관리자 여부 + 참여 중인 방 목록 (재접속 복구용)
import { handle, toApiError } from "@/lib/api";
import { isAdmin, requireUser } from "@/lib/auth";
import { supabaseAdmin } from "@/lib/supabase/admin";
import type { MeResponse } from "@/lib/types";

export async function GET(req: Request) {
  return handle(async (): Promise<MeResponse> => {
    const user = await requireUser(req);
    const { data, error } = await supabaseAdmin()
      .from("room_members")
      .select("room_id, nickname, rooms!inner(room_name, room_code, status)")
      .eq("user_id", user.id)
      .eq("status", "active");
    if (error) throw toApiError(error);
    type Row = { room_id: string; nickname: string; rooms: { room_name: string; room_code: string; status: MeResponse["rooms"][number]["status"] } };
    return {
      userId: user.id,
      isAdmin: await isAdmin(user.id),
      rooms: ((data ?? []) as unknown as Row[]).map((r) => ({
        room_id: r.room_id,
        nickname: r.nickname,
        room_name: r.rooms.room_name,
        room_code: r.rooms.room_code,
        status: r.rooms.status,
      })),
    };
  });
}
