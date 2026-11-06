"use client";
// 관리자: 전투방 관리 화면 (메뉴 9개 — 이번 단계에서는 1, 2번 구현)
import { use, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { api, errorMessage } from "@/lib/apiClient";
import { useRoomState } from "@/lib/useRoomState";
import type { Member, RoomState } from "@/lib/types";
import { MEMBER_STATUS_LABEL, PLAYER_STATUS_LABEL } from "@/lib/types";
import { EnemiesPanel, FirstSidePanel, ItemsPanel, PlayerStatsPanel } from "@/components/admin/SetupPanels";
import { AppearanceBanner, SystemEventList } from "@/components/BattleView";
import { Card, CopyButton, ErrorBox, formatDateTime, formatDuration, HpBar, Placeholder, RealtimeDot, StatusBadge } from "@/components/ui";

const MENUS = [
  { key: "settings", label: "1. 전투방 설정", stage: 2 },
  { key: "members", label: "2. 참가자 관리", stage: 2 },
  { key: "players", label: "3. 플레이어 능력치", stage: 3 },
  { key: "enemies", label: "4. 적군 관리", stage: 3 },
  { key: "items", label: "5. 아이템 관리", stage: 3 },
  { key: "first", label: "6. 선공 측 설정", stage: 3 },
  { key: "control", label: "7. 전투 진행 제어", stage: 4 },
  { key: "logs", label: "8. 전투 로그", stage: 5 },
  { key: "archive", label: "9. 전투 기록 보관함", stage: 7 },
] as const;
const IMPLEMENTED_STAGE = 3;

export default function AdminRoomPage({ params }: { params: Promise<{ roomId: string }> }) {
  const { roomId } = use(params);
  const { state, error, realtime, refresh } = useRoomState(roomId);
  const [menu, setMenu] = useState<(typeof MENUS)[number]["key"]>("settings");

  return (
    <>
      <header className="topbar">
        <div className="row">
          <Link href="/admin" className="btn btn-small btn-ghost">
            ← 목록
          </Link>
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
            <p style={{ marginTop: 12 }}>
              <Link href="/admin">관리자 홈으로</Link>
            </p>
          </Card>
        )}
        {state && state.viewer !== "admin" && <ErrorBox>관리자 권한이 필요합니다.</ErrorBox>}
        {state && state.viewer === "admin" && (
          <div className="admin-layout">
            <AppearanceBanner events={state.events} />
            <nav className="side-menu">
              {MENUS.map((m) => (
                <button key={m.key} className={menu === m.key ? "on" : ""} onClick={() => setMenu(m.key)}>
                  {m.label}
                  {m.stage > IMPLEMENTED_STAGE && <span className="todo">({m.stage}단계)</span>}
                </button>
              ))}
            </nav>
            <div className="stack">
              {error && <ErrorBox>{error.message}</ErrorBox>}
              {menu === "settings" && <SettingsPanel state={state} />}
              {menu === "members" && <MembersPanel state={state} onChanged={refresh} />}
              {menu === "players" && <PlayerStatsPanel state={state} onChanged={refresh} />}
              {menu === "enemies" && <EnemiesPanel state={state} onChanged={refresh} />}
              {menu === "items" && <ItemsPanel state={state} onChanged={refresh} />}
              {menu === "first" && <FirstSidePanel state={state} onChanged={refresh} />}
              {menu === "control" && (
                <Card title="전투 진행 제어">
                  <Placeholder stage={4}>전투 시작, 현재 사이클/단계/남은 시간, 제출 현황, 조기 판정, 강제 종료.</Placeholder>
                </Card>
              )}
              {menu === "logs" && (
                <Card title="전투 로그">
                  <h3 style={{ marginBottom: 8 }}>시스템 이벤트</h3>
                  <SystemEventList events={state.events} />
                  <div style={{ height: 12 }} />
                  <Placeholder stage={5}>사이클별, [턴 + 반응턴] 묶음으로 전투 결과를 보여줍니다.</Placeholder>
                </Card>
              )}
              {menu === "archive" && (
                <Card title="전투 기록 보관함">
                  <Placeholder stage={7}>전투 종료 시 자동 저장된 기록을 열람합니다.</Placeholder>
                </Card>
              )}
            </div>
          </div>
        )}
        {!state && !error && <p className="muted">불러오는 중…</p>}
      </main>
    </>
  );
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
                  <b>{m.nickname}</b>
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

