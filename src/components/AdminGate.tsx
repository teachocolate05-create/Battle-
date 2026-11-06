"use client";
// 관리자 전용 화면 감싸기: 관리자가 아니면 관리자 로그인 화면으로 안내
// (실제 권한 검사는 서버 API 가 매번 다시 함 — 이 컴포넌트는 안내용)
import { useEffect, useState, type ReactNode } from "react";
import Link from "next/link";
import { api, errorMessage } from "@/lib/apiClient";
import type { MeResponse } from "@/lib/types";
import { Card, ErrorBox } from "@/components/ui";

export function AdminGate({ children }: { children: ReactNode }) {
  const [me, setMe] = useState<MeResponse | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    api<MeResponse>("/api/auth/me").then(setMe).catch((e) => setError(errorMessage(e)));
  }, []);
  if (error) return <main className="page page-narrow"><ErrorBox>{error}</ErrorBox></main>;
  if (!me) return <main className="page"><p className="muted">불러오는 중…</p></main>;
  if (!me.isAdmin) {
    return (
      <main className="page page-narrow">
        <Card title="관리자 전용">
          <p className="muted">전투 기록 보관함은 관리자만 볼 수 있습니다.</p>
          <p style={{ marginTop: 12 }}><Link className="btn btn-primary" href="/admin">관리자 코드 입력</Link></p>
        </Card>
      </main>
    );
  }
  return <>{children}</>;
}
