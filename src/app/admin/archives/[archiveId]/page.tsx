"use client";
// 관리자: 전투 기록 상세 (기본 정보 / 사이클별 전투 로그 / 채팅 기록 / 참가자 / 적군 등장 시점)
import { use, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { api, errorMessage } from "@/lib/apiClient";
import type { ArchiveDetail } from "@/lib/types";
import { ITEM_TYPE_LABEL, PLAYER_STATUS_LABEL, RESULT_LABEL } from "@/lib/types";
import { AdminGate } from "@/components/AdminGate";
import { LogTree } from "@/components/BattleLogView";
import { Card, ErrorBox, formatDateTime, formatSeconds, formatTime, HpBar, Tabs } from "@/components/ui";

export default function ArchiveDetailPage({ params }: { params: Promise<{ archiveId: string }> }) {
  const { archiveId } = use(params);
  return (
    <>
      <header className="topbar">
        <div className="row">
          <Link href="/admin/archives" className="btn btn-small btn-ghost">← 보관함</Link>
          <b>📜 전투 기록</b>
        </div>
      </header>
      <AdminGate>
        <Detail id={archiveId} />
      </AdminGate>
    </>
  );
}

function Detail({ id }: { id: string }) {
  const [rec, setRec] = useState<ArchiveDetail | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    api<ArchiveDetail>(`/api/archives/${id}`).then(setRec).catch((e) => setError(errorMessage(e)));
  }, [id]);

  if (error) return <main className="page"><ErrorBox>{error}</ErrorBox></main>;
  if (!rec) return <main className="page"><p className="muted">불러오는 중…</p></main>;
  const d = rec.archive_data;
  const r = d.room;

  return (
    <main className="page stack">
      <Card title={r.room_name}>
        {r.description && <p className="muted" style={{ marginBottom: 10 }}>{r.description}</p>}
        <div className={`result-banner result-${r.result}`} style={{ marginTop: 0, marginBottom: 12 }}>
          <b>{RESULT_LABEL[r.result] ?? r.result}</b>
          {r.end_reason && <span>사유: {r.end_reason}</span>}
        </div>
        <div className="stat-grid archive-stats">
          <div className="stat"><span>전투 시작</span><b>{r.started_at ? formatDateTime(r.started_at) : "-"}</b></div>
          <div className="stat"><span>전투 종료</span><b>{r.ended_at ? formatDateTime(r.ended_at) : "-"}</b></div>
          <div className="stat"><span>소요 시간</span><b>{formatSeconds(r.duration_seconds)}</b></div>
          <div className="stat"><span>총 사이클 / 단계</span><b>{r.total_cycles} / {r.total_phases}</b></div>
          <div className="stat"><span>선공 측</span><b>{r.first_side === "enemies" ? "적군 측" : "플레이어 측"}</b></div>
          <div className="stat"><span>턴 제한 시간</span><b>{Math.round(r.turn_duration / 60)}분</b></div>
        </div>
      </Card>

      <Tabs
        tabs={[
          {
            key: "logs",
            label: "⚔ 전투 로그",
            content: (
              <Card title="사이클별 전투 로그">
                <div className="scroll-box log-view" style={{ maxHeight: 640 }}>
                  <LogTree logs={d.logs} firstSide={r.first_side} />
                </div>
              </Card>
            ),
          },
          { key: "chat", label: "💬 채팅 기록", content: <ArchiveChat rec={rec} /> },
          { key: "players", label: "👥 참가자", content: <ArchivePlayers rec={rec} /> },
          { key: "enemies", label: "👹 적군·등장", content: <ArchiveEnemies rec={rec} /> },
        ]}
      />
    </main>
  );
}

