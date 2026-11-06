// 서버: 요청한 사용자 확인 + 관리자 확인
import "server-only";
import { supabaseAdmin } from "./supabase/admin";
import { ApiError } from "./api";

export interface RequestUser {
  id: string;
}

/**
 * Authorization: Bearer <token> 검증.
 * getClaims 는 서명을 공개키(JWKS, 캐시됨)로 서버에서 직접 확인하므로 매 요청마다 인증 서버를 부르지 않아 빠릅니다.
 * (프로젝트가 구형 대칭키 방식이면 supabase-js 가 자동으로 인증 서버 확인으로 대체합니다)
 */
export async function getRequestUser(req: Request): Promise<RequestUser | null> {
  const header = req.headers.get("authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!token) return null;
  const { data, error } = await supabaseAdmin().auth.getClaims(token);
  const sub = data?.claims?.sub;
  if (error || !sub || data?.claims?.role !== "authenticated") return null;
  return { id: sub };
}

export async function requireUser(req: Request): Promise<RequestUser> {
  const user = await getRequestUser(req);
  if (!user) throw new ApiError(401, "로그인 정보가 없거나 만료되었습니다. 새로고침 후 다시 시도하세요.");
  return user;
}

export async function isAdmin(userId: string): Promise<boolean> {
  const { data, error } = await supabaseAdmin().from("admins").select("user_id").eq("user_id", userId).maybeSingle();
  if (error) throw error;
  return Boolean(data);
}

/** 관리자만 통과. (DB 함수에서도 한 번 더 검사합니다) */
export async function requireAdmin(req: Request): Promise<RequestUser> {
  const user = await requireUser(req);
  if (!(await isAdmin(user.id))) throw new ApiError(403, "관리자 권한이 필요합니다.");
  return user;
}
