"use client";
// 브라우저용 Supabase 클라이언트 (publishable key — 공개되어도 RLS로 보호됨)
import { createClient, type Session, type SupabaseClient } from "@supabase/supabase-js";

let client: SupabaseClient | null = null;

export function isSupabaseConfigured() {
  return Boolean(process.env.NEXT_PUBLIC_SUPABASE_URL && process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY);
}

export function supabaseBrowser(): SupabaseClient {
  if (client) return client;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) {
    throw new Error("Supabase 환경 변수가 설정되지 않았습니다. (.env.local 확인)");
  }
  client = createClient(url, key, {
    auth: { persistSession: true, autoRefreshToken: true, storageKey: "battle-arena-auth" },
  });
  return client;
}

let pending: Promise<Session> | null = null;

/**
 * 익명 로그인 세션을 보장합니다.
 * - 처음 방문: Supabase 익명 사용자 생성 → 브라우저(localStorage)에 저장
 * - 새로고침/재접속: 저장된 세션을 그대로 사용 → 같은 사용자로 복구
 */
export async function ensureSession(): Promise<Session> {
  const sb = supabaseBrowser();
  const { data } = await sb.auth.getSession();
  if (data.session) return data.session;
  if (!pending) {
    pending = (async () => {
      const { data: signed, error } = await sb.auth.signInAnonymously();
      if (error || !signed.session) {
        throw new Error(
          "익명 로그인에 실패했습니다. Supabase 대시보드 > Authentication > Sign In / Providers 에서 " +
            "'Allow anonymous sign-ins' 를 켰는지 확인하세요. (" + (error?.message ?? "no session") + ")",
        );
      }
      return signed.session;
    })().finally(() => {
      pending = null;
    });
  }
  return pending;
}
