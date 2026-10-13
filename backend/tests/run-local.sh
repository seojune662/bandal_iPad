#!/bin/sh
set -eu
test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime=$(mktemp -d "$test_root/.postgres-test.XXXXXX")
cleanup() {
  pg_ctl -D "$runtime/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$runtime"
}
trap cleanup EXIT INT TERM
initdb -D "$runtime/data" -A trust -U bandal_test >/dev/null
mkdir "$runtime/socket"
pg_ctl -D "$runtime/data" -l "$runtime/log" -o "-k $runtime/socket -h '' -p 54583" -w start >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -h "$runtime/socket" -p 54583 -U bandal_test -d postgres \
  -f "$test_root/tests/fixture.sql" \
  -f "$test_root/supabase/migrations/202610130001_personal_sync.sql" \
  -f "$test_root/tests/sync.sql"
