// 서버: 방 전체 상태를 권한에 맞게 가져옵니다.
// 실제 조립은 DB 함수 get_room_state (005_room_state.sql) 가 한 번의 질의로 처리합니다.
//  - 한 시점의 스냅샷이라 진행 중 상태가 섞이지 않음
//  - 판정 전 행동은 본인 것만, 미등장 적군은 관리자만 (DB 함수에서 걸러짐)
import "server-only";
import { ApiError, rpc } from "./api";
import type { RoomState } from "./types";

const ERRORS: Record<string, [number, string]> = {
  not_found: [404, "전투방이 삭제되었거나 존재하지 않습니다."],
  not_member: [403, "이 전투방의 참가자가 아닙니다."],
  kicked: [403, "관리자에 의해 강퇴되었습니다."],
  left: [403, "이미 퇴장한 전투방입니다. 다시 입장하려면 방 코드를 입력하세요."],
};

export async function buildRoomState(roomId: string, userId: string): Promise<RoomState> {
  const data = await rpc<RoomState & { error?: string }>("get_room_state", { p_user_id: userId, p_room_id: roomId });
  if (data.error) {
    const [status, message] = ERRORS[data.error] ?? [500, "상태를 불러오지 못했습니다."];
    throw new ApiError(status, message);
  }
  return data;
}
