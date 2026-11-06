"use client";
// 게스트: 전투방 화면 (상단 정보 + 전투/채팅 탭)
import { use, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { api, errorMessage } from "@/lib/apiClient";
import { useRoomState } from "@/lib/useRoomState";
import type { FullPlayer, RoomState } from "@/lib/types";
import { PLAYER_STATUS_LABEL } from "@/lib/types";
import { Card, ErrorBox, HpBar, RealtimeDot, StatusBadge, Tabs } from "@/components/ui";
import { AppearanceBanner, EnemyCards, MyInventory, SystemEventList } from "@/components/BattleView";
import { ActionPanel, IncomingAttacks, needsMyAction, PhaseHeader, PlayerList, ResultBanner, useAutoTick, useRemaining } from "@/components/BattlePanels";
import { BattleLogView } from "@/components/BattleLogView";
import { ChatPanel, useUnread } from "@/components/ChatPanel";

export default function GuestRoomPage({ params }: { params: Promise<{ roomId: string }> }) {
  const { roomId } = use(params);
  const { state, error, realtime, clockOffset, refresh } = useRoomState(roomId);
  const remaining = useRemaining(state?.phase?.status === "open" ? state.phase.ends_at : null, clockOffset);
  useAutoTick(state, remaining, refresh);
  const [tab, setTab] = useState("battle");
  const unread = useUnread(state, tab === "chat");

  if (!state) {
    return (
      <main className="page page-narrow stack">
        {error ? (
          <Card title="전투방에 들어갈 수 없습니다">
            <ErrorBox>{error.message}</ErrorBox>
            <p style={{ marginTop: 12 }}>
              <Link className="btn btn-primary" href="/">
                입장 화면으로
              </Link>
            </p>
          </Card>
        ) : (
          <p className="muted">전투방 정보를 불러오는 중…</p>
        )}
      </main>
    );
  }

  return (
    <>
      <header className="topbar">
        <div className="row">
          <b>{state.room.room_name}</b>
          <StatusBadge status={state.room.status} />
        </div>
        <div className="row">
          <RealtimeDot status={realtime} />
          {state.viewer === "admin" && (
            <Link className="btn btn-small" href={`/admin/rooms/${roomId}`}>
              관리 화면
            </Link>
          )}
        </div>
      </header>
      <main className="page stack">
        {error && <ErrorBox>{error.message} (자동으로 다시 시도합니다)</ErrorBox>}
        <AppearanceBanner events={state.events} />
        <ResultBanner state={state} />
        <PhaseHeader state={state} remaining={remaining} />
        <Tabs
          active={tab}
          onChange={setTab}
          tabs={[
            { key: "battle", label: "⚔ 전투", content: <BattleTab state={state} remaining={remaining} onDone={refresh} /> },
            {
              key: "chat",
              label: <>💬 채팅{unread > 0 && <span className="unread">{unread > 99 ? "99+" : unread}</span>}</>,
              content: (
                <div className="stack">
                  {/* 채팅 중에도 행동 제출 가능 (같은 서버 API 사용) */}
                  {needsMyAction(state, remaining) && <ActionPanel state={state} remaining={remaining} onDone={refresh} />}
                  {state.myAction && state.room.status === "in_progress" && state.phase?.acting_side === "players" && (
                    <div className="alert alert-ok small">✅ 이번 단계 행동 제출 완료 · 판정까지 대기 중</div>
                  )}
                  <Card title="채팅">
                    <ChatPanel state={state} onSent={refresh} height={520} />
                  </Card>
                </div>
              ),
            },
          ]}
        />
        {state.viewer === "guest" && <LeaveButton state={state} />}
      </main>
    </>
  );
}

function BattleTab({ state, remaining, onDone }: { state: RoomState; remaining: number | null; onDone: () => void }) {
  const me = state.me?.player as FullPlayer | null | undefined;
  return (
    <div className="grid-2">
      <div className="stack">
        <IncomingAttacks state={state} />
        {state.viewer === "guest" && <ActionPanel state={state} remaining={remaining} onDone={onDone} />}
        {me && (
          <Card title={`내 캐릭터 · ${me.display_name}`}>
            <HpBar current={me.current_hp} max={me.max_hp} />
            <div className="stat-grid">
              <div className="stat"><span>공격력</span><b>{me.min_attack} ~ {me.max_attack}</b></div>
              <div className="stat"><span>상태</span><b>{PLAYER_STATUS_LABEL[me.status]}</b></div>
              <div className="stat"><span>회피 성공률</span><b>{me.dodge_rate}%</b></div>
              <div className="stat"><span>도주 성공률</span><b>{me.escape_rate}%</b></div>
            </div>
            <p className="small muted" style={{ marginTop: 8 }}>능력치는 관리자만 수정할 수 있습니다.</p>
          </Card>
        )}
        <MyInventory state={state} />
      </div>
      <div className="stack">
        <EnemyCards enemies={state.enemies} />
        <PlayerList state={state} />
        <Card title="전투 로그">
          <BattleLogView state={state} />
        </Card>
        <Card title="시스템 메시지">
          <SystemEventList events={state.events} />
        </Card>
      </div>
    </div>
  );
}

function LeaveButton({ state }: { state: RoomState }) {
  const router = useRouter();
  const [error, setError] = useState("");
  const leave = async () => {
    if (!confirm("전투방에서 나갈까요? 같은 브라우저에서 방 코드로 다시 입장하면 캐릭터가 복구됩니다.")) return;
    try {
      await api(`/api/rooms/${state.room.id}/leave`, { method: "POST" });
      router.push("/");
    } catch (e) {
      setError(errorMessage(e));
    }
  };
  return (
    <div className="stack" style={{ gap: 8 }}>
      <ErrorBox>{error}</ErrorBox>
      <button className="btn btn-ghost btn-small" onClick={leave} disabled={state.room.status === "in_progress"}>
        전투방 나가기
      </button>
    </div>
  );
}
