"use client";
// 6단계: 채팅 (일반 채팅 + 시스템 메시지를 시간순으로 함께 표시)
// - 채팅은 전투 진행과 완전히 독립: 메시지를 보내도 행동 제출로 처리되지 않음
// - 메시지는 항상 "텍스트"로 출력 (HTML 해석 안 함 → 스크립트 삽입 불가)
import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { api, errorMessage } from "@/lib/apiClient";
import type { BattleEvent, ChatMessage, RoomState } from "@/lib/types";
import { formatTime } from "@/components/ui";
import { useOlder, useStickToBottom } from "@/components/BattleLogView";

type Row =
  | { kind: "chat"; key: string; at: string; msg: ChatMessage }
  | { kind: "system"; key: string; at: string; ev: BattleEvent };

export function ChatPanel({ state, onSent, height = 420, moderate = false }: {
  state: RoomState; onSent: () => void; height?: number;
  /** 관리자 채팅 관리: 메시지 가리기/해제 버튼 표시 */
  moderate?: boolean;
}) {
  const { all: chat, hasMore, loadMore, busy: loadingOlder } = useOlder<ChatMessage>(state.room.id, "chat", state.chat, state.chatHasMore);
  const [text, setText] = useState("");
  const [error, setError] = useState("");
  const readOnly = state.room.status === "ended";

  const rows = useMemo<Row[]>(() => {
    // 불러온 채팅 범위보다 오래된 시스템 메시지는 "더 보기" 전까지 숨김 (시간 순서가 어긋나지 않게)
    const oldest = hasMore && chat.length ? chat[0].created_at : null;
    const r: Row[] = [
      ...chat.map((m) => ({ kind: "chat" as const, key: `c${m.id}`, at: m.created_at, msg: m })),
      ...state.events
        .filter((e) => !oldest || e.created_at >= oldest)
        .map((e) => ({ kind: "system" as const, key: `e${e.id}`, at: e.created_at, ev: e })),
    ];
    return r.sort((a, b) => a.at.localeCompare(b.at));
  }, [chat, state.events, hasMore]);

  const { ref, onScroll } = useStickToBottom(rows.length);

  // 보낸 메시지는 입력창에서 바로 지우고 "보내는 중" 목록에 넣은 뒤 순서대로 하나씩 전송
  // (빠르게 연달아 Enter 를 눌러도 메시지가 사라지지 않음)
  const queue = useRef<string[]>([]);
  const running = useRef(false);
  const [pending, setPending] = useState<string[]>([]);

  const flush = async () => {
    if (running.current) return;
    running.current = true;
    while (queue.current.length) {
      const msg = queue.current[0];
      try {
        await api(`/api/rooms/${state.room.id}/chat`, { method: "POST", body: { message: msg } });
        onSent();
      } catch (err) {
        setError(errorMessage(err));
        // 실패한 메시지는 입력창으로 되돌려 다시 보낼 수 있게 (나머지 대기 메시지는 취소)
        setText((t) => (t ? t : msg));
        queue.current = [];
        break;
      }
      queue.current.shift();
      setPending([...queue.current]);
    }
    setPending([]);
    running.current = false;
  };

  const send = (e?: FormEvent) => {
    e?.preventDefault();
    const msg = text.trim();
    if (!msg) return;
    setError("");
    setText("");
    queue.current.push(msg);
    setPending([...queue.current]);
    void flush();
  };

  return (
    <div className="chat">
      <div className="scroll-box chat-list" style={{ maxHeight: height, minHeight: Math.min(240, height) }} ref={ref} onScroll={onScroll}>
        {hasMore && (
          <button className="btn btn-small btn-ghost" disabled={loadingOlder} onClick={loadMore}>
            {loadingOlder ? "불러오는 중…" : "▲ 이전 메시지 더 보기"}
          </button>
        )}
        {rows.length === 0 && <p className="muted">아직 메시지가 없습니다. 첫 메시지를 보내 보세요.</p>}
        {rows.map((r) =>
          r.kind === "chat" ? (
            <div key={r.key} className={`chat-msg ${r.msg.is_mine ? "chat-mine" : ""} ${r.msg.sender_role === "admin" ? "chat-admin" : ""}`}>
              <span className="time">[{formatTime(r.at)}]</span>{" "}
              <b className="chat-nick">{r.msg.nickname}{r.msg.sender_role === "admin" ? " 👑" : ""}</b>:{" "}
              {r.msg.hidden ? (
                <span className="chat-text chat-hidden">
                  (관리자가 가린 메시지){moderate && r.msg.original ? <> — 원문: <s>{r.msg.original}</s></> : null}
                </span>
              ) : (
                <span className="chat-text">{r.msg.message}</span>
              )}
              {moderate && <HideButton roomId={state.room.id} id={r.msg.id} hidden={Boolean(r.msg.hidden)} onDone={onSent} />}
            </div>
          ) : (
            <div key={r.key} className={`system-msg system-${r.ev.event_type}`}>
              <span className="time">[{formatTime(r.at)}]</span> <span className="sys-tag">시스템</span> {r.ev.event_message}
            </div>
          ),
        )}
        {pending.map((m, i) => (
          <div key={`p${i}`} className="chat-msg chat-mine chat-pending">
            <span className="time">[보내는 중]</span> <span className="chat-text">{m}</span>
          </div>
        ))}
      </div>
      {readOnly ? (
        <p className="small muted chat-readonly">전투가 종료되어 채팅은 읽기 전용입니다.</p>
      ) : (
        <form className="chat-input" onSubmit={send}>
          <input
            value={text}
            maxLength={300}
            onChange={(e) => setText(e.target.value)}
            placeholder={state.viewer === "admin" ? "스토리를 진행하세요… (Enter 전송)" : "메시지 입력 (Enter 전송)"}
            aria-label="채팅 메시지"
            enterKeyHint="send"
          />
          <button className="btn btn-primary" disabled={!text.trim()}>전송</button>
        </form>
      )}
      <div className="row between small muted" style={{ marginTop: 4 }}>
        <span style={{ color: error ? "var(--danger)" : undefined }}>{error || "채팅은 전투 행동과 무관합니다."}</span>
        {!readOnly && <span>{text.length}/300</span>}
      </div>
    </div>
  );
}

