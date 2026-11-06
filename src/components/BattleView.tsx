"use client";
// 참가자 화면용 전투 정보 조각: 적군 카드, 등장 연출 배너, 시스템 메시지, 인벤토리
import { useEffect, useRef, useState } from "react";
import type { BattleEvent, Enemy, RoomState } from "@/lib/types";
import { enemyStateLabel, ITEM_TYPE_LABEL } from "@/lib/types";
import { Card, formatTime, HpBar } from "@/components/ui";

/** 등장한 적군 카드 목록 (미등장 적군은 서버가 애초에 보내지 않음) */
export function EnemyCards({ enemies }: { enemies: Enemy[] }) {
  const shown = enemies
    .filter((e) => e.appearance_status === "appeared")
    .sort((a, b) => (a.appearance_order ?? 0) - (b.appearance_order ?? 0));
  const alive = shown.filter((e) => e.status === "alive").length;
  return (
    <Card title={`적군 (생존 ${alive})`}>
      {shown.length === 0 && <p className="muted">아직 등장한 적군이 없습니다.</p>}
      <div className="enemy-grid">
        {shown.map((e) => (
          <div key={e.id} className={`enemy-card ${e.status === "dead" ? "enemy-card-dead" : ""}`}>
            <div className="row between">
              <b className="enemy-name">{e.name}</b>
              <span className={`badge enemy-state-${e.status === "dead" ? "dead" : "appeared"}`}>{enemyStateLabel(e)}</span>
            </div>
            {e.description && <p className="small muted">{e.description}</p>}
            <HpBar current={e.current_hp} max={e.max_hp} compact />
          </div>
        ))}
      </div>
    </Card>
  );
}

/**
 * 적군 등장 연출: 화면을 연 뒤 새로 들어온 등장 이벤트를 큰 배너로 4초간 보여줌.
 * (처음 불러올 때 이미 있던 이벤트는 다시 띄우지 않음)
 */
export function AppearanceBanner({ events }: { events: BattleEvent[] }) {
  const lastSeen = useRef<number | null>(null);
  const [queue, setQueue] = useState<BattleEvent[]>([]);

  useEffect(() => {
    const maxId = events.reduce((m, e) => Math.max(m, e.id), 0);
    if (lastSeen.current === null) {
      lastSeen.current = maxId;
      return;
    }
    const fresh = events.filter((e) => e.id > (lastSeen.current ?? 0) && e.event_type === "enemy_appeared");
    lastSeen.current = Math.max(lastSeen.current, maxId);
    if (fresh.length) setQueue((q) => [...q, ...fresh]);
  }, [events]);

  const current = queue[0];
  useEffect(() => {
    if (!current) return;
    const t = setTimeout(() => setQueue((q) => q.slice(1)), 4000);
    return () => clearTimeout(t);
  }, [current]);

  if (!current) return null;
  return (
    <div className="appear-banner" role="alert" onClick={() => setQueue((q) => q.slice(1))}>
      <div className="appear-inner">
        <span className="appear-label">⚠ 적군 등장</span>
        <p>{current.event_message}</p>
      </div>
    </div>
  );
}

/** 시스템 메시지 목록 (적군 등장 등). 일반 채팅과 다른 디자인. */
export function SystemEventList({ events, empty = "아직 시스템 메시지가 없습니다." }: { events: BattleEvent[]; empty?: string }) {
  const endRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    endRef.current?.scrollIntoView({ block: "nearest" });
  }, [events.length]);
  return (
    <div className="scroll-box">
      {events.length === 0 && <p className="muted">{empty}</p>}
      {events.map((e) => (
        <div key={e.id} className={`system-msg system-${e.event_type}`}>
          <span className="time">[{formatTime(e.created_at)}]</span>{" "}
          <span className="sys-tag">시스템</span> {e.event_message}
        </div>
      ))}
      <div ref={endRef} />
    </div>
  );
}

/** 내 보유 아이템 */
export function MyInventory({ state }: { state: RoomState }) {
  const me = state.me?.player;
  if (!me) return null;
  const owned = state.inventory.filter((inv) => inv.player_id === me.id && inv.quantity > 0);
  return (
    <Card title="보유 아이템">
      {owned.length === 0 && <p className="muted">보유한 아이템이 없습니다.</p>}
      <ul className="list">
        {owned.map((inv) => {
          const item = state.items.find((i) => i.id === inv.item_id);
          if (!item) return null;
          return (
            <li key={inv.item_id} className="list-item">
              <div className="grow">
                <div className="row">
                  <b>{item.name}</b>
                  <span className={`badge item-${item.item_type}`}>
                    {ITEM_TYPE_LABEL[item.item_type]} {item.effect_value}
                  </span>
                </div>
                {item.description && <div className="small muted">{item.description}</div>}
              </div>
              <b>×{inv.quantity}</b>
            </li>
          );
        })}
      </ul>
      <p className="small muted" style={{ marginTop: 8 }}>아이템은 전투 중 [행동 선택 → 아이템 사용]으로 쓸 수 있습니다.</p>
    </Card>
  );
}
