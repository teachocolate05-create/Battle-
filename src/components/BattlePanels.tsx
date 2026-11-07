"use client";
// 4단계 전투 화면 조각: 진행 상태/타이머, 행동 선택, 제출 현황, 선언된 공격, 전투 로그, 결과, 관리자 진행 제어
import { useEffect, useRef, useState } from "react";
import { api, errorMessage } from "@/lib/apiClient";
import type { ActionType, FullPlayer, PublicPlayer, RoomState } from "@/lib/types";
import { ACTION_LABEL, ITEM_TYPE_LABEL, phaseName, RESULT_LABEL } from "@/lib/types";
import { Card, ErrorBox, formatTime, HpBar } from "@/components/ui";
import { NameTag, ProfileView } from "@/components/Profile";

// ---------------------------------------------------------------------
// 타이머 (서버 시각 기준) + 0초가 되면 서버에 판정 요청
// ---------------------------------------------------------------------
export function useRemaining(endsAt: string | null | undefined, clockOffset: number) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 500);
    return () => clearInterval(t);
  }, []);
  if (!endsAt) return null;
  return Math.max(0, Math.ceil((new Date(endsAt).getTime() - (now + clockOffset)) / 1000));
}

/**
 * 제한 시간이 끝났는데 아직 단계가 열려 있으면 서버에 확인 요청.
 * 실제 판정 여부는 서버가 DB 시각으로 결정 (브라우저 시계를 믿지 않음). pg_cron 이 5초마다 같은 일을 하는 보조 수단.
 */
export function useAutoTick(state: RoomState | null, remaining: number | null, refresh: () => void) {
  const last = useRef(0);
  const phase = state?.phase;
  const due =
    state?.room.status === "in_progress" &&
    ((phase?.status === "open" && (phase.acting_side === "enemies" || remaining === 0)) ||
      (phase?.status === "declared" && remaining === 0));
  useEffect(() => {
    if (!due || !state) return;
    const fire = () => {
      if (Date.now() - last.current < 1500) return;
      last.current = Date.now();
      api(`/api/rooms/${state.room.id}/battle/tick`, { method: "POST" })
        .catch(() => {})
        .finally(refresh);
    };
    fire();
    const t = setInterval(fire, 2000);
    return () => clearInterval(t);
  }, [due, state, refresh]);
}

function mmss(sec: number | null) {
  if (sec === null) return "--:--";
  return `${String(Math.floor(sec / 60)).padStart(2, "0")}:${String(sec % 60).padStart(2, "0")}`;
}

// ---------------------------------------------------------------------
// 상단 진행 상태
// ---------------------------------------------------------------------
/** 지금 기다리는 시각: 행동 제출 마감(open) 또는 결과 공개(declared) */
export function phaseTarget(state: RoomState | null) {
  const ph = state?.phase;
  if (!ph || state?.room.status !== "in_progress") return null;
  if (ph.status === "open") return ph.ends_at;
  if (ph.status === "declared") return ph.reveal_at;
  return null;
}

export function PhaseHeader({ state, remaining }: { state: RoomState; remaining: number | null }) {
  const { room, phase } = state;
  const alivePlayers = state.players.filter((p) => p.status === "alive").length;
  const aliveEnemies = state.enemies.filter((e) => e.appearance_status === "appeared" && e.status === "alive").length;
  const waiting = room.status === "waiting";
  const ended = room.status === "ended";
  const playersTurn = phase?.status === "open" && phase.acting_side === "players";
  const revealing = room.status === "in_progress" && phase?.status === "declared";
  const urgent = playersTurn && remaining !== null && remaining <= 30;
  return (
    <div className="battle-header">
      <div className="stat"><span>사이클</span><b>{waiting ? "-" : room.current_cycle}</b></div>
      <div className="stat">
        <span>현재 단계</span>
        <b>
          {waiting ? "전투 대기 중" : ended ? "전투 종료" : phase ? `${phase.phase_number}단계 · ${phaseName(room.first_side, phase.phase_number)}` : "-"}
        </b>
      </div>
      <div className={`stat timer ${urgent ? "timer-urgent" : ""} ${revealing ? "timer-reveal" : ""}`}>
        <span>{playersTurn ? "남은 시간 (플레이어 행동)" : revealing ? "⏳ 결과 공개까지" : ended || waiting ? "남은 시간" : "적군 행동 중"}</span>
        <b>{playersTurn ? mmss(remaining) : revealing ? `${remaining ?? 5}초` : "--:--"}</b>
      </div>
      <div className="stat">
        <span>생존 플레이어 / 적군</span>
        <b>{alivePlayers}명 / {aliveEnemies}</b>
      </div>
    </div>
  );
}

