"use client";
// 관리자 3단계 패널: 플레이어 능력치 / 적군 관리 / 아이템 관리 / 선공 측 설정
import { useEffect, useMemo, useState, type FormEvent, type ReactNode } from "react";
import { api, errorMessage } from "@/lib/apiClient";
import type { Enemy, EnemyTargetType, FullPlayer, Item, ItemType, RoomState } from "@/lib/types";
import { ENEMY_TARGET_LABEL, enemyStateLabel, ITEM_TYPE_LABEL, PLAYER_STATUS_LABEL, TURN_DURATIONS } from "@/lib/types";
import { Card, ErrorBox, formatDuration, formatTime, HpBar } from "@/components/ui";

/** 참가 중인 플레이어만 (퇴장/강퇴 제외) */
function activePlayers(state: RoomState): FullPlayer[] {
  const ids = new Set(state.members.filter((m) => m.status === "active").map((m) => m.id));
  return state.players.filter((p) => ids.has(p.member_id)) as FullPlayer[];
}

/** 버튼 클릭 → API 호출 → 오류 표시 → 성공 시 새로고침 */
function useAction(onDone: () => void) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setError("");
    try {
      await fn();
      onDone();
      return true;
    } catch (e) {
      setError(errorMessage(e));
      return false;
    } finally {
      setBusy(false);
    }
  };
  return { busy, error, run, setError };
}

function NumField({ label, value, onChange, disabled, min = 0, max, suffix }: {
  label: string; value: string; onChange: (v: string) => void; disabled?: boolean; min?: number; max?: number; suffix?: string;
}) {
  return (
    <label>
      {label}
      {suffix ? ` (${suffix})` : ""}
      <input type="number" inputMode="numeric" value={value} min={min} max={max} disabled={disabled}
        onChange={(e) => onChange(e.target.value)} />
    </label>
  );
}

// =====================================================================
// 3. 플레이어 능력치
// =====================================================================
const PLAYER_FIELDS = ["display_name", "max_hp", "current_hp", "min_attack", "max_attack", "dodge_rate", "escape_rate"] as const;
type PlayerForm = Record<(typeof PLAYER_FIELDS)[number], string>;
const toPlayerForm = (p: FullPlayer): PlayerForm =>
  Object.fromEntries(PLAYER_FIELDS.map((k) => [k, String(p[k])])) as PlayerForm;

export function PlayerStatsPanel({ state, onChanged }: { state: RoomState; onChanged: () => void }) {
  const players = activePlayers(state);
  return (
    <Card title="플레이어 능력치 설정">
      <p className="small muted" style={{ marginBottom: 12 }}>
        {state.room.status === "waiting"
          ? "전투 시작 전에는 모든 능력치를 설정할 수 있습니다. HP 변경은 전투 로그에 기록됩니다."
          : "전투 중에는 현재 HP만 조정할 수 있습니다. (다른 능력치 수정은 2차 업데이트)"}
      </p>
      {players.length === 0 && <p className="muted">참가자가 없습니다.</p>}
      <div className="stack">
        {players.map((p) => (
          <PlayerEditor key={p.id} player={p} state={state} onChanged={onChanged} />
        ))}
      </div>
    </Card>
  );
}

