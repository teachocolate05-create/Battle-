"use client";
// v2: 플레이어 프로필 / 이름 색상
//  - NameTag: 이름을 그 사람의 색으로 표시 (채팅, 전투 로그, 목록 등 모든 곳에서 공통 사용)
//  - colorizeNames: 전투 로그 문장 안의 캐릭터 이름에 색을 입힘
//  - ProfileEditor: 참가자 본인(대기 중) / 관리자(언제든) 공통 편집 폼
import { Fragment, useEffect, useMemo, useState, type FormEvent, type ReactNode } from "react";
import { api, errorMessage } from "@/lib/apiClient";
import type { ProfileField, ProfileHistoryEntry, PublicPlayer, RoomState } from "@/lib/types";
import { isReadableNameColor, NAME_COLOR_PALETTE, PROFILE_FIELD_LABEL } from "@/lib/types";
import { ErrorBox, formatTime } from "@/components/ui";

export function NameTag({ name, color, admin }: { name: string; color?: string | null; admin?: boolean }) {
  return (
    <b className={`name-tag ${admin ? "name-admin" : ""}`} style={color ? { color } : undefined}>
      {name}
    </b>
  );
}

/** 문장 속 캐릭터 이름을 각자의 색으로 표시 (긴 이름부터 찾아서 겹침 방지) */
export function useColorizer(players: Pick<PublicPlayer, "display_name" | "name_color">[]) {
  return useMemo(() => {
    const list = players
      .filter((p) => p.display_name)
      .sort((a, b) => b.display_name.length - a.display_name.length);
    if (list.length === 0) return (text: string): ReactNode => text;
    const colors = new Map(list.map((p) => [p.display_name, p.name_color]));
    const re = new RegExp(`(${list.map((p) => p.display_name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})`, "g");
    return (text: string): ReactNode =>
      text.split(re).map((part, i) =>
        colors.has(part) ? <NameTag key={i} name={part} color={colors.get(part)} /> : <Fragment key={i}>{part}</Fragment>,
      );
  }, [players]);
}

export function ColorPicker({ value, onChange, disabled }: { value: string; onChange: (v: string) => void; disabled?: boolean }) {
  const readable = isReadableNameColor(value);
  return (
    <div className="stack" style={{ gap: 8 }}>
      <div className="color-palette" role="radiogroup" aria-label="이름 색상">
        {NAME_COLOR_PALETTE.map((c) => (
          <button
            key={c}
            type="button"
            role="radio"
            aria-checked={value.toLowerCase() === c}
            aria-label={c}
            className={`swatch ${value.toLowerCase() === c ? "swatch-on" : ""}`}
            style={{ background: c }}
            disabled={disabled}
            onClick={() => onChange(c)}
          />
        ))}
        <label className="swatch swatch-custom" title="직접 고르기">
          <input type="color" value={value} disabled={disabled} onChange={(e) => onChange(e.target.value)} aria-label="색상 직접 고르기" />
          🎨
        </label>
      </div>
      <div className="color-preview">
        미리보기: <NameTag name="캐릭터 이름" color={value} /> <span className="mono small muted">{value}</span>
        {!readable && <span className="small" style={{ color: "var(--danger)" }}> — 너무 어두워서 읽기 어렵습니다. 더 밝은 색을 고르세요.</span>}
      </div>
    </div>
  );
}

type Form = { display_name: string; bio: string; appearance: string; name_color: string; profile_extra: Record<string, string> };
const toForm = (p: PublicPlayer): Form => ({
  display_name: p.display_name, bio: p.bio ?? "", appearance: p.appearance ?? "",
  name_color: p.name_color, profile_extra: { ...(p.profile_extra ?? {}) },
});

/**
 * 프로필 편집 폼
 *  mode="self": 참가자 본인 (대기 중 + 잠기기 전만)  /  mode="admin": 관리자
 */
