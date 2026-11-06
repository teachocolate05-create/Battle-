// 서버: 방 전체 상태를 권한에 맞게 가져옵니다.
// 전투 상태는 DB 함수 get_room_state (한 번의 질의 = 한 시점의 스냅샷),
// 채팅은 get_room_history 로 따로 가져옵니다. (채팅과 전투 데이터는 분리)
import "server-only";
import { ApiError, rpc } from "./api";
import type { ChatMessage, HistoryPage, RoomState } from "./types";

const ERRORS: Record<string, [number, string]> = {
  not_found: [404, "전투방이 삭제되었거나 존재하지 않습니다."],
  not_member: [403, "이 전투방의 참가자가 아닙니다."],
  kicked: [403, "관리자에 의해 강퇴되었습니다."],
  left: [403, "이미 퇴장한 전투방입니다. 다시 입장하려면 방 코드를 입력하세요."],
};

function check<T extends { error?: string }>(data: T): T {
  if (data.error) {
    const [status, message] = ERRORS[data.error] ?? [500, "상태를 불러오지 못했습니다."];
    throw new ApiError(status, message);
  }
  return data;
}

export async function buildRoomState(roomId: string, userId: string): Promise<RoomState> {
  const [state, chat] = await Promise.all([
    rpc<RoomState & { error?: string }>("get_room_state", { p_user_id: userId, p_room_id: roomId }),
    rpc<HistoryPage<ChatMessage> & { error?: string }>("get_room_history", {
      p_user_id: userId, p_room_id: roomId, p_kind: "chat", p_before: null, p_limit: 200,
    }),
  ]);
  check(state);
  // 채팅 조회가 실패해도(드문 경우) 전투 화면은 보여줌
  const chatOk = !chat.error;
  return { ...state, chat: chatOk ? chat.items : [], chatHasMore: chatOk ? chat.has_more : false };
}

export async function getHistory(roomId: string, userId: string, kind: "chat" | "logs", before: number | null) {
  return check(
    await rpc<HistoryPage<unknown> & { error?: string }>("get_room_history", {
      p_user_id: userId, p_room_id: roomId, p_kind: kind, p_before: before, p_limit: 300,
    }),
  );
}