function PlayerEditor({ player, state, onChanged }: { player: FullPlayer; state: RoomState; onChanged: () => void }) {
  const [form, setForm] = useState<PlayerForm>(() => toPlayerForm(player));
  const [dirty, setDirty] = useState(false);
  const [reason, setReason] = useState("");
  const { busy, error, run } = useAction(onChanged);
  const locked = state.room.status !== "waiting";
  const ended = state.room.status === "ended";

  // 다른 곳에서 값이 바뀌면(전투 판정 등) 수정 중이 아닐 때 자동 반영
  const serverKey = PLAYER_FIELDS.map((k) => player[k]).join("|");
  useEffect(() => {
    if (!dirty) setForm(toPlayerForm(player));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverKey]);

  const set = (k: keyof PlayerForm) => (v: string) => {
    setForm((f) => ({ ...f, [k]: v }));
    setDirty(true);
  };

  const save = async (e: FormEvent) => {
    e.preventDefault();
    const ok = locked
      ? await run(() => api(`/api/rooms/${state.room.id}/players/${player.id}/hp`, { method: "POST", body: { hp: Number(form.current_hp), reason } }))
      : await run(() => api(`/api/rooms/${state.room.id}/players/${player.id}`, { method: "PATCH", body: form }));
    if (ok) {
      setDirty(false);
      setReason("");
    }
  };

  const quickHp = (delta: number) => {
    const next = Math.max(0, Math.min(player.max_hp, player.current_hp + delta));
    void run(() => api(`/api/rooms/${state.room.id}/players/${player.id}/hp`, { method: "POST", body: { hp: next, reason } }));
  };

  return (
    <form className="list-item" style={{ display: "block" }} onSubmit={save}>
      <div className="row between" style={{ marginBottom: 8 }}>
        <div className="row">
          <b>{player.display_name}</b>
          <span className={`badge badge-${player.status}`}>{PLAYER_STATUS_LABEL[player.status]}</span>
        </div>
        <div style={{ minWidth: 180, flex: "0 1 260px" }}>
          <HpBar current={player.current_hp} max={player.max_hp} compact />
        </div>
      </div>
      <div className="form-grid">
        <label>
          플레이어 이름
          <input value={form.display_name} maxLength={20} disabled={locked} onChange={(e) => set("display_name")(e.target.value)} />
        </label>
        <NumField label="최대 HP" value={form.max_hp} onChange={set("max_hp")} disabled={locked} min={1} />
        <NumField label="현재 HP" value={form.current_hp} onChange={set("current_hp")} disabled={ended} />
        <NumField label="최소 공격력" value={form.min_attack} onChange={set("min_attack")} disabled={locked} />
        <NumField label="최대 공격력" value={form.max_attack} onChange={set("max_attack")} disabled={locked} />
        <NumField label="회피 성공률" suffix="%" value={form.dodge_rate} onChange={set("dodge_rate")} disabled={locked} max={100} />
        <NumField label="도주 성공률" suffix="%" value={form.escape_rate} onChange={set("escape_rate")} disabled={locked} max={100} />
        {locked && !ended && (
          <label>
            HP 조정 사유 (선택)
            <input value={reason} maxLength={100} onChange={(e) => setReason(e.target.value)} placeholder="예: 함정 피해" />
          </label>
        )}
      </div>
      <ErrorBox>{error}</ErrorBox>
      {!ended && (
        <div className="row" style={{ marginTop: 10 }}>
          <button className="btn btn-primary btn-small" disabled={busy || !dirty}>
            {locked ? "현재 HP 적용" : "저장"}
          </button>
          {dirty && (
            <button type="button" className="btn btn-small btn-ghost" onClick={() => { setForm(toPlayerForm(player)); setDirty(false); }}>
              변경 취소
            </button>
          )}
          <span className="muted small">빠른 HP 조정</span>
          {[-10, -1, +1, +10].map((d) => (
            <button key={d} type="button" className="btn btn-small" disabled={busy} onClick={() => quickHp(d)}>
              {d > 0 ? `+${d}` : d}
            </button>
          ))}
          <button type="button" className="btn btn-small" disabled={busy} onClick={() => quickHp(player.max_hp)}>
            최대
          </button>
        </div>
      )}
    </form>
  );
}

// =====================================================================
// 4. 적군 관리
// =====================================================================
type EnemyForm = {
  name: string; description: string; max_hp: string; current_hp: string; min_attack: string; max_attack: string;
  dodge_rate: string; defense: string; target_type: EnemyTargetType; target_player_id: string; appearance_message: string;
};
const EMPTY_ENEMY: EnemyForm = {
  name: "", description: "", max_hp: "100", current_hp: "", min_attack: "1", max_attack: "4",
  dodge_rate: "0", defense: "0", target_type: "random", target_player_id: "", appearance_message: "",
};
const toEnemyForm = (e: Enemy): EnemyForm => ({
  name: e.name, description: e.description, max_hp: String(e.max_hp), current_hp: String(e.current_hp),
  min_attack: String(e.min_attack), max_attack: String(e.max_attack), dodge_rate: String(e.dodge_rate),
  defense: String(e.defense), target_type: e.target_type, target_player_id: e.target_player_id ?? "",
  appearance_message: e.appearance_message,
});

