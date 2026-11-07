"use client";
// 관리자: 전투방 관리 화면 — 메뉴 5개로 묶고, 각 메뉴 안에서 필요한 항목만 펼침
//  1) 전투방 관리  2) 플레이어 관리  3) 적군 및 아이템 관리  4) 전투 진행 관리  5) 기록 및 채팅 관리
//  + 상단 빠른 전투 제어 바, 오른쪽(모바일은 아래) 상시 채팅
import { use, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { api, errorMessage } from "@/lib/apiClient";
import { useRoomState } from "@/lib/useRoomState";
import type { Member, RoomState } from "@/lib/types";
import { MEMBER_STATUS_LABEL, PLAYER_STATUS_LABEL } from "@/lib/types";
import { EnemiesPanel, FirstSidePanel, GrantPanel, ItemsPanel, PlayerStatsPanel, ProfilesPanel } from "@/components/admin/SetupPanels";
import { BattleProgress, BattleStartEnd, QuickBar } from "@/components/admin/BattleControl";
import { AppearanceBanner } from "@/components/BattleView";
import { ArchiveStatus, phaseTarget, useAutoTick, useRemaining } from "@/components/BattlePanels";
import { BattleLogView } from "@/components/BattleLogView";
import { ChatPanel } from "@/components/ChatPanel";
import { NameTag, ProfileFieldsEditor } from "@/components/Profile";
import { Card, CopyButton, ErrorBox, formatDateTime, formatDuration, HpBar, RealtimeDot, StatusBadge } from "@/components/ui";

const MENUS = [
  { key: "room", label: "🏰 전투방 관리", subs: [["info", "방 정보·코드"], ["first", "선공·턴 시간"], ["fields", "프로필 항목"], ["battle", "전투 시작·종료"]] },
  { key: "players", label: "👥 플레이어 관리", subs: [["members", "참가자·퇴장"], ["profiles", "프로필"], ["stats", "HP·능력치"], ["grant", "아이템 지급"]] },
  { key: "enemies", label: "👹 적군 및 아이템", subs: [["enemies", "적군"], ["items", "아이템"]] },
  { key: "progress", label: "⚔ 전투 진행 관리", subs: [["control", "진행·제출 현황"], ["log", "전투 로그"]] },
  { key: "records", label: "📜 기록 및 채팅", subs: [["chat", "채팅 관리"], ["archive", "전투 기록"]] },
] as const;
type MenuKey = (typeof MENUS)[number]["key"];

export default function AdminRoomPage({ params }: { params: Promise<{ roomId: string }> }) {
  const { roomId } = use(params);
  const { state, error, realtime, refresh, clockOffset } = useRoomState(roomId);
  const remaining = useRemaining(phaseTarget(state), clockOffset);
  useAutoTick(state, remaining, refresh);
  const [menu, setMenu] = useState<MenuKey>("room");
  const [subs, setSubs] = useState<Record<string, string>>({});
  const current = MENUS.find((m) => m.key === menu)!;
  const sub = subs[menu] ?? current.subs[0][0];
  const goto = (m: string, s?: string) => {
    setMenu(m as MenuKey);
    if (s) setSubs((x) => ({ ...x, [m]: s }));
  };

  return (
    <>
      <header className="topbar">
        <div className="row">
          <Link href="/admin" className="btn btn-small btn-ghost">← 목록</Link>
          <b>{state?.room.room_name ?? "전투방"}</b>
          {state && <StatusBadge status={state.room.status} />}
        </div>
        <div className="row">
          {state && (
            <>
              <span className="mono room-code" style={{ fontSize: "1.1rem" }}>{state.room.room_code}</span>
              <CopyButton text={state.room.room_code} label="코드 복사" />
            </>
          )}
          <RealtimeDot status={realtime} />
        </div>
      </header>
      <main className="page">
        {error && !state && (
          <Card>
            <ErrorBox>{error.message}</ErrorBox>
            <p style={{ marginTop: 12 }}><Link href="/admin">관리자 홈으로</Link></p>
          </Card>
        )}
        {state && state.viewer !== "admin" && <ErrorBox>관리자 권한이 필요합니다.</ErrorBox>}
        {state && state.viewer === "admin" && (
          <>
            <QuickBar state={state} remaining={remaining} onChanged={refresh} goto={goto} />
            <div className="admin-layout">
              <AppearanceBanner events={state.events} />
              <nav className="side-menu">
                {MENUS.map((m) => (
                  <button key={m.key} className={menu === m.key ? "on" : ""} onClick={() => setMenu(m.key)}>{m.label}</button>
                ))}
              </nav>
              <div className="stack">
                {error && <ErrorBox>{error.message}</ErrorBox>}
                <div className="sub-tabs" role="tablist">
                  {current.subs.map(([k, label]) => (
                    <button key={k} role="tab" aria-selected={sub === k} className={sub === k ? "on" : ""}
                      onClick={() => setSubs((x) => ({ ...x, [menu]: k }))}>{label}</button>
                  ))}
                </div>
                <MenuContent state={state} menu={menu} sub={sub} remaining={remaining} refresh={refresh} />
              </div>
              {/* 채팅은 어떤 메뉴를 보고 있어도 항상 옆(모바일은 아래)에 표시 → 스토리 진행 중 바로 적군 등장 가능 */}
              <aside className="admin-chat">
                <Card title="💬 채팅 · 스토리 진행">
                  <ChatPanel state={state} onSent={refresh} height={460} />
                </Card>
              </aside>
            </div>
          </>
        )}
        {!state && !error && <p className="muted">불러오는 중…</p>}
      </main>
    </>
  );
}

function MenuContent({ state, menu, sub, remaining, refresh }: {
  state: RoomState; menu: MenuKey; sub: string; remaining: number | null; refresh: () => void;
}) {
  const key = `${menu}/${sub}`;
  switch (key) {
    case "room/info": return <SettingsPanel state={state} />;
    case "room/first": return <FirstSidePanel state={state} onChanged={refresh} />;
    case "room/fields": return <Card title="프로필 추가 항목"><ProfileFieldsEditor state={state} onSaved={refresh} /></Card>;
    case "room/battle": return <BattleStartEnd state={state} onChanged={refresh} />;
    case "players/members": return <MembersPanel state={state} onChanged={refresh} />;
    case "players/profiles": return <ProfilesPanel state={state} onChanged={refresh} />;
    case "players/stats": return <PlayerStatsPanel state={state} onChanged={refresh} />;
    case "players/grant": return <GrantPanel state={state} onChanged={refresh} />;
    case "enemies/enemies": return <EnemiesPanel state={state} onChanged={refresh} />;
    case "enemies/items": return <ItemsPanel state={state} onChanged={refresh} />;
    case "progress/control": return <BattleProgress state={state} remaining={remaining} onChanged={refresh} />;
    case "progress/log": return <Card title="전투 로그"><BattleLogView state={state} /></Card>;
    case "records/chat":
      return (
        <Card title="채팅 관리">
          <p className="small muted" style={{ marginBottom: 8 }}>부적절한 메시지는 [가리기]로 숨길 수 있습니다. 원문은 관리자만 볼 수 있고 기록에도 남습니다.</p>
          <ChatPanel state={state} onSent={refresh} height={560} moderate />
        </Card>
      );
    case "records/archive":
      return (
        <Card title="전투 기록">
          <ArchiveStatus state={state} onChanged={refresh} />
          <p className="small muted" style={{ margin: "10px 0" }}>모든 전투방의 지난 기록은 보관함에서 볼 수 있습니다.</p>
          <Link className="btn btn-primary" href="/admin/archives">📜 기록 보관함 열기</Link>
        </Card>
      );
    default: return null;
  }
}

function SettingsPanel({ state }: { state: RoomState }) {
  const router = useRouter();
  const { room } = state;
  const activeCount = state.members.filter((m) => m.status === "active").length;
  const remove = async () => {
    if (!confirm(`'${room.room_name}' 전투방을 삭제할까요?\n(종료된 전투 기록은 보관함에 남습니다)`)) return;
    try {
      await api(`/api/rooms/${room.id}`, { method: "DELETE" });
      router.push("/admin");
    } catch (e) {
      alert(errorMessage(e));
    }
  };
  return (
    <Card title="전투방 설정">
      <div className="stack" style={{ gap: 12 }}>
        <div className="alert alert-info row between">
          <div>
            <div className="small">방 코드 (참가자에게 공유)</div>
            <div className="room-code mono">{room.room_code}</div>
          </div>
          <CopyButton text={room.room_code} label="코드 복사" />
        </div>
        <div className="stat-grid">
          <div className="stat"><span>전투방 이름</span><b>{room.room_name}</b></div>
          <div className="stat"><span>상태</span><b><StatusBadge status={room.status} /></b></div>
          <div className="stat"><span>참가 인원</span><b>{activeCount} / {room.max_players}명</b></div>
          <div className="stat"><span>턴 제한 시간</span><b>{formatDuration(room.turn_duration)}</b></div>
          <div className="stat"><span>입장 비밀번호</span><b>{room.has_password ? "사용" : "없음"}</b></div>
          <div className="stat"><span>생성 시각</span><b>{formatDateTime(room.created_at)}</b></div>
        </div>
        {room.description && <p style={{ whiteSpace: "pre-wrap" }}>{room.description}</p>}
        <div className="row">
          <button className="btn btn-danger" onClick={remove} disabled={room.status === "in_progress"}>
            전투방 삭제
          </button>
          {room.status === "in_progress" && <span className="small muted">진행 중인 전투는 먼저 종료해야 삭제할 수 있습니다.</span>}
        </div>
      </div>
    </Card>
  );
}

function MembersPanel({ state, onChanged }: { state: RoomState; onChanged: () => void }) {
  const [error, setError] = useState("");
  const playerOf = (m: Member) => state.players.find((p) => p.member_id === m.id);
  const active = state.members.filter((m) => m.status === "active");
  const others = state.members.filter((m) => m.status !== "active");

  const kick = async (m: Member) => {
    if (!confirm(`${m.nickname} 님을 강퇴할까요? 강퇴된 사용자는 이 방에 다시 입장할 수 없습니다.`)) return;
    setError("");
    try {
      await api(`/api/rooms/${state.room.id}/members/${m.id}/kick`, { method: "POST" });
      onChanged();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  return (
    <Card title={`참가자 관리 (${active.length}/${state.room.max_players}명)`}>
      <ErrorBox>{error}</ErrorBox>
      {active.length === 0 && <p className="muted">아직 입장한 참가자가 없습니다. 방 코드를 공유하세요.</p>}
      <ul className="list">
        {active.map((m) => {
          const p = playerOf(m);
          return (
            <li key={m.id} className="list-item">
              <div className="grow">
                <div className="row">
                  {p ? <NameTag name={p.display_name} color={p.name_color} /> : <b>{m.nickname}</b>}
                  {p && p.display_name !== m.nickname && <span className="small muted">({m.nickname})</span>}
                  {p && <span className={`badge badge-${p.status}`}>{PLAYER_STATUS_LABEL[p.status]}</span>}
                </div>
                <div className="small muted">입장 {formatDateTime(m.joined_at)}</div>
                {p && <div style={{ marginTop: 6 }}><HpBar current={p.current_hp} max={p.max_hp} compact /></div>}
              </div>
              <button className="btn btn-small btn-danger" onClick={() => kick(m)}>
                강퇴
              </button>
            </li>
          );
        })}
      </ul>
      {others.length > 0 && (
        <>
          <h3 style={{ margin: "16px 0 8px" }} className="muted">퇴장 / 강퇴 기록</h3>
          <ul className="list">
            {others.map((m) => (
              <li key={m.id} className="list-item">
                <span>{m.nickname}</span>
                <span className={`badge badge-${m.status}`}>{MEMBER_STATUS_LABEL[m.status]}</span>
              </li>
            ))}
          </ul>
        </>
      )}
    </Card>
  );
}