export function ProfileEditor({ state, player, mode, onSaved, onCancel }: {
  state: RoomState; player: PublicPlayer; mode: "self" | "admin"; onSaved: () => void; onCancel?: () => void;
}) {
  const [form, setForm] = useState<Form>(() => toForm(player));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [msg, setMsg] = useState("");
  const fields: ProfileField[] = state.room.profile_fields ?? [];
  const key = [player.display_name, player.bio, player.appearance, player.name_color, JSON.stringify(player.profile_extra)].join("|");
  const [dirty, setDirty] = useState(false);
  useEffect(() => {
    if (!dirty) setForm(toForm(player));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  const set = <K extends keyof Form>(k: K, v: Form[K]) => {
    setForm((f) => ({ ...f, [k]: v }));
    setDirty(true);
    setMsg("");
  };

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      const url = mode === "self" ? `/api/rooms/${state.room.id}/profile` : `/api/rooms/${state.room.id}/players/${player.id}/profile`;
      const res = await api<{ changes: Record<string, unknown> }>(url, { method: "PATCH", body: form });
      setDirty(false);
      setMsg(Object.keys(res.changes ?? {}).length ? "저장되었습니다." : "바뀐 내용이 없습니다.");
      onSaved();
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="stack" style={{ gap: 10 }} onSubmit={submit}>
      <label>
        캐릭터 이름 (1~20자)
        <input value={form.display_name} maxLength={20} required onChange={(e) => set("display_name", e.target.value)} />
      </label>
      <div>
        <div className="small muted" style={{ marginBottom: 6 }}>이름 색상 (채팅·전투 로그·목록에 이 색으로 표시)</div>
        <ColorPicker value={form.name_color} onChange={(v) => set("name_color", v)} />
      </div>
      <label>
        캐릭터 소개
        <textarea value={form.bio} maxLength={500} onChange={(e) => set("bio", e.target.value)} placeholder="어떤 캐릭터인가요?" />
      </label>
      <label>
        외형 설명
        <textarea value={form.appearance} maxLength={500} onChange={(e) => set("appearance", e.target.value)} placeholder="생김새, 옷차림, 무기 등" />
      </label>
      {fields.map((f) => (
        <label key={f.key}>
          {f.label}
          <input value={form.profile_extra[f.key] ?? ""} maxLength={200}
            onChange={(e) => set("profile_extra", { ...form.profile_extra, [f.key]: e.target.value })} />
        </label>
      ))}
      <ErrorBox>{error}</ErrorBox>
      {msg && <div className="small" style={{ color: "var(--ok)" }}>{msg}</div>}
      <div className="row">
        <button className="btn btn-primary" disabled={busy || !dirty || !isReadableNameColor(form.name_color)}>
          {busy ? "저장 중…" : "프로필 저장"}
        </button>
        {dirty && (
          <button type="button" className="btn btn-ghost" onClick={() => { setForm(toForm(player)); setDirty(false); }}>되돌리기</button>
        )}
        {onCancel && <button type="button" className="btn btn-ghost" onClick={onCancel}>닫기</button>}
      </div>
      {mode === "self" && (
        <p className="small muted">전투가 시작되면 프로필이 확정되어 더 이상 수정할 수 없습니다. HP·공격력 등 능력치는 관리자가 설정합니다.</p>
      )}
    </form>
  );
}

/** 프로필 보기 (읽기 전용) */
export function ProfileView({ player, fields }: { player: PublicPlayer; fields: ProfileField[] }) {
  const extras = fields.filter((f) => player.profile_extra?.[f.key]);
  if (!player.bio && !player.appearance && extras.length === 0) {
    return <p className="small muted">아직 작성한 프로필이 없습니다.</p>;
  }
  return (
    <dl className="profile-view">
      {player.bio && (<><dt>소개</dt><dd>{player.bio}</dd></>)}
      {player.appearance && (<><dt>외형</dt><dd>{player.appearance}</dd></>)}
      {extras.map((f) => (<Fragment key={f.key}><dt>{f.label}</dt><dd>{player.profile_extra[f.key]}</dd></Fragment>))}
    </dl>
  );
}

/** 관리자: 추가 프로필 항목 설정 */
export function ProfileFieldsEditor({ state, onSaved }: { state: RoomState; onSaved: () => void }) {
  const [rows, setRows] = useState<ProfileField[]>(state.room.profile_fields ?? []);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [msg, setMsg] = useState("");
  const ended = state.room.status === "ended";
  const save = async () => {
    setBusy(true);
    setError("");
    setMsg("");
    try {
      await api(`/api/rooms/${state.room.id}/profile-fields`, { method: "PUT", body: { fields: rows.filter((r) => r.label.trim()) } });
      setMsg("저장되었습니다.");
      onSaved();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="stack" style={{ gap: 8 }}>
      <p className="small muted">캐릭터 이름·소개·외형 외에 참가자가 채울 항목을 최대 5개까지 정할 수 있습니다. (예: 나이, 직업, 출신)</p>
      {rows.map((r, i) => (
        <div key={r.key || i} className="row">
          <input value={r.label} maxLength={20} placeholder="항목 이름" disabled={ended} style={{ flex: 1 }}
            onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, label: e.target.value } : x)))} />
          <button type="button" className="btn btn-small btn-danger" disabled={ended} onClick={() => setRows(rows.filter((_, j) => j !== i))}>삭제</button>
        </div>
      ))}
      <div className="row">
        <button type="button" className="btn btn-small" disabled={ended || rows.length >= 5} onClick={() => setRows([...rows, { key: "", label: "" }])}>+ 항목 추가</button>
        <button type="button" className="btn btn-small btn-primary" disabled={ended || busy} onClick={save}>저장</button>
        {msg && <span className="small" style={{ color: "var(--ok)" }}>{msg}</span>}
      </div>
      <ErrorBox>{error}</ErrorBox>
    </div>
  );
}

/** 관리자: 프로필 수정 내역 */
export function ProfileHistoryList({ entries, players }: { entries: ProfileHistoryEntry[]; players: PublicPlayer[] }) {
  if (entries.length === 0) return <p className="small muted">수정 내역이 없습니다.</p>;
  const show = (v: unknown) => (typeof v === "string" ? (v || "(빈칸)") : JSON.stringify(v));
  return (
    <ul className="list">
      {[...entries].reverse().map((h) => {
        const p = players.find((x) => x.id === h.player_id);
        return (
          <li key={h.id} className="list-item" style={{ display: "block" }}>
            <div className="small muted">
              [{formatTime(h.created_at)}] {p ? <NameTag name={p.display_name} color={p.name_color} /> : "?"} ·{" "}
              {h.changed_by === "admin" ? "관리자 수정" : "본인 수정"}
            </div>
            {Object.entries(h.changes).map(([k, v]) => (
              <div key={k} className="small" style={{ overflowWrap: "anywhere" }}>
                {PROFILE_FIELD_LABEL[k] ?? k}: <span className="muted">{show(v.before)}</span> → {show(v.after)}
              </div>
            ))}
          </li>
        );
      })}
    </ul>
  );
}
