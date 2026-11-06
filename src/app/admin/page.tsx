"use client";
// 관리자: 코드 로그인 → 전투방 생성 / 목록 / 삭제
import { useCallback, useEffect, useState, type FormEvent } from "react";
import Link from "next/link";
import { api, errorMessage } from "@/lib/apiClient";
import type { AdminRoomSummary, MeResponse } from "@/lib/types";
import { TURN_DURATIONS } from "@/lib/types";
import { Card, CopyButton, ErrorBox, formatDateTime, formatDuration, Placeholder, StatusBadge } from "@/components/ui";

export default function AdminPage() {
  const [me, setMe] = useState<MeResponse | null>(null);
  const [error, setError] = useState("");

  const loadMe = useCallback(() => {
    api<MeResponse>("/api/auth/me").then(setMe).catch((e) => setError(errorMessage(e)));
  }, []);
  useEffect(loadMe, [loadMe]);

  const logout = async () => {
    await api("/api/auth/admin", { method: "DELETE" }).catch(() => {});
    loadMe();
  };

  return (
    <>
      <header className="topbar">
        <Link href="/" className="brand">⚔ 턴제 전투 아레나</Link>
        <div className="row">
          <span className="badge">관리자</span>
          {me?.isAdmin && (
            <button className="btn btn-small btn-ghost" onClick={logout}>
              관리자 해제
            </button>
          )}
        </div>
      </header>
      <main className="page stack">
        <ErrorBox>{error}</ErrorBox>
        {!me && !error && <p className="muted">불러오는 중…</p>}
        {me && !me.isAdmin && <AdminLogin onDone={loadMe} />}
        {me?.isAdmin && <AdminHome />}
      </main>
    </>
  );
}

function AdminLogin({ onDone }: { onDone: () => void }) {
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      await api("/api/auth/admin", { method: "POST", body: { code } });
      onDone();
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="page-narrow" style={{ margin: "0 auto", width: "100%" }}>
      <Card title="관리자 코드 입력">
        <form className="stack" onSubmit={submit}>
          <p className="small muted">관리자 코드는 서버에서만 확인합니다. 한 번 인증하면 이 브라우저는 관리자 권한을 유지합니다.</p>
          <label>
            관리자 코드
            <input type="password" value={code} onChange={(e) => setCode(e.target.value)} autoComplete="off" />
          </label>
          <ErrorBox>{error}</ErrorBox>
          <button className="btn btn-primary btn-block" disabled={busy || !code}>
            {busy ? "확인 중…" : "관리자 권한으로 전환"}
          </button>
        </form>
      </Card>
    </div>
  );
}

function AdminHome() {
  const [rooms, setRooms] = useState<AdminRoomSummary[] | null>(null);
  const [error, setError] = useState("");
  const load = useCallback(() => {
    api<{ rooms: AdminRoomSummary[] }>("/api/rooms")
      .then((r) => setRooms(r.rooms))
      .catch((e) => setError(errorMessage(e)));
  }, []);
  useEffect(load, [load]);

  const remove = async (room: AdminRoomSummary) => {
    if (!confirm(`'${room.room_name}' 전투방을 삭제할까요?\n(종료된 전투 기록은 보관함에 남습니다)`)) return;
    try {
      await api(`/api/rooms/${room.id}`, { method: "DELETE" });
      load();
    } catch (e) {
      alert(errorMessage(e));
    }
  };

  return (
    <div className="grid-2">
      <CreateRoomForm onCreated={load} />
      <div className="stack">
        <Card title="전투방 목록" actions={<button className="btn btn-small" onClick={load}>새로고침</button>}>
          <ErrorBox>{error}</ErrorBox>
          {!rooms && !error && <p className="muted">불러오는 중…</p>}
          {rooms?.length === 0 && <p className="muted">아직 만든 전투방이 없습니다.</p>}
          <ul className="list">
            {rooms?.map((r) => (
              <li key={r.id} className="list-item">
                <div className="grow">
                  <div className="row">
                    <b>{r.room_name}</b>
                    <StatusBadge status={r.status} />
                    {r.has_password && <span className="badge">🔒 비밀번호</span>}
                  </div>
                  <div className="small muted">
                    코드 <span className="mono">{r.room_code}</span> · 참가 {r.active_members}/{r.max_players}명 · 턴{" "}
                    {formatDuration(r.turn_duration)} · {formatDateTime(r.created_at)}
                  </div>
                </div>
                <div className="row">
                  <CopyButton text={r.room_code} label="코드 복사" />
                  <Link className="btn btn-small btn-primary" href={`/admin/rooms/${r.id}`}>
                    관리
                  </Link>
                  <button className="btn btn-small btn-danger" onClick={() => remove(r)}>
                    삭제
                  </button>
                </div>
              </li>
            ))}
          </ul>
        </Card>
        <Card title="전투 기록 보관함">
          <Placeholder stage={7}>종료된 전투의 로그와 채팅 기록을 다시 볼 수 있는 메뉴입니다.</Placeholder>
        </Card>
      </div>
    </div>
  );
}

