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
  /** 관리자가 정한 추가 프로필 항목 */
  profile_fields: ProfileField[];
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
  /** 이름 색상 (#rrggbb) — 채팅·로그·목록 등 이름이 나오는 모든 곳에 사용 */
  name_color: string;
  bio: string;
  appearance: string;
  /** 관리자가 정한 추가 항목 값 { 항목키: 값 } */
  profile_extra: Record<string, string>;
  /** 전투 시작 시 프로필 확정 시각 (이후 본인 수정 불가) */
  profile_locked_at: string | null;
}

export interface ProfileField {
  key: string;
  label: string;
}

export interface ProfileHistoryEntry {
  id: number;
  player_id: string;
  changed_by: "player" | "admin";
  changes: Record<string, { before: unknown; after: unknown }>;
  created_at: string;
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

export type Side = "players" | "enemies";

export interface BattlePhase {
  id: string;
  cycle_number: number;
  phase_number: number;
  phase_type: "turn" | "reaction";
  acting_side: Side;
  response_to_phase_id: string | null;
  started_at: string;
  ends_at: string | null;
  resolved_at: string | null;
  status: "open" | "resolved" | "aborted";
}

export type ActionType = "attack" | "dodge" | "item" | "escape";

/** 본인이 제출한 행동 (다른 사람 것은 서버가 절대 보내지 않음) */
export interface MyAction {
  action_type: ActionType;
  target_id: string | null;
  item_id: string | null;
  submitted_at: string;
  status: "submitted" | "resolved" | "invalid";
}

/** 관리자만 보는 판정 전 행동 */
export interface AdminAction {
  player_id: string;
  action_type: ActionType;
  target_id: string | null;
  item_id: string | null;
  submitted_at: string;
}

/** 적군 턴에 선언되어 다음 플레이어 반응턴에 적용될 공격 (공개 정보) */
export interface PendingAttack {
  id: string;
  enemy_id: string;
  target_player_id: string;
  attack_power: number;
}

export interface BattleLog {
  id: number;
  cycle_number: number | null;
  phase_number: number | null;
  phase_id: string | null;
  actor_type: string | null;
  actor_id: string | null;
  target_type: string | null;
  target_id: string | null;
  log_type: string;
  content: string;
  data: Record<string, unknown>;
  created_at: string;
}

export interface ChatMessage {
  id: number;
  sender_role: "guest" | "admin";
  nickname: string;
  message: string;
  created_at: string;
  /** 내가 보낸 메시지인지 (보낸 사람 ID는 서버가 보내지 않음) */
  is_mine: boolean;
}

export interface HistoryPage<T> {
  items: T[];
  has_more: boolean;
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
  /** 현재 단계 (전투 전이면 null) */
  phase: BattlePhase | null;
  /** 현재 단계에 행동을 제출한 플레이어 ID (행동 종류 없음) */
  submissions: string[];
  /** 현재 단계 내 행동 (게스트 본인만) */
  myAction: MyAction | null;
  /** 지금 반응해야 할, 선언된 적군 공격 */
  pendingAttacks: PendingAttack[];
  logs: BattleLog[];
  /** 관리자 전용: 판정 전 제출된 행동 목록 */
  adminActions: AdminAction[];
  /** 관리자 전용: 프로필 수정 내역 */
  profileHistory: ProfileHistoryEntry[];
  /** 최근 채팅 (전투 데이터와 별도 테이블·별도 조회) */
  chat: ChatMessage[];
  chatHasMore: boolean;
}

export const ACTION_LABEL: Record<ActionType, string> = {
  attack: "일반 공격",
  dodge: "회피",
  item: "아이템 사용",
  escape: "도망",
};

export const RESULT_LABEL: Record<string, string> = {
  victory: "🏆 승리",
  defeat: "💀 패배",
  all_escaped: "🏃 전원 도주",
  forced: "⛔ 강제 종료",
};

export function phaseName(first: Side | null, n: number) {
  const p = ["플레이어 선공턴", "적군 반응턴", "적군 후공턴", "플레이어 반응턴"];
  const e = ["적군 선공턴", "플레이어 반응턴", "플레이어 후공턴", "적군 반응턴"];
  return (first === "enemies" ? e : p)[n - 1] ?? "";
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

// ===== 7단계: 전투 기록 보관함 =====
export interface ArchiveSummary {
  id: string;
  room_id: string;
  room_name_snapshot: string;
  started_at: string | null;
  ended_at: string | null;
  result: string;
  first_side: Side | null;
  created_at: string;
  total_cycles: number;
  duration_seconds: number;
  player_count: number;
}

export interface ArchivePlayer {
  nickname: string;
  display_name: string;
  member_status: string;
  final_hp: number;
  max_hp: number;
  status: PlayerStatus;
  damage_dealt: number;
  damage_taken: number;
  items_used: { item_name: string; item_type: ItemType; count: number }[];
  items_left: { item_name: string; quantity: number }[];
}

export interface ArchiveEnemy {
  name: string;
  description: string;
  appeared: boolean;
  appeared_at: string | null;
  appearance_order: number | null;
  appearance_message: string;
  final_hp: number;
  max_hp: number;
  dead: boolean;
}

export interface ArchiveData {
  room: {
    room_name: string;
    description: string;
    room_code: string;
    first_side: Side | null;
    turn_duration: number;
    started_at: string | null;
    ended_at: string | null;
    duration_seconds: number;
    result: string;
    end_reason: string | null;
    total_cycles: number;
    total_phases: number;
  };
  players: ArchivePlayer[];
  enemies: ArchiveEnemy[];
  items: { name: string; description: string; item_type: ItemType; effect_value: number }[];
  phases: { cycle_number: number; phase_number: number; started_at: string; resolved_at: string | null; status: string }[];
  logs: BattleLog[];
  events: BattleEvent[];
  chat: Omit<ChatMessage, "is_mine">[];
}

export interface ArchiveDetail {
  id: string;
  room_name_snapshot: string;
  result: string;
  created_at: string;
  archive_data: ArchiveData;
}

/** 이름 색상 기본 목록 (DB 의 name_color_palette 와 같음) */
export const NAME_COLOR_PALETTE = [
  "#ff8a80", "#ffb74d", "#ffd54f", "#dce775", "#81c784", "#4dd0e1",
  "#64b5f6", "#9fa8da", "#ce93d8", "#f48fb1", "#bcaaa4", "#e0e0e0",
];

function luminance(hex: string) {
  return [0, 1, 2]
    .map((i) => parseInt(hex.slice(1 + i * 2, 3 + i * 2), 16) / 255)
    .map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4))
    .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
}

/** 어두운 카드 배경(#222838) 위에서 읽을 수 있는 색인지 (서버와 같은 기준: 명암비 4.5 이상) */
export function isReadableNameColor(hex: string) {
  if (!/^#[0-9a-f]{6}$/i.test(hex)) return false;
  return (luminance(hex.toLowerCase()) + 0.05) / (luminance("#222838") + 0.05) >= 4.5;
}

export const PROFILE_FIELD_LABEL: Record<string, string> = {
  display_name: "캐릭터 이름",
  bio: "캐릭터 소개",
  appearance: "외형 설명",
  name_color: "이름 색상",
  profile_extra: "추가 항목",
};
