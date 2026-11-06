// 1단계 확인용: 환경 변수와 DB 연결 상태 점검 (비밀 값 자체는 절대 응답하지 않음)
import { NextResponse } from "next/server";
import { getServerEnvStatus, supabaseAdmin } from "@/lib/supabase/admin";

export const dynamic = "force-dynamic";

export async function GET() {
  const env = getServerEnvStatus();
  let db: { ok: boolean; message: string } = { ok: false, message: "환경 변수가 없어 확인하지 않았습니다." };
  if (env.NEXT_PUBLIC_SUPABASE_URL && env.SUPABASE_SECRET_KEY) {
    try {
      const { error } = await supabaseAdmin().from("rooms").select("id", { head: true, count: "exact" });
      db = error
        ? {
            ok: false,
            message:
              error.code === "42P01" || error.message.includes("does not exist")
                ? "rooms 테이블이 없습니다. 001_schema.sql 을 실행했는지 확인하세요."
                : `DB 오류: ${error.message}`,
          }
        : { ok: true, message: "데이터베이스 연결 정상" };
    } catch (e) {
      db = { ok: false, message: e instanceof Error ? e.message : String(e) };
    }
  }
  const ok = Object.values(env).every(Boolean) && db.ok;
  return NextResponse.json({ ok, env, db });
}
