// 서버: 요청한 사용자 확인 + 관리자 확인
import "server-only";
import { supabaseAdmin } from "./supabase/admin";
import { ApiError } from "./api";

export interface RequestUser {
  id: string;
}

/** Authorization: Bearer <token> 을 Supabase Auth 서버에서 검증 */
export async function getRequestUser(req: Request): Promise<RequestUser | null> {
  const header = req.headers.get("authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!token) return null;
  const { data, error } = await supabaseAdmin().auth.getUser(token);
  if (error || !data.user) return null;
  return { id: data.user.id };
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
