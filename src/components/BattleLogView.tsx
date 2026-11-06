"use client";
// 5단계: 전투 로그를 사이클 → [턴 + 반응턴] 묶음 → 단계 순서로 보여줍니다.
// (서버는 4개 단계를 각각 판정·기록하고, 화면에서만 2개씩 묶어서 표시)
import { useEffect, useMemo, useRef, useState } from "react";
import { api, errorMessage } from "@/lib/apiClient";
import type { BattleLog, HistoryPage, RoomState, Side } from "@/lib/types";
import { phaseName } from "@/lib/types";
import { formatTime } from "@/components/ui";

interface PhaseGroup { n: number; startedAt: string | null; logs: BattleLog[] }
interface CycleGroup { n: number; phases: Map<number, PhaseGroup>; count: number }

function group(logs: BattleLog[]) {
  const prep: BattleLog[] = [];
  const cycles = new Map<number, CycleGroup>();
  for (const l of logs) {
    if (l.cycle_number == null || l.phase_number == null) {
      prep.push(l);
      continue;
    }
    let c = cycles.get(l.cycle_number);
    if (!c) cycles.set(l.cycle_number, (c = { n: l.cycle_number, phases: new Map(), count: 0 }));
    let p = c.phases.get(l.phase_number);
    if (!p) c.phases.set(l.phase_number, (p = { n: l.phase_number, startedAt: null, logs: [] }));
    if (l.log_type === "phase_started") p.startedAt = l.created_at;
    else {
      p.logs.push(l);
      c.count++;
    }
  }
  return { prep, cycles: [...cycles.values()].sort((a, b) => a.n - b.n) };
}

/** 이전 기록 더 보기 (서버 페이지 조회) */
export function useOlder<T extends { id: number }>(roomId: string, kind: "chat" | "logs", latest: T[], initialHasMore: boolean) {
  const [older, setOlder] = useState<T[]>([]);
  const [hasMore, setHasMore] = useState(initialHasMore);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    if (older.length === 0) setHasMore(initialHasMore);
  }, [initialHasMore, older.length]);
  const all = useMemo(() => {
    const map = new Map<number, T>();
    for (const x of older) map.set(x.id, x);
    for (const x of latest) map.set(x.id, x);
    return [...map.values()].sort((a, b) => a.id - b.id);
  }, [older, latest]);
  const loadMore = async () => {
    const first = all[0]?.id;
    if (!first) return;
    setBusy(true);
    setError("");
    try {
      const page = await api<HistoryPage<T>>(`/api/rooms/${roomId}/history?kind=${kind}&before=${first}`);
      setOlder((o) => [...page.items, ...o]);
      setHasMore(page.has_more);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  return { all, hasMore, loadMore, busy, error };
}

/** 스크롤이 맨 아래에 있을 때만 새 내용이 오면 자동으로 따라 내려감 */
export function useStickToBottom(dep: unknown) {
  const ref = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  useEffect(() => {
    const el = ref.current;
    if (el && stick.current) el.scrollTop = el.scrollHeight;
  }, [dep]);
  const onScroll = () => {
    const el = ref.current;
    if (el) stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 60;
  };
  return { ref, onScroll };
}

export function BattleLogView({ state }: { state: RoomState }) {
  const { all, hasMore, loadMore, busy, error } = useOlder<BattleLog>(state.room.id, "logs", state.logs, state.logs.length >= 400);
  const { ref, onScroll } = useStickToBottom(all.length);
  return (
    <div className="scroll-box log-view" ref={ref} onScroll={onScroll}>
      {hasMore && (
        <button className="btn btn-small btn-ghost" disabled={busy} onClick={loadMore}>
          {busy ? "불러오는 중…" : "▲ 이전 기록 더 보기"}
        </button>
      )}
      {error && <p className="small" style={{ color: "var(--danger)" }}>{error}</p>}
      <LogTree logs={all} firstSide={state.room.first_side} />
    </div>
  );
}

/** 로그 묶음 표시 (실시간 화면과 전투 기록 보관함에서 공통 사용) */
export function LogTree({ logs, firstSide, openAll = false }: { logs: BattleLog[]; firstSide: Side | null; openAll?: boolean }) {
  const { prep, cycles } = useMemo(() => group(logs), [logs]);
  const latestCycle = cycles.length ? cycles[cycles.length - 1].n : null;
  const first = firstSide;
  return (
    <>
      {logs.length === 0 && <p className="muted">아직 전투 기록이 없습니다.</p>}

      {prep.length > 0 && (
        <section className="log-cycle">
          <div className="log-cycle-title">전투 준비 / 시스템</div>
          {prep.map((l) => <LogLine key={l.id} log={l} />)}
        </section>
      )}

      {cycles.map((c) => (
        <details key={c.n} className="log-cycle" open={openAll || c.n === latestCycle || undefined}>
          <summary className="log-cycle-title">
            사이클 {c.n} <span className="small muted">· 기록 {c.count}개</span>
          </summary>
          {[[1, 2], [3, 4]].map(([a, b]) => {
            const pa = c.phases.get(a);
            const pb = c.phases.get(b);
            if (!pa && !pb) return null;
            return (
              <div key={a} className="exchange">
                <div className="exchange-title">[{phaseName(first, a)} + {phaseName(first, b)}]</div>
                {[pa, pb].map((p) =>
                  p ? (
                    <div key={p.n} className="phase-block">
                      <div className="phase-title">
                        {p.n}단계 · {phaseName(first, p.n)}
                        {p.startedAt && <span className="time"> {formatTime(p.startedAt)}</span>}
                      </div>
                      {p.logs.length === 0 && <div className="log muted">(기록 없음)</div>}
                      {p.logs.map((l) => <LogLine key={l.id} log={l} />)}
                    </div>
                  ) : null,
                )}
              </div>
            );
          })}
        </details>
      ))}
    </>
  );
}

function LogLine({ log }: { log: BattleLog }) {
  return (
    <div className={`log log-${log.log_type}`}>
      <span className="time">{formatTime(log.created_at)}</span> {log.content}
    </div>
  );
}
