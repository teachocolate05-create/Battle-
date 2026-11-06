// 관리자: 전투방 목록 / 생성
import { ApiError, handle, int, readJson, rpc, str, toApiError } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";
import { supabaseAdmin } from "@/lib/supabase/admin";
import type { AdminRoomSummary } from "@/lib/types";

export async function GET(req: Request) {
  return handle(async () => {
    await requireAdmin(req);
    const db = supabaseAdmin();
    const { data: rooms, error } = await db
      .from("rooms")
      .select("id, room_code, room_name, status, has_password, max_players, turn_duration, created_at")
      .order("created_at", { ascending: false });
    if (error) throw toApiError(error);
    const { data: members, error: mErr } = await db.from("room_members").select("room_id").eq("status", "active");
    if (mErr) throw toApiError(mErr);
    const counts = new Map<string, number>();
    for (const m of members ?? []) counts.set(m.room_id, (counts.get(m.room_id) ?? 0) + 1);
    const result: AdminRoomSummary[] = (rooms ?? []).map((r) => ({ ...r, active_members: counts.get(r.id) ?? 0 }));
    return { rooms: result };
  });
}

export async function POST(req: Request) {
  return handle(async () => {
    const user = await requireAdmin(req);
    const body = await readJson(req);
    const usePassword = body.usePassword === true;
    const password = usePassword ? str(body.password) : "";
    if (usePassword && password.length < 4) throw new ApiError(400, "비밀번호는 4자 이상 입력하세요.");
    const created = await rpc<{ id: string; room_code: string }>("admin_create_room", {
      p_user_id: user.id,
      p_room_name: str(body.roomName),
      p_description: str(body.description),
      p_password: password || null,
      p_max_players: int(body.maxPlayers) ?? 10,
      p_turn_duration: int(body.turnDuration) ?? 180,
    });
    return created;
  });
}
