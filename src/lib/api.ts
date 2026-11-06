// 서버 API 공통 도우미: 응답, 오류 처리, DB 함수(RPC) 호출
import "server-only";
import { NextResponse } from "next/server";
import { supabaseAdmin } from "./supabase/admin";

/** 사용자에게 그대로 보여줄 수 있는 오류 */
export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

type PgError = { code?: string; message: string };

/** DB 오류 → 사용자용 오류로 변환. P0001 은 DB 함수가 일부러 낸 한국어 오류입니다. */
export function toApiError(error: PgError): ApiError {
  if (error.code === "P0001") return new ApiError(400, error.message);
  console.error("[DB 오류]", error);
  return new ApiError(500, "서버 처리 중 오류가 발생했습니다. 잠시 후 다시 시도하세요.");
}

/** DB 함수 호출 */
export async function rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabaseAdmin().rpc(fn, args);
  if (error) throw toApiError(error);
  return data as T;
}

/** 라우트 핸들러를 감싸서 오류를 JSON 응답으로 변환 */
export async function handle(fn: () => Promise<unknown>): Promise<NextResponse> {
  try {
    const result = await fn();
    return result instanceof NextResponse ? result : NextResponse.json(result ?? { ok: true });
  } catch (e) {
    if (e instanceof ApiError) return NextResponse.json({ error: e.message }, { status: e.status });
    console.error("[API 오류]", e);
    const msg = e instanceof Error && e.message.includes("환경 변수") ? e.message : "서버 오류가 발생했습니다.";
    return NextResponse.json({ error: msg }, { status: 500 });
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function assertUuid(value: string, label = "ID"): string {
  if (!UUID_RE.test(value)) throw new ApiError(400, `잘못된 ${label}입니다.`);
  return value;
}

export async function readJson<T = Record<string, unknown>>(req: Request): Promise<T> {
  try {
    return (await req.json()) as T;
  } catch {
    throw new ApiError(400, "잘못된 요청 형식입니다.");
  }
}

export function str(v: unknown, fallback = ""): string {
  return typeof v === "string" ? v : fallback;
}

export function int(v: unknown): number | null {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isInteger(n) ? n : null;
}
