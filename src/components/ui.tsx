"use client";
// 공통 UI 조각들
import { useState, type ReactNode } from "react";
import type { RoomStatus } from "@/lib/types";
import { ROOM_STATUS_LABEL } from "@/lib/types";
import type { RealtimeStatus } from "@/lib/useRoomState";

export function Card({ title, children, actions }: { title?: ReactNode; children: ReactNode; actions?: ReactNode }) {
  return (
    <section className="card">
      {(title || actions) && (
        <div className="card-head">
          {title && <h2>{title}</h2>}
          {actions && <div className="card-actions">{actions}</div>}
        </div>
      )}
      {children}
    </section>
  );
}

export function HpBar({ current, max, compact }: { current: number; max: number; compact?: boolean }) {
  const pct = max > 0 ? Math.max(0, Math.min(100, (current / max) * 100)) : 0;
  const tone = pct > 50 ? "high" : pct > 20 ? "mid" : "low";
  return (
    <div className={`hp ${compact ? "hp-compact" : ""}`} aria-label={`HP ${current}/${max}`}>
      <div className={`hp-fill hp-${tone}`} style={{ width: `${pct}%` }} />
      <span className="hp-text">
        HP {current} / {max}
      </span>
    </div>
  );
}

export function StatusBadge({ status }: { status: RoomStatus }) {
  return <span className={`badge badge-${status}`}>{ROOM_STATUS_LABEL[status]}</span>;
}

export function RealtimeDot({ status }: { status: RealtimeStatus }) {
  const label = status === "live" ? "실시간 연결됨" : status === "connecting" ? "연결 중…" : "실시간 끊김 (자동 재시도)";
  return (
    <span className={`rt rt-${status}`} title={label}>
      <i /> {label}
    </span>
  );
}

export function ErrorBox({ children }: { children: ReactNode }) {
  return children ? <div className="alert alert-error" role="alert">{children}</div> : null;
}

export function CopyButton({ text, label = "복사" }: { text: string; label?: string }) {
  const [done, setDone] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      // 구형 브라우저 / http 환경 대비
      const ta = document.createElement("textarea");
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      ta.remove();
    }
    setDone(true);
    setTimeout(() => setDone(false), 1500);
  };
  return (
    <button type="button" className="btn btn-small" onClick={copy}>
      {done ? "복사됨 ✓" : label}
    </button>
  );
}

/** 탭: 모든 탭 내용을 계속 렌더링하고 보이기만 전환 → 탭을 바꿔도 상태(입력 중인 내용, 스크롤 등) 유지 */
export function Tabs({ tabs, active: activeProp, onChange }: {
  tabs: { key: string; label: ReactNode; content: ReactNode }[];
  active?: string;
  onChange?: (key: string) => void;
}) {
  const [inner, setInner] = useState(tabs[0]?.key);
  const active = activeProp ?? inner;
  const setActive = (k: string) => {
    setInner(k);
    onChange?.(k);
  };
  return (
    <div className="tabs">
      <div className="tab-bar" role="tablist">
        {tabs.map((t) => (
          <button
            key={t.key}
            role="tab"
            aria-selected={active === t.key}
            className={`tab ${active === t.key ? "tab-active" : ""}`}
            onClick={() => setActive(t.key)}
          >
            {t.label}
          </button>
        ))}
      </div>
      {tabs.map((t) => (
        <div key={t.key} role="tabpanel" hidden={active !== t.key} className="tab-panel">
          {t.content}
        </div>
      ))}
    </div>
  );
}

export function Placeholder({ stage, children }: { stage: number; children: ReactNode }) {
  return (
    <div className="placeholder">
      <span className="badge">{stage}단계에서 구현 예정</span>
      <p>{children}</p>
    </div>
  );
}

export function formatDuration(sec: number) {
  return `${Math.floor(sec / 60)}분${sec % 60 ? ` ${sec % 60}초` : ""}`;
}

export function formatDateTime(iso: string) {
  return new Date(iso).toLocaleString("ko-KR", { dateStyle: "short", timeStyle: "short" });
}

/** [21:03:12] 형식 시각 */
export function formatTime(iso: string) {
  const d = new Date(iso);
  return [d.getHours(), d.getMinutes(), d.getSeconds()].map((n) => String(n).padStart(2, "0")).join(":");
}