/** 탭이 채팅이 아닐 때 새로 온 메시지 수 (채팅 탭을 보고 있으면 0, 마지막으로 본 메시지 이후만 셈) */
export function useUnread(state: RoomState | null, chatActive: boolean) {
  const lastChat = state?.chat.at(-1)?.id ?? 0;
  const lastEvent = state?.events.at(-1)?.id ?? 0;
  const [seen, setSeen] = useState<{ chat: number; event: number } | null>(null);
  useEffect(() => {
    if (!state) return;
    if (seen === null || chatActive) {
      if (seen?.chat !== lastChat || seen?.event !== lastEvent) setSeen({ chat: lastChat, event: lastEvent });
    }
  }, [state, chatActive, lastChat, lastEvent, seen]);
  if (!state || !seen || chatActive) return 0;
  return (
    state.chat.filter((m) => m.id > seen.chat && !m.is_mine).length +
    state.events.filter((e) => e.id > seen.event).length
  );
}

/** 관리자: 메시지 가리기 / 해제 */
function HideButton({ roomId, id, hidden, onDone }: { roomId: string; id: number; hidden: boolean; onDone: () => void }) {
  const [busy, setBusy] = useState(false);
  const toggle = async () => {
    if (!hidden && !confirm("이 메시지를 가릴까요? 참가자에게는 '(관리자가 가린 메시지)'로 보이고, 원문은 관리자만 볼 수 있습니다.")) return;
    setBusy(true);
    try {
      await api(`/api/rooms/${roomId}/chat/${id}/hide`, { method: "POST", body: { hide: !hidden } });
      onDone();
    } catch (e) {
      alert(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <button className="btn btn-small btn-ghost chat-mod" disabled={busy} onClick={toggle}>
      {hidden ? "해제" : "가리기"}
    </button>
  );
}
