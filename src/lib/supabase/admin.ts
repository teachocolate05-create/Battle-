// 서버 전용 Supabase 클라이언트 (secret key 사용 — RLS를 우회하므로 브라우저에서 절대 사용 금지)
// "server-only" 덕분에 브라우저 코드에서 import 하면 빌드가 실패합니다.
import "server-only";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

let cached: SupabaseClient | null = null;

export function getServerEnvStatus() {
  return {
    NEXT_PUBLIC_SUPABASE_URL: Boolean(process.env.NEXT_PUBLIC_SUPABASE_URL),
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: Boolean(process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY),
    SUPABASE_SECRET_KEY: Boolean(process.env.SUPABASE_SECRET_KEY),
    ADMIN_CODE: Boolean(process.env.ADMIN_CODE),
  };
}

export function supabaseAdmin(): SupabaseClient {
  if (cached) return cached;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) {
    throw new Error(
      "서버 환경 변수 NEXT_PUBLIC_SUPABASE_URL 또는 SUPABASE_SECRET_KEY 가 설정되지 않았습니다. .env.local 을 확인하세요.",
    );
  }
  cached = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  return cached;
}