export function EnemiesPanel({ state, onChanged }: { state: RoomState; onChanged: () => void }) {
  const [creating, setCreating] = useState(false);
  const ended = state.room.status === "ended";
  const count = state.enemies.length;
  const sorted = useMemo(
    () => [...state.enemies].sort((a, b) => (a.appearance_order ?? 99) - (b.appearance_order ?? 99) || a.created_at.localeCompare(b.created_at)),
    [state.enemies],
  );
  return (
    <div className="stack">
      <Card
        title={`적군 관리 (${count}/5)`}
        actions={!ended && !creating && (
          <button className="btn btn-primary btn-small" disabled={count >= 5} onClick={() => setCreating(true)}>
            + 적군 등록
          </button>
        )}
      >
        <p className="small muted">
          등록한 적군은 <b>자동으로 등장하지 않습니다.</b> 채팅으로 스토리를 진행하다가 원하는 순간에 <b>[등장시키기]</b>를 누르세요.
          등장 전에는 참가자 화면에 보이지 않고, 공격하거나 공격받지 않습니다.
        </p>
        {count >= 5 && <p className="small muted">최대 5명까지 등록할 수 있습니다.</p>}
        {creating && (
          <div style={{ marginTop: 12 }}>
            <EnemyEditor state={state} onCancel={() => setCreating(false)} onSaved={() => { setCreating(false); onChanged(); }} />
          </div>
        )}
        {count === 0 && !creating && <p className="muted" style={{ marginTop: 12 }}>등록된 적군이 없습니다.</p>}
      </Card>
      {sorted.map((e) => (
        <EnemyAdminCard key={e.id} enemy={e} state={state} onChanged={onChanged} />
      ))}
    </div>
  );
}

