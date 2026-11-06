#!/usr/bin/env bash
# 로컬 PostgreSQL로 마이그레이션 + 테스트 실행
#   사용법: bash supabase/tests/run_tests.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
DB=battle_test
PSQL="psql -X -q -o /dev/null -v ON_ERROR_STOP=1 -d $DB"
dropdb --if-exists $DB
createdb $DB
$PSQL -f "$DIR/00_local_supabase_stub.sql"
for f in "$DIR"/../migrations/*.sql; do
  echo "▶ migration $(basename "$f")"
  $PSQL -f "$f"
done
for f in "$DIR"/*_test.sql; do
  echo "▶ test $(basename "$f")"
  $PSQL -f "$f"
done
echo "✅ 모든 테스트 통과"