function ArchiveChat({ rec }: { rec: ArchiveDetail }) {
  const d = rec.archive_data;
  const rows = useMemo(
    () =>
      [
        ...d.chat.map((c) => ({ key: `c${c.id}`, at: c.created_at, chat: c, ev: null })),
        ...d.events.map((e) => ({ key: `e${e.id}`, at: e.created_at, chat: null, ev: e })),
      ].sort((a, b) => a.at.localeCompare(b.at)),
    [d.chat, d.events],
  );
  return (
    <Card title={`채팅 기록 (메시지 ${d.chat.length} · 시스템 ${d.events.length})`}>
      <div className="scroll-box chat-list" style={{ maxHeight: 640 }}>
        {rows.length === 0 && <p className="muted">채팅 기록이 없습니다.</p>}
        {rows.map((x) =>
          x.chat ? (
            <div key={x.key} className={`chat-msg ${x.chat.sender_role === "admin" ? "chat-admin" : ""}`}>
              <span className="time">[{formatTime(x.at)}]</span>{" "}
              <b className="chat-nick">{x.chat.nickname}{x.chat.sender_role === "admin" ? " 👑" : ""}</b>: <span className="chat-text">{x.chat.message}</span>
            </div>
          ) : (
            <div key={x.key} className={`system-msg system-${x.ev!.event_type}`}>
              <span className="time">[{formatTime(x.at)}]</span> <span className="sys-tag">시스템</span> {x.ev!.event_message}
            </div>
          ),
        )}
      </div>
    </Card>
  );
}

function ArchivePlayers({ rec }: { rec: ArchiveDetail }) {
  const players = rec.archive_data.players;
  return (
    <Card title={`참가자 (${players.length})`}>
      <ul className="list">
        {players.map((p) => (
          <li key={p.nickname} className="list-item" style={{ display: "block" }}>
            <div className="row between">
              <div className="row">
                <b>{p.display_name}</b>
                {p.display_name !== p.nickname && <span className="small muted">({p.nickname})</span>}
                <span className={`badge badge-${p.status}`}>{PLAYER_STATUS_LABEL[p.status]}</span>
                {p.member_status !== "active" && <span className="badge">{p.member_status === "kicked" ? "강퇴" : "퇴장"}</span>}
              </div>
              <div style={{ minWidth: 180, flex: "0 1 240px" }}><HpBar current={p.final_hp} max={p.max_hp} compact /></div>
            </div>
            <div className="small muted" style={{ marginTop: 6 }}>
              누적 가한 피해 <b>{p.damage_dealt}</b> · 받은 피해 <b>{p.damage_taken}</b> · 사용 아이템:{" "}
              {p.items_used.length ? p.items_used.map((u) => `${u.item_name}(${ITEM_TYPE_LABEL[u.item_type]}) ×${u.count}`).join(", ") : "없음"}
              {p.items_left.length > 0 && <> · 남은 아이템: {p.items_left.map((i) => `${i.item_name} ×${i.quantity}`).join(", ")}</>}
            </div>
          </li>
        ))}
      </ul>
    </Card>
  );
}

function ArchiveEnemies({ rec }: { rec: ArchiveDetail }) {
  const enemies = rec.archive_data.enemies;
  return (
    <Card title={`적군 (${enemies.length}) · 등장 시점`}>
      <ul className="list">
        {enemies.map((e, i) => (
          <li key={`${e.name}${i}`} className="list-item" style={{ display: "block" }}>
            <div className="row between">
              <div className="row">
                {e.appearance_order && <span className="badge">#{e.appearance_order}</span>}
                <b>{e.name}</b>
                <span className={`badge enemy-state-${e.dead ? "dead" : e.appeared ? "appeared" : "registered"}`}>
                  {e.dead ? "사망" : e.appeared ? "생존" : "등장하지 않음"}
                </span>
              </div>
              <div style={{ minWidth: 180, flex: "0 1 240px" }}><HpBar current={e.final_hp} max={e.max_hp} compact /></div>
            </div>
            <div className="small muted" style={{ marginTop: 6 }}>
              {e.appeared && e.appeared_at
                ? <>등장 시각 <b>{new Date(e.appeared_at).toLocaleDateString("ko-KR")} {formatTime(e.appeared_at)}</b> · 등장 순서 {e.appearance_order}번째</>
                : "전투가 끝날 때까지 등장하지 않았습니다."}
            </div>
            {e.appeared && e.appearance_message && <div className="system-msg small" style={{ marginTop: 6 }}>{e.appearance_message}</div>}
          </li>
        ))}
      </ul>
    </Card>
  );
}
