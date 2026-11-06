"use client";
// 방 상태 실시간 동기화 훅
//  1) 서버 API에서 전체 상태를 받아옴 (권한 필터링은 서버가 담당)
//  2) Supabase Realtime 으로 "이 방 데이터가 바뀌었다" 신호를 받으면 다시 받아옴
//  3) 실시간 연결이 끊겨도 15초마다, 그리고 탭으로 돌아올 때마다 다시 받아옴 (접속 복구)
import { useCallback, useEffect, useRef, useState } from "react";
import { api, ApiClientError, errorMessage } from "./apiClient";
import { ensureSession, supabaseBrowser } from "./supabase/client";
import type { RoomState } from "./types";

// 방 ID(room_id) 컬럼으로 필터링할 테이블들 (단계가 늘어나면 자동으로 함께 구독)
const ROOM_TABLES = [
  "room_members", "players", "enemies", "items", "player_inventory",
  "battle_phases", "phase_submissions", "pending_attacks",
  "battle_logs", "battle_events", "chat_messages",
];

export type RealtimeStatus = "connecting" | "live" | "offline";

export function useRoomState(roomId: string) {
  const [state, setState] = useState<RoomState | null>(null);
  const [error, setError] = useState<{ status: number; message: string } | null>(null);
  const [realtime, setRealtime] = useState<RealtimeStatus>("connecting");
  /** 서버 시각 - 내 기기 시각 (타이머를 서버 기준으로 맞추기 위함) */
  const [clockOffset, setClockOffset] = useState(0);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const loading = useRef(false);
  const again = useRef(false);

  const load = useCallback(async () => {
    if (loading.current) {
      again.current = true; // 진행 중이면 끝난 뒤 한 번 더
      return;
    }
    loading.current = true;
    try {
      const startedAt = Date.now();
      const next = await api<RoomState>(`/api/rooms/${roomId}/state`);
      const rtt = Date.now() - startedAt;
      setClockOffset(new Date(next.serverNow).getTime() + rtt / 2 - Date.now());
      setState(next);
      setError(null);
    } catch (e) {
      const status = e instanceof ApiClientError ? e.status : 0;
      // 일시적 네트워크 오류는 기존 화면 유지, 권한/삭제 오류는 표시
      if (status === 403 || status === 404 || status === 401) setState(null);
      setError({ status, message: errorMessage(e) });
    } finally {
      loading.current = false;
      if (again.current) {
        again.current = false;
        void load();
      }
    }
  }, [roomId]);

  /** 짧은 시간에 변경이 몰려도 한 번만 다시 불러오기 */
  const refresh = useCallback(() => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => void load(), 150);
  }, [load]);

  useEffect(() => {
    let cancelled = false;
    const sb = supabaseBrowser();
    let channel: ReturnType<typeof sb.channel> | null = null;

    (async () => {
      await load();
      try {
        const session = await ensureSession();
        if (cancelled) return;
        await sb.realtime.setAuth(session.access_token);
        channel = sb.channel(`room-${roomId}`);
        channel.on("postgres_changes", { event: "*", schema: "public", table: "rooms", filter: `id=eq.${roomId}` }, refresh);
        for (const table of ROOM_TABLES) {
          channel.on("postgres_changes", { event: "*", schema: "public", table, filter: `room_id=eq.${roomId}` }, refresh);
        }
        channel.subscribe((status) => {
          if (status === "SUBSCRIBED") {
            setRealtime("live");
            refresh(); // 재연결 직후 놓친 변경 반영
          } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT" || status === "CLOSED") {
            setRealtime("offline");
          }
        });
      } catch {
        setRealtime("offline");
      }
    })();

    const poll = setInterval(() => void load(), 15000);
    const onVisible = () => document.visibilityState === "visible" && refresh();
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("online", refresh);

    return () => {
      cancelled = true;
      clearInterval(poll);
      if (timer.current) clearTimeout(timer.current);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("online", refresh);
      if (channel) void sb.removeChannel(channel);
    };
  }, [roomId, load, refresh]);

  return { state, error, realtime, clockOffset, refresh: load };
}