function EnemyAdminCard({ enemy, state, onChanged }: { enemy: Enemy; state: RoomState; onChanged: () => void }) {
  const [editing, setEditing] = useState(false);
  const { busy, error, run } = useAction(onChanged);
  const ended = state.room.status === "ended";
  const label = enemyStateLabel(enemy);
  const target =
    enemy.target_type === "specific"
      ? `특정: ${state.players.find((p) => p.id === enemy.target_player_id)?.display_name ?? "(없음)"}`
      : ENEMY_TARGET_LABEL[enemy.target_type];
  const defaultMsg = `${enemy.name}${hasBatchim(enemy.name) ? "이" : "가"} 등장했다!`;

  const appear = () => {
    if (!confirm(`'${enemy.name}'을(를) 지금 등장시킬까요?\n참가자 화면과 채팅에 등장 메시지가 표시되고, 바로 전투에 참여합니다.`)) return;
    void run(() => api(`/api/rooms/${state.room.id}/enemies/${enemy.id}/appear`, { method: "POST" }));
  };
  const remove = () => {
    if (!confirm(`'${enemy.name}'을(를) 삭제할까요?`)) return;
    void run(() => api(`/api/rooms/${state.room.id}/enemies/${enemy.id}`, { method: "DELETE" }));
  };

  return (
    <section className={`card enemy-admin enemy-${enemy.status === "dead" ? "dead" : enemy.appearance_status}`}>
      <div className="card-head">
        <div className="row">
          {enemy.appearance_order && <span className="badge">#{enemy.appearance_order}</span>}
          <h2>{enemy.name}</h2>
          <span className={`badge enemy-state-${enemy.status === "dead" ? "dead" : enemy.appearance_status}`}>{label}</span>
        </div>
        <div className="card-actions">
          {enemy.appearance_status === "registered" && !ended && (
            <button className="btn btn-primary" disabled={busy} onClick={appear}>
              ⚡ 등장시키기
            </button>
          )}
          {!ended && enemy.status !== "dead" && !editing && (
            <button className="btn btn-small" onClick={() => setEditing(true)}>수정</button>
          )}
          {enemy.appearance_status === "registered" && !ended && (
            <button className="btn btn-small btn-danger" disabled={busy} onClick={remove}>삭제</button>
          )}
        </div>
      </div>
      <ErrorBox>{error}</ErrorBox>
      {editing ? (
        <EnemyEditor state={state} enemy={enemy} onCancel={() => setEditing(false)} onSaved={() => { setEditing(false); onChanged(); }} />
      ) : (
        <>
          <HpBar current={enemy.current_hp} max={enemy.max_hp} />
          {enemy.description && <p className="muted" style={{ marginTop: 8 }}>{enemy.description}</p>}
          <div className="small muted" style={{ marginTop: 8 }}>
            공격력 {enemy.min_attack}~{enemy.max_attack} · 회피율 {enemy.dodge_rate}% · 방어력 {enemy.defense} · 공격 대상: {target}
          </div>
          <div className="system-msg small" style={{ marginTop: 8 }}>
            등장 문구: {enemy.appearance_message || <span className="muted">(기본) {defaultMsg}</span>}
          </div>
          {enemy.appeared_at && (
            <div className="small muted" style={{ marginTop: 6 }}>
              등장 시각 {formatTime(enemy.appeared_at)}
            </div>
          )}
        </>
      )}
    </section>
  );
}

function hasBatchim(word: string) {
  const c = word.charCodeAt(word.length - 1);
  return c >= 0xac00 && c <= 0xd7a3 && (c - 0xac00) % 28 !== 0;
}

function EnemyEditor({ state, enemy, onCancel, onSaved }: {
  state: RoomState; enemy?: Enemy; onCancel: () => void; onSaved: () => void;
}) {
  const [form, setForm] = useState<EnemyForm>(() => (enemy ? toEnemyForm(enemy) : EMPTY_ENEMY));
  const { busy, error, run } = useAction(onSaved);
  const set = (k: keyof EnemyForm) => (v: string) => setForm((f) => ({ ...f, [k]: v }));
  const players = activePlayers(state);
  const appeared = enemy?.appearance_status === "appeared";

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const body = { ...form, current_hp: form.current_hp === "" ? undefined : form.current_hp };
    void run(() =>
      enemy
        ? api(`/api/rooms/${state.room.id}/enemies/${enemy.id}`, { method: "PATCH", body })
        : api(`/api/rooms/${state.room.id}/enemies`, { method: "POST", body }),
    );
  };

  return (
    <form className="stack" onSubmit={submit}>
      <div className="form-grid">
        <label>
          적군 이름
          <input value={form.name} maxLength={30} required onChange={(e) => set("name")(e.target.value)} placeholder="예: 나무 허수아비" />
        </label>
        <NumField label="최대 HP" value={form.max_hp} onChange={set("max_hp")} min={1} />
        <NumField label={enemy ? "현재 HP" : "현재 HP (비우면 최대 HP)"} value={form.current_hp} onChange={set("current_hp")} min={1} />
        <NumField label="최소 공격력" value={form.min_attack} onChange={set("min_attack")} />
        <NumField label="최대 공격력" value={form.max_attack} onChange={set("max_attack")} />
        <NumField label="회피율" suffix="%" value={form.dodge_rate} onChange={set("dodge_rate")} max={100} />
        <NumField label="방어력" value={form.defense} onChange={set("defense")} />
        <label>
          공격 대상 방식
          <select value={form.target_type} onChange={(e) => set("target_type")(e.target.value)}>
            {(Object.keys(ENEMY_TARGET_LABEL) as EnemyTargetType[]).map((t) => (
              <option key={t} value={t}>{ENEMY_TARGET_LABEL[t]}</option>
            ))}
          </select>
        </label>
        {form.target_type === "specific" && (
          <label>
            공격할 플레이어
            <select value={form.target_player_id} onChange={(e) => set("target_player_id")(e.target.value)}>
              <option value="">선택하세요</option>
              {players.map((p) => (
                <option key={p.id} value={p.id}>{p.display_name}</option>
              ))}
            </select>
          </label>
        )}
      </div>
      <label>
        적군 설명
        <textarea value={form.description} maxLength={500} onChange={(e) => set("description")(e.target.value)} />
      </label>
      {!appeared && (
        <label>
          등장 문구 (비우면 &quot;[이름]이/가 등장했다!&quot;)
          <input value={form.appearance_message} maxLength={300} onChange={(e) => set("appearance_message")(e.target.value)}
            placeholder="예: 어둠 속에서 거대한 그림자가 모습을 드러냈다." />
        </label>
      )}
      {form.target_type === "specific" && (
        <p className="small muted">지정한 플레이어가 사망하거나 도주하면 생존한 플레이어 중 무작위 1명을 공격합니다.</p>
      )}
      <ErrorBox>{error}</ErrorBox>
      <div className="row">
        <button className="btn btn-primary" disabled={busy}>{enemy ? "수정 저장" : "적군 등록"}</button>
        <button type="button" className="btn btn-ghost" onClick={onCancel}>취소</button>
      </div>
    </form>
  );
}

