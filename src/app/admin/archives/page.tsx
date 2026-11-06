"use client";
// 관리자: 전투 기록 보관함 목록
import { useEffect, useState } from "react";
import Link from "next/link";
import { api, errorMessage } from "@/lib/apiClient";
import type { ArchiveSummary } from "@/lib/types";
import { RESULT_LABEL } from "@/lib/types";
import { AdminGate } from "@/components/AdminGate";
import { Card, ErrorBox, formatDateTime, formatSeconds } from "@/components/ui";

export default function ArchivesPage() {
  return (
    <>
      <header className="topbar">
        <div className="row">
          <Link href="/admin" className="btn btn-small btn-ghost">← 관리자 홈</Link>
          <b>📜 전투 기록 보관함</b>
        </div>
      </header>
      <AdminGate>
        <ArchiveList />
      </AdminGate>
    </>
  );
}

function ArchiveList() {
  const [list, setList] = useState<ArchiveSummary[] | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    api<{ archives: ArchiveSummary[] }>("/api/archives").then((r) => setList(r.archives)).catch((e) => setError(errorMessage(e)));
  }, []);
  return (
    <main className="page stack">
      <Card title={`이전 전투 ${list ? `(${list.length})` : ""}`}>
        <p className="small muted" style={{ marginBottom: 10 }}>
          전투가 끝나면 자동으로 저장됩니다. 전투방을 삭제해도 기록은 남습니다.
        </p>
        <ErrorBox>{error}</ErrorBox>
        {!list && !error && <p className="muted">불러오는 중…</p>}
        {list?.length === 0 && <p className="muted">아직 저장된 전투 기록이 없습니다.</p>}
        <ul className="list">
          {list?.map((a) => (
            <li key={a.id} className="list-item">
              <div className="grow">
                <div className="row">
                  <b>{a.room_name_snapshot}</b>
                  <span className={`badge result-badge-${a.result}`}>{RESULT_LABEL[a.result] ?? a.result}</span>
                </div>
                <div className="small muted">
                  {a.ended_at ? formatDateTime(a.ended_at) : formatDateTime(a.created_at)} · {a.total_cycles}사이클 · 참가 {a.player_count}명 ·
                  소요 {formatSeconds(a.duration_seconds)}
                </div>
              </div>
              <Link className="btn btn-small btn-primary" href={`/admin/archives/${a.id}`}>상세 보기</Link>
            </li>
          ))}
        </ul>
      </Card>
    </main>
  );
}
