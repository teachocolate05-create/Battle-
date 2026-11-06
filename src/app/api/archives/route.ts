// 관리자: 전투 기록 보관함 목록 (최신순)
import { handle, toApiError } from "@/lib/api";
import { requireAdmin } from "@/lib/auth";
import { supabaseAdmin } from "@/lib/supabase/admin";
import type { ArchiveSummary } from "@/lib/types";

export async function GET(req: Request) {
  return handle(async () => {
    await requireAdmin(req);
    const { data, error } = await supabaseAdmin()
      .from("battle_archives")
      .select(
        "id, room_id, room_name_snapshot, started_at, ended_at, result, first_side, created_at, " +
          "players:archive_data->players, battle_results(total_cycles, duration_seconds)",
      )
      .order("created_at", { ascending: false })
      .limit(500);
    if (error) throw toApiError(error);
    type Row = Omit<ArchiveSummary, "total_cycles" | "duration_seconds" | "player_count"> & {
      players: unknown[] | null;
      battle_results: { total_cycles: number; duration_seconds: number } | null;
    };
    const archives: ArchiveSummary[] = ((data ?? []) as unknown as Row[]).map(({ players, battle_results, ...r }) => ({
      ...r,
      player_count: players?.length ?? 0,
      total_cycles: battle_results?.total_cycles ?? 0,
      duration_seconds: battle_results?.duration_seconds ?? 0,
    }));
    return { archives };
  });
}
