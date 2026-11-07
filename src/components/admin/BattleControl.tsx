"use client";
// 관리자 전투 제어
//  - BattleStartEnd: 전투 시작(점검표) / 강제 종료 / 결과·기록 저장 상태   (1. 전투방 관리)
//  - BattleProgress: 현재 사이클·단계·타이머, 제출 현황(관리자는 행동 내용까지), 조기 판정 (4. 전투 진행 관리)
//  - QuickBar: 어느 메뉴에서든 보이는 상단 빠른 제어 바
import { useState } from "react";
import { api, errorMessage } from "@/lib/apiClient";
import type { RoomState } from "@/lib/types";
import { ACTION_LABEL, phaseName, PLAYER_STATUS_LABEL } from "@/lib/types";
import { Card, ErrorBox, formatTime } from "@/components/ui";
import { NameTag } from "@/components/Profile";
import { ArchiveStatus, PhaseHeader, ResultBanner, submissionLabel } from "@/components/BattlePanels";

function useBattleCall(roomId: string, onChanged: () => void) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const call = async (path: string, body?: unknown, confirmMsg?: string) => {
    if (confirmMsg && !confirm(confirmMsg)) return;
    setBusy(true);
    setError("");
    try {
      await api(`/api/rooms/${roomId}/battle/${path}`, { method: "POST", body });
      onChanged();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  return { busy, error, call };
}

function participants(state: RoomState) {
  const ids = new Set(state.members.filter((m) => m.status === "active").map((m) => m.id));
  return state.players.filter((p) => ids.has(p.member_id));
}

const EARLY_MSG = "제한 시간이 남아 있지만 지금 행동을 마감할까요? 미제출 플레이어는 행동하지 않은 것으로 처리됩니다.";

/** 지금 조기 마감(조기 판정)이 가능한지 */
function canEarly(state: RoomState) {
  const ph = state.phase;
  return state.room.status === "in_progress" && ph?.status === "open" && ph.acting_side === "players";
}

export function BattleStartEnd({ state, onChanged }: { state: RoomState; onChanged: () => void }) {
  const { busy, error, call } = useBattleCall(state.room.id, onChanged);
  const [reason, setReason] = useState("");
  const { room } = state;
  const alive = participants(state).filter((p) => p.status === "alive");

  if (room.status === "waiting") {
    const checks = [
      { ok: Boolean(room.first_side), text: room.first_side ? `선공 측: ${room.first_side === "players" ? "플레이어" : "적군"}` : "선공 측 미설정 (선공·턴 시간 탭)" },
      { ok: alive.length > 0, text: `참가 플레이어 ${alive.length}명` },
      { ok: state.enemies.length > 0, text: `등록된 적군 ${state.enemies.length}명 (등장 ${state.enemies.filter((e) => e.appearance_status === "appeared").length}명)` },
    ];
    return (
      <Card title="전투 시작">
        <ul className="list">
          {checks.map((c) => <li key={c.text} className="list-item"><span>{c.ok ? "✅" : "❌"} {c.text}</span></li>)}
        </ul>
        <p className="small muted" style={{ margin: "10px 0" }}>
          전투를 시작하면 참가자 프로필과 이름 색상이 확정됩니다. 적군은 전투 중에도 원하는 시점에 등장시킬 수 있습니다.
        </p>
        <ErrorBox>{error}</ErrorBox>
        <button className="btn btn-primary btn-block" disabled={busy || !checks.every((c) => c.ok)}
          onClick={() => call("start", undefined, "전투를 시작할까요? 참가자 프로필이 확정되고, 선공 측과 능력치(HP 제외)를 바꿀 수 없게 됩니다.")}>
          ⚔ 전투 시작
        </button>
      </Card>
    );
  }
  if (room.status === "in_progress") {
    return (
      <Card title="전투 강제 종료">
        <p className="small muted" style={{ marginBottom: 8 }}>남은 단계와 대기 중인 결과 공개는 진행되지 않고, 기록은 자동 저장됩니다.</p>
        <label>
          종료 사유 (기록에 남습니다)
          <input value={reason} maxLength={200} onChange={(e) => setReason(e.target.value)} placeholder="예: 시간 관계상 종료" />
        </label>
        <ErrorBox>{error}</ErrorBox>
        <button className="btn btn-danger" style={{ marginTop: 10 }} disabled={busy}
          onClick={() => call("end", { reason }, "전투를 강제로 종료할까요?")}>
          ⛔ 강제 종료
        </button>
      </Card>
    );
  }
  return (
    <Card title="전투 결과">
      <ResultBanner state={state} />
      <ul className="list" style={{ marginTop: 10 }}>
        {participants(state).map((p) => (
          <li key={p.id} className="list-item">
            <NameTag name={p.display_name} color={p.name_color} />
            <span className={`badge badge-${p.status}`}>{PLAYER_STATUS_LABEL[p.status]} · HP {p.current_hp}/{p.max_hp}</span>
          </li>
        ))}
      </ul>
      <div style={{ marginTop: 12 }}><ArchiveStatus state={state} onChanged={onChanged} /></div>
    </Card>
  );
}

export function BattleProgress({ state, remaining, onChanged }: { state: RoomState; remaining: number | null; onChanged: () => void }) {
  const { busy, error, call } = useBattleCall(state.room.id, onChanged);
  const { room, phase } = state;
  const list = participants(state);
  const alive = list.filter((p) => p.status === "alive");
  const early = canEarly(state);
  const submitted = list.filter((p) => state.submissions.includes(p.id)).length;
  const describe = (playerId: string) => {
    const a = state.adminActions.find((x) => x.player_id === playerId);
    if (!a) return null;
    const target = a.target_id ? state.enemies.find((e) => e.id === a.target_id)?.name : null;
    const item = a.item_id ? state.items.find((i) => i.id === a.item_id)?.name : null;
    return `${ACTION_LABEL[a.action_type]}${item ? ` (${item})` : ""}${target ? ` → ${target}` : ""} · ${formatTime(a.submitted_at)}`;
  };

  return (
    <div className="stack">
      <Card title="전투 진행 상태">
        <PhaseHeader state={state} remaining={remaining} />
        {phase && room.status === "in_progress" && (
          <p className="small muted" style={{ marginTop: 10 }}>
            {room.current_cycle}사이클 {phase.phase_number}단계 · {phaseName(room.first_side, phase.phase_number)} · 행동 측{" "}
            <b>{phase.acting_side === "players" ? "플레이어" : "적군"}</b> · 시작 {formatTime(phase.started_at)}
            {phase.ends_at && ` · 마감 ${formatTime(phase.ends_at)}`}
          </p>
        )}
        <ResultBanner state={state} />
      </Card>
      {room.status === "in_progress" && (
        <Card title={`행동 제출 현황 ${early ? `(${submitted}/${alive.length})` : ""}`}>
          <p className="small muted" style={{ marginBottom: 8 }}>
            관리자는 판정 전에도 각자 제출한 행동을 볼 수 있습니다. 다른 참가자에게는 행동 선언 전까지 공개되지 않습니다.
          </p>
          <ul className="list">
            {list.map((p) => {
              const s = submissionLabel(state, p);
              const d = early ? describe(p.id) : null;
              return (
                <li key={p.id} className="list-item">
                  <div className="grow">
                    <NameTag name={p.display_name} color={p.name_color} /> <span className="small muted">HP {p.current_hp}/{p.max_hp}</span>
                    {d && <div className="small">🔒 {d}</div>}
                  </div>
                  <span className={`badge sub-${s.cls}`}>{s.text}</span>
                </li>
              );
            })}
          </ul>
          <ErrorBox>{error}</ErrorBox>
          <div className="row" style={{ marginTop: 12 }}>
            <button className="btn btn-primary" disabled={busy || !early} onClick={() => call("resolve", undefined, EARLY_MSG)}>⏩ 조기 판정</button>
            {!early && <span className="small muted">조기 판정은 플레이어가 행동을 제출하는 단계에서만 가능합니다.</span>}
          </div>
        </Card>
      )}
    </div>
  );
}

/** 상단 빠른 제어 바: 현재 단계·남은 시간·제출 수 + 조기 판정 / 메뉴 바로가기 */
export function QuickBar({ state, remaining, onChanged, goto }: {
  state: RoomState; remaining: number | null; onChanged: () => void; goto: (menu: string, sub?: string) => void;
}) {
  const { busy, error, call } = useBattleCall(state.room.id, onChanged);
  const { room, phase } = state;
  const early = canEarly(state);
  const list = participants(state);
  const submitted = list.filter((p) => state.submissions.includes(p.id)).length;
  const alive = list.filter((p) => p.status === "alive").length;
  const mmss = (s: number | null) => (s === null ? "--:--" : `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`);
  let status = "";
  if (room.status === "waiting") status = "⏸ 전투 대기 중";
  else if (room.status === "ended") status = "🏁 전투 종료";
  else if (phase) status = `${room.current_cycle}사이클 ${phase.phase_number}단계 · ${phaseName(room.first_side, phase.phase_number)}`;
  return (
    <div className="quickbar">
      <div className="quickbar-status">
        <b>{status}</b>
        {early && <span className="badge sub-pending">⏱ {mmss(remaining)} · 제출 {submitted}/{alive}</span>}
        {room.status === "in_progress" && phase?.status === "declared" && <span className="badge sub-submitted">⏳ 결과 공개까지 {remaining ?? 5}초</span>}
      </div>
      <div className="row">
        {room.status === "waiting" && <button className="btn btn-small btn-primary" onClick={() => goto("room", "battle")}>⚔ 전투 시작하러 가기</button>}
        {room.status === "in_progress" && (
          <>
            <button className="btn btn-small btn-primary" disabled={busy || !early} onClick={() => call("resolve", undefined, EARLY_MSG)}>⏩ 조기 판정</button>
            <button className="btn btn-small" onClick={() => goto("progress", "control")}>제출 현황</button>
            <button className="btn btn-small btn-danger" onClick={() => goto("room", "battle")}>강제 종료</button>
          </>
        )}
      </div>
      {error && <div className="small" style={{ color: "var(--danger)", width: "100%" }}>{error}</div>}
    </div>
  );
}
