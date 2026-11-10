#!/bin/sh
set -eu
test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime=$(mktemp -d "$test_root/.postgres-test.XXXXXX")
# A Unix socket path may be at most 103 bytes, which a deep checkout (a git worktree) exceeds.
socket=$(mktemp -d /tmp/bandal-pg.XXXXXX)
cleanup() {
  pg_ctl -D "$runtime/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$runtime" "$socket"
}
trap cleanup EXIT INT TERM
initdb -D "$runtime/data" -A trust -U bandal_test -E UTF8 >/dev/null
pg_ctl -D "$runtime/data" -l "$runtime/log" -o "-k $socket -h '' -p 54583" -w start >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -h "$socket" -p 54583 -U bandal_test -d postgres \
  -f "$test_root/tests/fixture.sql" \
  -f "$test_root/supabase/migrations/202610130001_personal_sync.sql" \
  -f "$test_root/tests/sync.sql" \
  -f "$test_root/supabase/migrations/202611060001_ai_metering.sql" \
  -f "$test_root/tests/ai.sql" \
  -f "$test_root/supabase/migrations/202611060002_ipad_store.sql" \
  -f "$test_root/tests/store.sql" \
  -f "$test_root/supabase/migrations/202611100001_ai_google.sql" \
  -f "$test_root/tests/ai_google.sql" \
  -f "$test_root/supabase/migrations/202611100002_schools.sql" \
  -f "$test_root/tests/schools.sql"
