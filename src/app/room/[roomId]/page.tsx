"use client";
// 게스트: 전투방 화면 (상단 정보 + 전투/채팅 탭)
import { use, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { api, errorMessage } from "@/lib/apiClient";
import { useRoomState } from "@/lib/useRoomState";
import type { FullPlayer, RoomState } from "@/lib/types";
import { PLAYER_STATUS_LABEL } from "@/lib/types";
import { Card, ErrorBox, HpBar, Placeholder, RealtimeDot, StatusBadge, Tabs } from "@/components/ui";
import { AppearanceBanner, EnemyCards, MyInventory, SystemEventList } from "@/components/BattleView";

export default function GuestRoomPage({ params }: { params: Promise<{ roomId: string }> }) {
  const { roomId } = use(params);
  const { state, error, realtime } = useRoomState(roomId);

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
        <BattleHeader state={state} />
        <Tabs
          tabs={[
            { key: "battle", label: "⚔ 전투", content: <BattleTab state={state} /> },
            {
              key: "chat",
              label: "💬 채팅",
              content: (
                <Card title="채팅">
                  <SystemEventList events={state.events} empty="아직 메시지가 없습니다." />
                  <div style={{ marginTop: 12 }}>
                    <Placeholder stage={6}>
                      참가자·관리자 일반 채팅 입력은 6단계에서 추가됩니다. 지금은 적군 등장 같은 시스템 메시지만 표시됩니다.
                    </Placeholder>
                  </div>
                </Card>
              ),
            },
          ]}
        />
        {state.viewer === "guest" && <LeaveButton state={state} />}
      </main>
    </>
  );
}

function BattleHeader({ state }: { state: RoomState }) {
  const alive = state.players.filter((p) => p.status === "alive").length;
  const aliveEnemies = state.enemies.filter((e) => e.appearance_status === "appeared" && e.status === "alive").length;
  const waiting = state.room.status === "waiting";
  return (
    <div className="battle-header">
      <div className="stat"><span>사이클</span><b>{waiting ? "-" : state.room.current_cycle}</b></div>
      <div className="stat"><span>현재 단계</span><b>{waiting ? "전투 대기 중" : "-"}</b></div>
      <div className="stat timer"><span>남은 시간</span><b>--:--</b></div>
      <div className="stat"><span>생존 플레이어 / 적군</span><b>{alive}명 / {aliveEnemies}</b></div>
    </div>
  );
}

function BattleTab({ state }: { state: RoomState }) {
  const me = state.me?.player as FullPlayer | null | undefined;
  return (
    <div className="grid-2">
      <div className="stack">
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
        <Card title="행동 선택">
          <div className="grid-2" style={{ gap: 8 }}>
            {["일반 공격", "회피", "아이템 사용", "도망"].map((a) => (
              <button key={a} className="btn btn-block" disabled>
                {a}
              </button>
            ))}
          </div>
          <p className="small muted" style={{ marginTop: 8 }}>
            {state.room.status === "waiting" ? "전투가 시작되면 행동할 수 있습니다." : ""} (행동 제출은 4단계에서 구현 예정)
          </p>
        </Card>
      </div>
      <div className="stack">
        <EnemyCards enemies={state.enemies} />
        <Card title={`플레이어 (${state.players.length}명)`}>
          <ul className="list">
            {state.players.map((p) => (
              <li key={p.id} className="list-item">
                <div className="grow">
                  <div className="row">
                    <b>{p.display_name}</b>
                    {p.id === me?.id && <span className="badge">나</span>}
                    <span className={`badge badge-${p.status}`}>{PLAYER_STATUS_LABEL[p.status]}</span>
                  </div>
                  <div style={{ marginTop: 6 }}>
                    <HpBar current={p.current_hp} max={p.max_hp} compact />
                  </div>
                </div>
              </li>
            ))}
          </ul>
        </Card>
        <Card title="시스템 메시지">
          <SystemEventList events={state.events} />
        </Card>
        <Card title="전투 로그">
          <Placeholder stage={5}>사이클별 [턴 + 반응턴] 결과가 표시됩니다.</Placeholder>
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
