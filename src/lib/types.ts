// 서버와 브라우저가 함께 쓰는 타입 정의

export type RoomStatus = "waiting" | "in_progress" | "ended";
export type MemberStatus = "active" | "left" | "kicked";
export type PlayerStatus = "alive" | "dead" | "escaped";

export interface Room {
  id: string;
  room_code: string;
  room_name: string;
  description: string;
  has_password: boolean;
  status: RoomStatus;
  max_players: number;
  turn_duration: number;
  first_side: "players" | "enemies" | null;
  current_cycle: number;
  current_phase_id: string | null;
  battle_started_at: string | null;
  battle_ended_at: string | null;
  result: string | null;
  end_reason: string | null;
  archive_status: "none" | "pending" | "saved" | "failed";
  created_at: string;
}

export interface Member {
  id: string;
  room_id: string;
  nickname: string;
  role: "guest";
  status: MemberStatus;
  joined_at: string;
  left_at: string | null;
}

/** 다른 참가자에게 공개되는 플레이어 정보 */
export interface PublicPlayer {
  id: string;
  member_id: string;
  display_name: string;
  max_hp: number;
  current_hp: number;
  status: PlayerStatus;
}

/** 본인 또는 관리자에게만 보이는 전체 능력치 */
export interface FullPlayer extends PublicPlayer {
  min_attack: number;
  max_attack: number;
  dodge_rate: number;
  escape_rate: number;
}

/** GET /api/rooms/[roomId]/state 응답 */
export interface RoomState {
  viewer: "admin" | "guest";
  serverNow: string;
  room: Room;
  /** 관리자: 모든 참가 기록 / 게스트: 활성 참가자만 */
  members: Member[];
  /** 관리자: 전체 능력치 / 게스트: 본인만 전체, 나머지는 공개 정보 */
  players: (PublicPlayer | FullPlayer)[];
  me: { member: Member; player: FullPlayer | null } | null;
}

export interface AdminRoomSummary {
  id: string;
  room_code: string;
  room_name: string;
  status: RoomStatus;
  has_password: boolean;
  max_players: number;
  turn_duration: number;
  created_at: string;
  active_members: number;
}

export interface MeResponse {
  userId: string;
  isAdmin: boolean;
  rooms: { room_id: string; room_name: string; room_code: string; status: RoomStatus; nickname: string }[];
}

export const ROOM_STATUS_LABEL: Record<RoomStatus, string> = {
  waiting: "대기 중",
  in_progress: "전투 진행 중",
  ended: "전투 종료",
};

export const PLAYER_STATUS_LABEL: Record<PlayerStatus, string> = {
  alive: "생존",
  dead: "사망",
  escaped: "도주",
};

export const MEMBER_STATUS_LABEL: Record<MemberStatus, string> = {
  active: "참가 중",
  left: "퇴장",
  kicked: "강퇴",
};

export const TURN_DURATIONS = [180, 300, 420] as const;
