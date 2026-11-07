"use client";
// 채팅 탭: 네 종류를 시간순으로, 서로 다른 모양으로 표시
//   ① 일반 참가자 채팅 (이름 = 참가자가 고른 색)  ② 관리자 대사·상황 설명 (본문 회색, 이름은 회색 아님)
//   ③ 전투 시스템 메시지 (적군 등장·전투 시작/종료)  ④ 전투 진행 로그 (행동 선언·판정 결과)
// - 채팅과 전투 로그는 DB 에서 따로 저장되고, 여기서만 함께 보여줌
// - 채팅은 전투 진행과 완전히 독립: 메시지를 보내도 행동 제출로 처리되지 않음
// - 메시지는 항상 "텍스트"로 출력 (HTML 해석 안 함 → 스크립트 삽입 불가)
import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { api, errorMessage } from "@/lib/apiClient";
import type { BattleEvent, BattleLog, ChatMessage, RoomState } from "@/lib/types";
import { formatTime } from "@/components/ui";
import { useOlder, useStickToBottom } from "@/components/BattleLogView";
import { NameTag, useColorizer } from "@/components/Profile";

/** 채팅 탭에 섞어 보여줄 전투 로그 (시스템 메시지와 겹치는 것은 제외) */
const LOG_DUPLICATES_EVENT = new Set(["enemy_appeared", "enemy_withdrawn", "battle_started", "battle_ended"]);

type Row =
  | { kind: "chat"; key: string; at: string; msg: ChatMessage }
  | { kind: "system"; key: string; at: string; ev: BattleEvent }
  | { kind: "log"; key: string; at: string; log: BattleLog };

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
      ...state.logs
        .filter((l) => !LOG_DUPLICATES_EVENT.has(l.log_type) && (!oldest || l.created_at >= oldest))
        .map((l) => ({ kind: "log" as const, key: `l${l.id}`, at: l.created_at, log: l })),
    ];
    // 같은 시각이면 채팅 → 시스템 → 전투 로그 순, 로그끼리는 기록 순서
    const order = { chat: 0, system: 1, log: 2 };
    return r.sort((a, b) => a.at.localeCompare(b.at) || order[a.kind] - order[b.kind] ||
      (a.kind === "log" && b.kind === "log" ? a.log.id - b.log.id : 0));
  }, [chat, state.events, state.logs, hasMore]);
  const colorize = useColorizer(state.players);

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
      <div className="chat-legend small">
        <span className="legend legend-player">참가자</span>
        <span className="legend legend-admin">관리자 진행</span>
        <span className="legend legend-system">시스템</span>
        <span className="legend legend-log">전투 로그</span>
      </div>
      <div className="scroll-box chat-list" style={{ maxHeight: height, minHeight: Math.min(240, height) }} ref={ref} onScroll={onScroll}>
        {hasMore && (
          <button className="btn btn-small btn-ghost" disabled={loadingOlder} onClick={loadMore}>
            {loadingOlder ? "불러오는 중…" : "▲ 이전 메시지 더 보기"}
          </button>
        )}
        {rows.length === 0 && <p className="muted">아직 메시지가 없습니다. 첫 메시지를 보내 보세요.</p>}
        {rows.map((r) => {
          if (r.kind === "chat") {
            const m = r.msg;
            const admin = m.sender_role === "admin";
            return (
              <div key={r.key} className={`chat-msg ${admin ? "chat-kind-admin" : "chat-kind-player"} ${m.is_mine ? "chat-mine" : ""}`}>
                <span className="time">[{formatTime(r.at)}]</span>{" "}
                {admin ? <><NameTag name={m.nickname} admin /> <span className="kind-tag tag-admin">진행</span></>
                  : <NameTag name={m.nickname} color={m.name_color} />}
                :{" "}
                {m.hidden ? (
                  <span className="chat-text chat-hidden">
                    (관리자가 가린 메시지){moderate && m.original ? <> — 원문: <s>{m.original}</s></> : null}
                  </span>
                ) : (
                  <span className={`chat-text ${admin ? "admin-body" : ""}`}>{m.message}</span>
                )}
                {moderate && <HideButton roomId={state.room.id} id={m.id} hidden={Boolean(m.hidden)} onDone={onSent} />}
              </div>
            );
          }
          if (r.kind === "system") {
            return (
              <div key={r.key} className={`system-msg system-${r.ev.event_type}`}>
                <span className="time">[{formatTime(r.at)}]</span> <span className="sys-tag">시스템</span> {r.ev.event_message}
              </div>
            );
          }
          const l = r.log;
          if (l.log_type === "phase_started") {
            return <div key={r.key} className="chat-log-divider">— {l.content} —</div>;
          }
          return (
            <div key={r.key} className={`chat-log chat-log-${l.stage}`}>
              <span className="time">[{formatTime(r.at)}]</span>{" "}
              <span className={`kind-tag tag-${l.stage}`}>{l.stage === "declare" ? "선언" : l.stage === "result" ? "결과" : "전투"}</span>{" "}
              {colorize(l.content)}
            </div>
          );
        })}
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