// =====================================================================
// 5. 아이템 관리
// =====================================================================
export function ItemsPanel({ state, onChanged }: { state: RoomState; onChanged: () => void }) {
  const ended = state.room.status === "ended";
  const players = activePlayers(state);
  return (
    <div className="stack">
      {!ended && <CreateItemForm state={state} onChanged={onChanged} />}
      <Card title={`아이템 목록 (${state.items.length})`}>
        {state.items.length === 0 && <p className="muted">만든 아이템이 없습니다.</p>}
        <ul className="list">
          {state.items.map((it) => (
            <ItemRow key={it.id} item={it} state={state} players={players} onChanged={onChanged} />
          ))}
        </ul>
      </Card>
      <Card title="플레이어별 보유 아이템">
        {players.length === 0 && <p className="muted">참가자가 없습니다.</p>}
        <ul className="list">
          {players.map((p) => {
            const owned = state.inventory.filter((inv) => inv.player_id === p.id);
            return (
              <li key={p.id} className="list-item">
                <b>{p.display_name}</b>
                <span className="small">
                  {owned.length === 0
                    ? <span className="muted">없음</span>
                    : owned.map((inv) => `${state.items.find((i) => i.id === inv.item_id)?.name ?? "?"} ×${inv.quantity}`).join(", ")}
                </span>
              </li>
            );
          })}
        </ul>
      </Card>
    </div>
  );
}

function CreateItemForm({ state, onChanged }: { state: RoomState; onChanged: () => void }) {
  const [type, setType] = useState<ItemType>("heal");
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [value, setValue] = useState("20");
  const { busy, error, run } = useAction(onChanged);
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    const ok = await run(() =>
      api(`/api/rooms/${state.room.id}/items`, { method: "POST", body: { item_type: type, name, description, effect_value: value } }),
    );
    if (ok) {
      setName("");
      setDescription("");
    }
  };
  return (
    <Card title="아이템 만들기">
      <form className="stack" onSubmit={submit}>
        <div className="form-grid">
          <label>
            종류
            <select value={type} onChange={(e) => setType(e.target.value as ItemType)}>
              <option value="heal">{ITEM_TYPE_LABEL.heal}</option>
              <option value="damage">{ITEM_TYPE_LABEL.damage}</option>
            </select>
          </label>
          <label>
            아이템 이름
            <input value={name} maxLength={30} required onChange={(e) => setName(e.target.value)}
              placeholder={type === "heal" ? "예: 소형 회복약" : "예: 투척 폭탄"} />
          </label>
          <NumField label={type === "heal" ? "회복량" : "피해량"} value={value} onChange={setValue} min={1} />
        </div>
        <label>
          아이템 설명
          <input value={description} maxLength={300} onChange={(e) => setDescription(e.target.value)} />
        </label>
        <p className="small muted">
          {type === "heal" ? "사용한 플레이어의 HP를 회복합니다. (최대 HP를 넘지 않음)" : "선택한 적군에게 고정 피해를 줍니다. (적군의 회피·방어력 무시)"}
        </p>
        <ErrorBox>{error}</ErrorBox>
        <button className="btn btn-primary" disabled={busy}>아이템 생성</button>
      </form>
    </Card>
  );
}

