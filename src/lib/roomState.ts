// 서버: 방 전체 상태를 권한에 맞게 조립합니다. (판정 전 행동 같은 비공개 데이터는 여기서 절대 내보내지 않음)
import "server-only";
import { supabaseAdmin } from "./supabase/admin";
import { ApiError, toApiError } from "./api";
import type { FullPlayer, Member, PublicPlayer, Room, RoomState } from "./types";

const ROOM_COLUMNS =
  "id, room_code, room_name, description, has_password, status, max_players, turn_duration, first_side, " +
  "current_cycle, current_phase_id, battle_started_at, battle_ended_at, result, end_reason, archive_status, created_at";

const PLAYER_FULL = "id, member_id, display_name, max_hp, current_hp, status, min_attack, max_attack, dodge_rate, escape_rate";

export async function buildRoomState(roomId: string, userId: string, admin: boolean): Promise<RoomState> {
  const db = supabaseAdmin();

  const { data: room, error: roomErr } = await db.from("rooms").select(ROOM_COLUMNS).eq("id", roomId).maybeSingle();
  if (roomErr) throw toApiError(roomErr);
  if (!room) throw new ApiError(404, "전투방이 삭제되었거나 존재하지 않습니다.");

  const { data: members, error: memErr } = await db
    .from("room_members")
    .select("id, room_id, user_id, nickname, role, status, joined_at, left_at")
    .eq("room_id", roomId)
    .order("joined_at");
  if (memErr) throw toApiError(memErr);

  const mine = (members ?? []).find((m) => m.user_id === userId) ?? null;
  if (!admin) {
    if (!mine) throw new ApiError(403, "이 전투방의 참가자가 아닙니다.");
    if (mine.status === "kicked") throw new ApiError(403, "관리자에 의해 강퇴되었습니다.");
    if (mine.status === "left") throw new ApiError(403, "이미 퇴장한 전투방입니다. 다시 입장하려면 방 코드를 입력하세요.");
  }

  const { data: players, error: plErr } = await db.from("players").select(PLAYER_FULL).eq("room_id", roomId);
  if (plErr) throw toApiError(plErr);

  // user_id 는 브라우저로 내보내지 않음
  const strip = (m: NonNullable<typeof members>[number]): Member => {
    const copy: Partial<typeof m> = { ...m };
    delete copy.user_id;
    return copy as unknown as Member;
  };
  const visibleMembers = (members ?? []).filter((m) => admin || m.status === "active").map(strip);
  const visibleMemberIds = new Set(visibleMembers.map((m) => m.id));

  const myPlayer = mine ? ((players ?? []).find((p) => p.member_id === mine.id) as FullPlayer | undefined) : undefined;

  const visiblePlayers = (players ?? [])
    .filter((p) => visibleMemberIds.has(p.member_id))
    .map((p): PublicPlayer | FullPlayer => {
      if (admin || p.id === myPlayer?.id) return p as FullPlayer;
      const { id, member_id, display_name, max_hp, current_hp, status } = p;
      return { id, member_id, display_name, max_hp, current_hp, status } as PublicPlayer;
    });

  return {
    viewer: admin ? "admin" : "guest",
    serverNow: new Date().toISOString(),
    room: room as unknown as Room,
    members: visibleMembers,
    players: visiblePlayers,
    me: mine ? { member: strip(mine), player: myPlayer ?? null } : null,
  };
}
