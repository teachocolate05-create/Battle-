"use client";
// 홈: 게스트 입장 화면 + 참여 중인 방 복구 + 연결 상태 확인
import { useEffect, useState, type FormEvent } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { api, errorMessage } from "@/lib/apiClient";
import { isSupabaseConfigured } from "@/lib/supabase/client";
import type { MeResponse } from "@/lib/types";
import { ROOM_STATUS_LABEL } from "@/lib/types";
import { Card, ErrorBox } from "@/components/ui";
import { HealthCheck } from "@/components/HealthCheck";

export default function HomePage() {
  const router = useRouter();
  const [nickname, setNickname] = useState("");
  const [code, setCode] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [me, setMe] = useState<MeResponse | null>(null);

  useEffect(() => {
    if (!isSupabaseConfigured()) return;
    api<MeResponse>("/api/auth/me").then(setMe).catch((e) => setError(errorMessage(e)));
  }, []);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setError("");
    if (!nickname.trim()) return setError("닉네임을 입력하세요.");
    if (!code.trim()) return setError("방 코드를 입력하세요.");
    setBusy(true);
    try {
      const res = await api<{ room_id: string }>("/api/rooms/join", {
        method: "POST",
        body: { nickname: nickname.trim(), code: code.trim(), password },
      });
      router.push(`/room/${res.room_id}`);
    } catch (err) {
      setError(errorMessage(err));
      setBusy(false);
    }
  };

  return (
    <>
      <header className="topbar">
        <span className="brand">⚔ 턴제 전투 아레나</span>
        <Link className="btn btn-small btn-ghost" href="/admin">
          관리자 모드
        </Link>
      </header>
      <main className="page page-narrow stack">
        <h1>전투방 입장</h1>

        {me && me.rooms.length > 0 && (
          <Card title="참여 중인 전투방">
            <ul className="list">
              {me.rooms.map((r) => (
                <li key={r.room_id} className="list-item">
                  <div className="grow">
                    <b>{r.room_name}</b>
                    <div className="small muted">
                      {r.nickname} · {ROOM_STATUS_LABEL[r.status]}
                    </div>
                  </div>
                  <Link className="btn btn-primary btn-small" href={`/room/${r.room_id}`}>
                    돌아가기
                  </Link>
                </li>
              ))}
            </ul>
          </Card>
        )}

        <Card>
          <form className="stack" onSubmit={submit}>
            <label>
              닉네임
              <input value={nickname} onChange={(e) => setNickname(e.target.value)} maxLength={20} placeholder="1~20자" autoComplete="nickname" />
            </label>
            <label>
              방 코드
              <input
                className="mono"
                value={code}
                onChange={(e) => setCode(e.target.value.toUpperCase())}
                maxLength={6}
                placeholder="예: AB12CD"
                autoCapitalize="characters"
                autoComplete="off"
              />
            </label>
            <label>
              비밀번호 <span className="small">(비밀번호가 설정된 방만)</span>
              <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} maxLength={50} autoComplete="off" />
            </label>
            <ErrorBox>{error}</ErrorBox>
            <button className="btn btn-primary btn-block" disabled={busy}>
              {busy ? "입장 중…" : "입장하기"}
            </button>
          </form>
        </Card>

        <HealthCheck />
      </main>
    </>
  );
}