function ItemRow({ item, state, players, onChanged }: { item: Item; state: RoomState; players: FullPlayer[]; onChanged: () => void }) {
  const [playerId, setPlayerId] = useState("");
  const [qty, setQty] = useState("1");
  const [msg, setMsg] = useState("");
  const { busy, error, run } = useAction(onChanged);
  const ended = state.room.status === "ended";

  const grant = async () => {
    setMsg("");
    const name = players.find((p) => p.id === playerId)?.display_name;
    const ok = await run(() =>
      api(`/api/rooms/${state.room.id}/items/${item.id}/grant`, { method: "POST", body: { playerId, quantity: Number(qty) } }),
    );
    if (ok) setMsg(`${name}에게 ${qty}개 지급 완료`);
  };
  const remove = () => {
    if (!confirm(`'${item.name}'을(를) 삭제할까요? 플레이어가 가진 수량도 함께 사라집니다.`)) return;
    void run(() => api(`/api/rooms/${state.room.id}/items/${item.id}`, { method: "DELETE" }));
  };

  return (
    <li className="list-item">
      <div className="grow">
        <div className="row">
          <b>{item.name}</b>
          <span className={`badge item-${item.item_type}`}>{ITEM_TYPE_LABEL[item.item_type]} {item.effect_value}</span>
        </div>
        {item.description && <div className="small muted">{item.description}</div>}
        <ErrorBox>{error}</ErrorBox>
        {msg && <div className="small" style={{ color: "var(--ok)" }}>{msg}</div>}
      </div>
      {!ended && (
        <div className="row">
          <select value={playerId} onChange={(e) => setPlayerId(e.target.value)} aria-label="지급할 플레이어">
            <option value="">플레이어 선택</option>
            {players.map((p) => (
              <option key={p.id} value={p.id}>{p.display_name}</option>
            ))}
          </select>
          <input type="number" min={1} max={99} value={qty} onChange={(e) => setQty(e.target.value)} style={{ width: 72 }} aria-label="수량" />
          <button className="btn btn-small btn-primary" disabled={busy || !playerId} onClick={grant}>지급</button>
          {state.room.status === "waiting" && (
            <button className="btn btn-small btn-danger" disabled={busy} onClick={remove}>삭제</button>
          )}
        </div>
      )}
    </li>
  );
}

// =====================================================================
// 6. 선공 측 설정
// =====================================================================
export function FirstSidePanel({ state, onChanged }: { state: RoomState; onChanged: () => void }) {
  const [side, setSide] = useState(state.room.first_side ?? "");
  const [turn, setTurn] = useState(state.room.turn_duration);
  const { busy, error, run } = useAction(onChanged);
  const locked = state.room.status !== "waiting";
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    setSide(state.room.first_side ?? "");
    setTurn(state.room.turn_duration);
  }, [state.room.first_side, state.room.turn_duration]);

  const save = async () => {
    setSaved(false);
    if (await run(() => api(`/api/rooms/${state.room.id}/settings`, { method: "PATCH", body: { first_side: side, turn_duration: turn } }))) {
      setSaved(true);
    }
  };

  const Option = ({ value, title, children }: { value: string; title: string; children: ReactNode }) => (
    <label className={`choice ${side === value ? "choice-on" : ""}`}>
      <input type="radio" name="first_side" value={value} checked={side === value} disabled={locked} onChange={() => setSide(value)} />
      <b>{title}</b>
      <span className="small muted">{children}</span>
    </label>
  );

  return (
    <Card title="선공 측 / 턴 제한 시간">
      <div className="stack">
        <div className="grid-2" style={{ gap: 12 }}>
          <Option value="players" title="플레이어 측 선공">
            ① 플레이어 선공턴 → ② 적군 반응턴 → ③ 적군 후공턴 → ④ 플레이어 반응턴
          </Option>
          <Option value="enemies" title="적군 측 선공">
            ① 적군 선공턴 → ② 플레이어 반응턴 → ③ 플레이어 후공턴 → ④ 적군 반응턴
          </Option>
        </div>
        <label style={{ maxWidth: 240 }}>
          턴 제한 시간 (플레이어 단계)
          <select value={turn} disabled={locked} onChange={(e) => setTurn(Number(e.target.value))}>
            {TURN_DURATIONS.map((s) => (
              <option key={s} value={s}>{formatDuration(s)}</option>
            ))}
          </select>
        </label>
        <ErrorBox>{error}</ErrorBox>
        {locked ? (
          <p className="small muted">전투가 시작된 뒤에는 바꿀 수 없습니다.</p>
        ) : (
          <div className="row">
            <button className="btn btn-primary" disabled={busy || !side} onClick={save}>저장</button>
            {!side && <span className="small muted">선공 측을 선택하세요. (전투 시작 전 필수)</span>}
            {saved && <span className="small" style={{ color: "var(--ok)" }}>저장되었습니다.</span>}
          </div>
        )}
      </div>
    </Card>
  );
}