function CreateRoomForm({ onCreated }: { onCreated: () => void }) {
  const [roomName, setRoomName] = useState("");
  const [description, setDescription] = useState("");
  const [usePassword, setUsePassword] = useState(false);
  const [password, setPassword] = useState("");
  const [maxPlayers, setMaxPlayers] = useState(10);
  const [turnDuration, setTurnDuration] = useState<number>(180);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [created, setCreated] = useState<{ id: string; room_code: string } | null>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      const res = await api<{ id: string; room_code: string }>("/api/rooms", {
        method: "POST",
        body: { roomName, description, usePassword, password, maxPlayers, turnDuration },
      });
      setCreated(res);
      setRoomName("");
      setDescription("");
      setPassword("");
      onCreated();
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card title="새 전투방 만들기">
      {created && (
        <div className="alert alert-ok stack" style={{ gap: 8, marginBottom: 12 }}>
          <span>전투방이 생성되었습니다. 아래 코드를 참가자에게 공유하세요.</span>
          <div className="row between">
            <span className="room-code mono">{created.room_code}</span>
            <div className="row">
              <CopyButton text={created.room_code} label="코드 복사" />
              <Link className="btn btn-small btn-primary" href={`/admin/rooms/${created.id}`}>
                관리 화면으로
              </Link>
            </div>
          </div>
        </div>
      )}
      <form className="stack" onSubmit={submit}>
        <label>
          전투방 이름
          <input value={roomName} onChange={(e) => setRoomName(e.target.value)} maxLength={50} required />
        </label>
        <label>
          전투방 설명
          <textarea value={description} onChange={(e) => setDescription(e.target.value)} maxLength={500} />
        </label>
        <label className="checkbox">
          <input type="checkbox" checked={usePassword} onChange={(e) => setUsePassword(e.target.checked)} />
          입장 비밀번호 사용
        </label>
        {usePassword && (
          <label>
            입장 비밀번호 (4~50자)
            <input type="text" value={password} onChange={(e) => setPassword(e.target.value)} minLength={4} maxLength={50} autoComplete="off" />
          </label>
        )}
        <div className="grid-2" style={{ gap: 12 }}>
          <label>
            최대 인원 (관리자 제외)
            <select value={maxPlayers} onChange={(e) => setMaxPlayers(Number(e.target.value))}>
              {Array.from({ length: 10 }, (_, i) => i + 1).map((n) => (
                <option key={n} value={n}>
                  {n}명
                </option>
              ))}
            </select>
          </label>
          <label>
            턴 제한 시간
            <select value={turnDuration} onChange={(e) => setTurnDuration(Number(e.target.value))}>
              {TURN_DURATIONS.map((s) => (
                <option key={s} value={s}>
                  {formatDuration(s)}
                </option>
              ))}
            </select>
          </label>
        </div>
        <ErrorBox>{error}</ErrorBox>
        <button className="btn btn-primary btn-block" disabled={busy}>
          {busy ? "생성 중…" : "전투방 생성 + 코드 발급"}
        </button>
      </form>
    </Card>
  );
}
