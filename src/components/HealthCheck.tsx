"use client";
// 1단계 확인용: 서버 환경 변수 / DB 연결 / 익명 로그인 상태를 보여줍니다.
import { useEffect, useState } from "react";
import { ensureSession, isSupabaseConfigured } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/apiClient";

interface Health {
  ok: boolean;
  env: Record<string, boolean>;
  db: { ok: boolean; message: string };
}

export function HealthCheck() {
  const [health, setHealth] = useState<Health | null>(null);
  const [auth, setAuth] = useState<{ ok: boolean; message: string } | null>(null);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    fetch("/api/health", { cache: "no-store" })
      .then((r) => r.json())
      .then(setHealth)
      .catch(() => setHealth(null));
    if (!isSupabaseConfigured()) {
      setAuth({ ok: false, message: "브라우저용 Supabase 환경 변수가 없습니다." });
      return;
    }
    ensureSession()
      .then(() => setAuth({ ok: true, message: "익명 로그인 정상" }))
      .catch((e) => setAuth({ ok: false, message: errorMessage(e) }));
  }, []);

  const allOk = health?.ok && auth?.ok;
  if (allOk && !open) {
    return (
      <button className="btn btn-ghost btn-small" onClick={() => setOpen(true)}>
        ✅ 서버 연결 정상 (자세히)
      </button>
    );
  }
  return (
    <div className={`alert ${allOk ? "alert-ok" : "alert-info"}`}>
      <b>연결 상태 점검</b>
      {!health && <p>서버 확인 중…</p>}
      {health && (
        <ul className="small" style={{ margin: "6px 0", paddingLeft: 18 }}>
          {Object.entries(health.env).map(([k, v]) => (
            <li key={k}>
              {v ? "✅" : "❌"} {k} {v ? "" : "— .env.local 에 값이 없습니다"}
            </li>
          ))}
          <li>
            {health.db.ok ? "✅" : "❌"} {health.db.message}
          </li>
          {auth && (
            <li>
              {auth.ok ? "✅" : "❌"} {auth.message}
            </li>
          )}
        </ul>
      )}
    </div>
  );
}
