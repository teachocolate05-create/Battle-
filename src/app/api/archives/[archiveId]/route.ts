// 관리자: 전투 기록 상세 (참가자, 적군, 사이클별 전투 로그, 채팅, 적군 등장 시점)
import { ApiError, assertUuid, handle, toApiError } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";
import { supabaseAdmin } from "@/lib/supabase/admin";

export async function GET(req: Request, { params }: { params: Promise<{ archiveId: string }> }) {
  return handle(async () => {
    await requireAdmin(req);
    const { archiveId } = await params;
    const { data, error } = await supabaseAdmin()
      .from("battle_archives")
      .select("id, room_name_snapshot, result, created_at, archive_data")
      .eq("id", assertUuid(archiveId, "기록 ID"))
      .maybeSingle();
    if (error) throw toApiError(error);
    if (!data) throw new ApiError(404, "전투 기록을 찾을 수 없습니다.");
    return data;
  });
}