export function ResultBanner({ state }: { state: RoomState }) {
  const { room } = state;
  if (room.status !== "ended" || !room.result) return null;
  return (
    <div className={`result-banner result-${room.result}`}>
      <b>{RESULT_LABEL[room.result] ?? room.result}</b>
      <span>
        {room.current_cycle}사이클에서 전투 종료
        {room.end_reason ? ` · 사유: ${room.end_reason}` : ""}
      </span>
    </div>
  );
}

// ---------------------------------------------------------------------
// 제출 현황: 제출 완료 / 대기 중 / 사망 / 도주 (행동 종류는 표시하지 않음)
// ---------------------------------------------------------------------
export function submissionLabel(state: RoomState, p: PublicPlayer): { text: string; cls: string } {
  if (p.status === "dead") return { text: "사망", cls: "dead" };
  if (p.status === "escaped") return { text: "도주", cls: "escaped" };
  const playersTurn = state.room.status === "in_progress" && state.phase?.status === "open" && state.phase.acting_side === "players";
  if (!playersTurn) return { text: "생존", cls: "alive" };
  return state.submissions.includes(p.id) ? { text: "행동 제출 완료", cls: "submitted" } : { text: "행동 대기 중", cls: "pending" };
}

export function PlayerList({ state }: { state: RoomState }) {
  const meId = state.me?.player?.id;
  return (
    <Card title={`플레이어 (${state.players.length}명)`}>
      <ul className="list">
        {state.players.map((p) => {
          const s = submissionLabel(state, p);
          return (
            <li key={p.id} className="list-item" style={{ display: "block" }}>
              <div className="row">
                <NameTag name={p.display_name} color={p.name_color} />
                {p.id === meId && <span className="badge">나</span>}
                <span className={`badge sub-${s.cls}`}>{s.text}</span>
              </div>
              <div style={{ marginTop: 6 }}>
                <HpBar current={p.current_hp} max={p.max_hp} compact />
              </div>
              <details className="small" style={{ marginTop: 4 }}>
                <summary className="muted">프로필 보기</summary>
                <ProfileView player={p} fields={state.room.profile_fields ?? []} />
              </details>
            </li>
          );
        })}
      </ul>
    </Card>
  );
}

// ---------------------------------------------------------------------
// 지금 반응해야 할 적군 공격 (적군 턴에 선언된 공격)
// ---------------------------------------------------------------------
export function IncomingAttacks({ state }: { state: RoomState }) {
  if (state.pendingAttacks.length === 0) return null;
  const meId = state.me?.player?.id;
  return (
    <Card title="⚠ 다가오는 적군의 공격">
      <p className="small muted" style={{ marginBottom: 8 }}>
        이번 반응턴이 끝나고 결과가 공개될 때 적용됩니다. 공격력은 결과 공개 때 정해집니다.
        <b>회피</b>를 고르면 회피 판정을, <b>도망</b>에 성공하면 공격을 피할 수 있습니다.
      </p>
      <ul className="list">
        {state.pendingAttacks.map((a) => {
          const enemy = state.enemies.find((e) => e.id === a.enemy_id);
          const target = state.players.find((p) => p.id === a.target_player_id);
          return (
            <li key={a.id} className={`list-item ${a.target_player_id === meId ? "incoming-me" : ""}`}>
              <span>
                <b>{enemy?.name ?? "?"}</b> → <b>{target?.display_name ?? "?"}</b>
                {a.target_player_id === meId && <span className="badge sub-dead" style={{ marginLeft: 6 }}>나를 노림</span>}
              </span>
              <span className="badge">공격 예고</span>
            </li>
          );
        })}
      </ul>
    </Card>
  );
}

