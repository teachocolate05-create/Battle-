"use client";
// 브라우저 → 서버 API 호출 도우미. 로그인 토큰을 자동으로 붙입니다.
import { ensureSession } from "./supabase/client";

export class ApiClientError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export async function api<T>(path: string, options: { method?: string; body?: unknown } = {}): Promise<T> {
  const session = await ensureSession();
  let res: Response;
  try {
    res = await fetch(path, {
      method: options.method ?? "GET",
      headers: {
        Authorization: `Bearer ${session.access_token}`,
        ...(options.body !== undefined ? { "Content-Type": "application/json" } : {}),
      },
      body: options.body !== undefined ? JSON.stringify(options.body) : undefined,
      cache: "no-store",
    });
  } catch {
    throw new ApiClientError(0, "서버에 연결할 수 없습니다. 인터넷 연결을 확인하세요.");
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new ApiClientError(res.status, (data as { error?: string }).error ?? `요청 실패 (${res.status})`);
  }
  return data as T;
}

export function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
