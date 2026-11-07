"use client";
// 전투 탭 위쪽: 내 캐릭터 정보 (이름·HP·능력치·보유 아이템·프로필)
import { useState } from "react";
import type { FullPlayer, RoomState } from "@/lib/types";
import { ITEM_TYPE_LABEL, PLAYER_STATUS_LABEL } from "@/lib/types";
import { Card, HpBar } from "@/components/ui";
import { NameTag, ProfileEditor, ProfileView } from "@/components/Profile";

export function MyCharacter({ state, onChanged }: { state: RoomState; onChanged: () => void }) {
  const me = state.me?.player as FullPlayer | null | undefined;
  const editable = state.room.status === "waiting" && !me?.profile_locked_at;
  const [editing, setEditing] = useState(false);
  if (!me) return null;
  const owned = state.inventory
    .filter((i) => i.player_id === me.id && i.quantity > 0)
    .map((i) => ({ ...i, item: state.items.find((it) => it.id === i.item_id) }))
    .filter((i) => i.item);

  return (
    <Card
      title={<>내 캐릭터 · <NameTag name={me.display_name} color={me.name_color} /></>}
      actions={editable && !editing && (
        <button className="btn btn-small btn-primary" onClick={() => setEditing(true)}>✏ 프로필 설정</button>
      )}
    >
      {editable && !editing && (
        <div className="alert alert-info small" style={{ marginBottom: 10 }}>
          전투 시작 전입니다. <b>프로필 설정</b>에서 캐릭터 이름·소개·외형·이름 색상을 정하세요. 전투가 시작되면 확정됩니다.
        </div>
      )}
      {editing && editable ? (
        <ProfileEditor state={state} player={me} mode="self" onSaved={onChanged} onCancel={() => setEditing(false)} />
      ) : (
        <>
          <HpBar current={me.current_hp} max={me.max_hp} />
          <div className="stat-grid">
            <div className="stat"><span>공격력</span><b>{me.min_attack} ~ {me.max_attack}</b></div>
            <div className="stat"><span>상태</span><b>{PLAYER_STATUS_LABEL[me.status]}</b></div>
            <div className="stat"><span>회피율</span><b>{me.dodge_rate}%</b></div>
            <div className="stat"><span>도주율</span><b>{me.escape_rate}%</b></div>
          </div>
          <div className="my-items">
            <span className="small muted">보유 아이템</span>
            {owned.length === 0 ? (
              <span className="small muted"> 없음</span>
            ) : (
              <div className="row" style={{ marginTop: 4 }}>
                {owned.map((o) => (
                  <span key={o.item_id} className={`badge item-${o.item!.item_type}`} title={o.item!.description}>
                    {o.item!.name} ×{o.quantity} · {ITEM_TYPE_LABEL[o.item!.item_type]} {o.item!.effect_value}
                  </span>
                ))}
              </div>
            )}
          </div>
          <details className="my-profile">
            <summary className="small">내 프로필 {me.profile_locked_at ? "(확정됨)" : ""}</summary>
            <ProfileView player={me} fields={state.room.profile_fields ?? []} />
          </details>
          <p className="small muted" style={{ marginTop: 6 }}>능력치는 관리자만 수정할 수 있습니다.</p>
        </>
      )}
    </Card>
  );
}