/** 지금 내가 행동을 제출해야 하는 상황인지 (채팅 탭에도 행동 패널을 띄우기 위해 사용) */
export function needsMyAction(state: RoomState, remaining: number | null) {
  const me = state.me?.player;
  return Boolean(
    state.viewer === "guest" && me && me.status === "alive" && !state.myAction &&
      state.room.status === "in_progress" && state.phase?.status === "open" &&
      state.phase.acting_side === "players" && remaining !== 0,
  );
}

// ---------------------------------------------------------------------
// 행동 선택 / 제출
// ---------------------------------------------------------------------
export function ActionPanel({ state, remaining, onDone }: { state: RoomState; remaining: number | null; onDone: () => void }) {
  const me = state.me?.player as FullPlayer | null | undefined;
  const [type, setType] = useState<ActionType | null>(null);
  const [target, setTarget] = useState("");
  const [itemId, setItemId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const phaseId = state.phase?.id;

  // 단계가 바뀌면 선택 초기화
  useEffect(() => {
    setType(null);
    setTarget("");
    setItemId("");
    setError("");
  }, [phaseId]);

  if (!me) return null;
  const enemies = state.enemies.filter((e) => e.appearance_status === "appeared" && e.status === "alive");
  const owned = state.inventory
    .filter((i) => i.player_id === me.id && i.quantity > 0)
    .map((i) => ({ ...i, item: state.items.find((it) => it.id === i.item_id) }))
    .filter((i) => i.item);
  const selectedItem = state.items.find((i) => i.id === itemId);
  const needsTarget = type === "attack" || (type === "item" && selectedItem?.item_type === "damage");

  const playersTurn = state.room.status === "in_progress" && state.phase?.status === "open" && state.phase.acting_side === "players";
  let disabledReason = "";
  if (state.room.status === "waiting") disabledReason = "전투가 시작되면 행동할 수 있습니다.";
  else if (state.room.status === "ended") disabledReason = "전투가 종료되었습니다.";
  else if (me.status === "dead") disabledReason = "쓰러져서 행동할 수 없습니다.";
  else if (me.status === "escaped") disabledReason = "전투에서 이탈했습니다.";
  else if (state.phase?.status === "declared") disabledReason = "행동 선언이 공개되었습니다. 잠시 후 판정 결과가 공개됩니다.";
  else if (!playersTurn) disabledReason = "적군이 행동하는 단계입니다. 잠시 기다리세요.";
  else if (remaining === 0) disabledReason = "제한 시간이 끝났습니다. 판정을 기다리는 중…";
  else if (state.myAction) disabledReason = "이번 단계 행동을 제출했습니다. 제한 시간이 끝나면 행동이 공개되고, 5초 뒤 결과가 공개됩니다.";
  const canAct = !disabledReason;

  const submit = async () => {
    if (!type) return;
    setBusy(true);
    setError("");
    try {
      await api(`/api/rooms/${state.room.id}/actions`, {
        method: "POST",
        body: { action_type: type, target_id: needsTarget ? target : "", item_id: type === "item" ? itemId : "" },
      });
      onDone();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const ready = type && (!needsTarget || target) && (type !== "item" || itemId);
  const my = state.myAction;
  const myText = my
    ? `${ACTION_LABEL[my.action_type]}${my.target_id ? ` → ${state.enemies.find((e) => e.id === my.target_id)?.name ?? ""}` : ""}${
        my.item_id ? ` (${state.items.find((i) => i.id === my.item_id)?.name ?? ""})` : ""}`
    : "";

  return (
    <Card title="행동 선택">
      {my && (
        <div className="alert alert-ok" style={{ marginBottom: 10 }}>
          ✅ 제출한 행동: <b>{myText}</b> <span className="small">({formatTime(my.submitted_at)}) · 다른 참가자에게는 판정 전까지 공개되지 않습니다.</span>
        </div>
      )}
      <div className="action-grid">
        {(["attack", "dodge", "item", "escape"] as ActionType[]).map((t) => (
          <button
            key={t}
            className={`btn action-btn action-${t} ${type === t ? "action-on" : ""}`}
            disabled={!canAct || (t === "attack" && enemies.length === 0) || (t === "item" && owned.length === 0)}
            onClick={() => { setType(t); setTarget(""); setItemId(""); }}
          >
            {ACTION_LABEL[t]}
          </button>
        ))}
      </div>

      {canAct && type === "item" && (
        <label style={{ marginTop: 10 }}>
          사용할 아이템
          <select value={itemId} onChange={(e) => { setItemId(e.target.value); setTarget(""); }}>
            <option value="">선택하세요</option>
            {owned.map((o) => (
              <option key={o.item_id} value={o.item_id}>
                {o.item!.name} ×{o.quantity} ({ITEM_TYPE_LABEL[o.item!.item_type]} {o.item!.effect_value})
              </option>
            ))}
          </select>
        </label>
      )}
      {canAct && needsTarget && (
        <div style={{ marginTop: 10 }}>
          <div className="small muted" style={{ marginBottom: 6 }}>대상 적군</div>
          <div className="target-grid">
            {enemies.map((e) => (
              <button key={e.id} className={`btn target-btn ${target === e.id ? "action-on" : ""}`} onClick={() => setTarget(e.id)}>
                {e.name} <span className="small muted">HP {e.current_hp}/{e.max_hp}</span>
              </button>
            ))}
          </div>
        </div>
      )}
      {canAct && type && (
        <p className="small muted" style={{ marginTop: 8 }}>
          {type === "attack" && `공격력 ${me.min_attack}~${me.max_attack} 무작위. 적군의 회피·방어력이 적용됩니다.`}
          {type === "dodge" && `회피 성공률 ${me.dodge_rate}%. 성공하면 이번 구간(턴+반응턴)에서 받는 적군 공격 피해를 무효화합니다.`}
          {type === "item" && "아이템 사용은 행동 1회를 소모합니다."}
          {type === "escape" && `도주 성공률 ${me.escape_rate}%. 성공하면 전투에서 이탈하며 이후 행동할 수 없습니다.`}
        </p>
      )}
      <ErrorBox>{error}</ErrorBox>
      {canAct ? (
        <button className="btn btn-primary btn-block" style={{ marginTop: 10 }} disabled={!ready || busy} onClick={submit}>
          {busy ? "제출 중…" : type ? `${ACTION_LABEL[type]} 제출 (한 번만 가능)` : "행동을 선택하세요"}
        </button>
      ) : (
        !my && <p className="small muted" style={{ marginTop: 8 }}>{disabledReason}</p>
      )}
      {my && !canAct && state.myAction && <p className="small muted" style={{ marginTop: 4 }}>{disabledReason}</p>}
    </Card>
  );
}

// ---------------------------------------------------------------------
// 관리자: 전투 기록 저장 상태 표시 + 재시도
// ---------------------------------------------------------------------
export function ArchiveStatus({ state, onChanged }: { state: RoomState; onChanged: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const { room } = state;
  if (room.status !== "ended") {
    return <p className="small muted">전투가 끝나면 기록이 자동으로 저장됩니다.</p>;
  }
  const retry = async () => {
    setBusy(true);
    setError("");
    try {
      await api(`/api/rooms/${room.id}/archive/retry`, { method: "POST" });
      onChanged();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  const label =
    room.archive_status === "saved" ? { cls: "alert-ok", text: "✅ 전투 기록 저장 완료 — 보관함에서 볼 수 있습니다." }
    : room.archive_status === "failed" ? { cls: "alert-error", text: "❌ 전투 기록 저장 실패" }
    : { cls: "alert-info", text: "⏳ 전투 기록 저장 중…" };
  return (
    <div className="stack" style={{ gap: 8 }}>
      <div className={`alert ${label.cls}`}>
        {label.text}
        {room.archive_status === "failed" && <div className="small">기록은 지워지지 않았습니다. 아래 버튼으로 다시 저장하세요.</div>}
      </div>
      {room.archive_status !== "saved" && (
        <button className="btn btn-primary" disabled={busy} onClick={retry}>
          {busy ? "저장 중…" : "🔁 기록 저장 재시도"}
        </button>
      )}
      <ErrorBox>{error}</ErrorBox>
    </div>
  );
}
