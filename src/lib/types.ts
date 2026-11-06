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

export type EnemyTargetType = "all" | "random" | "specific";

export interface Enemy {
  id: string;
  name: string;
  description: string;
  max_hp: number;
  current_hp: number;
  min_attack: number;
  max_attack: number;
  dodge_rate: number;
  defense: number;
  target_type: EnemyTargetType;
  target_player_id: string | null;
  appearance_message: string;
  appearance_status: "registered" | "appeared";
  appearance_order: number | null;
  appeared_at: string | null;
  status: "alive" | "dead";
  created_at: string;
}

export type ItemType = "heal" | "damage";

export interface Item {
  id: string;
  name: string;
  description: string;
  item_type: ItemType;
  effect_value: number;
}

export interface InventoryEntry {
  player_id: string;
  item_id: string;
  quantity: number;
}

/** 시스템 이벤트 (적군 등장, 전투 시작/종료 등) */
export interface BattleEvent {
  id: number;
  enemy_id: string | null;
  event_type: string;
  event_message: string;
  event_data: Record<string, unknown>;
  created_at: string;
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
  /** 관리자: 모든 적군 / 게스트: 등장한 적군만 (서버에서 걸러짐) */
  enemies: Enemy[];
  items: Item[];
  /** 관리자: 모든 플레이어 / 게스트: 본인 것만 */
  inventory: InventoryEntry[];
  events: BattleEvent[];
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

export const ENEMY_TARGET_LABEL: Record<EnemyTargetType, string> = {
  all: "생존한 모든 플레이어",
  random: "무작위 1명",
  specific: "특정 플레이어",
};

export const ITEM_TYPE_LABEL: Record<ItemType, string> = {
  heal: "HP 회복",
  damage: "적군 고정 피해",
};

export function enemyStateLabel(e: Pick<Enemy, "appearance_status" | "status">) {
  if (e.status === "dead") return "사망";
  return e.appearance_status === "appeared" ? "등장함" : "등록됨";
}
