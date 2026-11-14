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
  -f "$test_root/tests/schools.sql" \
  -f "$test_root/supabase/migrations/202611110001_referral.sql" \
  -f "$test_root/tests/referral.sql" \
  -f "$test_root/supabase/migrations/202611140001_ai_decisions.sql" \
  -f "$test_root/tests/ai_decisions.sql"
# Referral from several sessions at once, on what referral.sql left open. The first session
# completes invitee 25, takes account 28's `ai:` lock through a grant of its own, makes account
# 29's code, and keeps its transaction open while the others run into it:
#   - invitee 26 (the same inviter's sixth) and invitee 25 again: the inviter is paid for five
#     and each invitee is counted once;
#   - 28 and then 27, who invited each other: 28 is already waiting when 27 starts, which
#     deadlocks unless both take the two accounts' `ai:` locks in the same order;
#   - account 29 asking for its status a second time: one code, not two and not an error.
export PGHOST="$socket" PGPORT=54583 PGUSER=bandal_test PGDATABASE=postgres
session() { psql -X -q -v ON_ERROR_STOP=1 -c "$1"; }
session "begin; select public.referral_complete(public.test_user(25));
  select public.ai_grant_credit(public.test_user(28), 'manual', 'held during the race', 1);
  select public.referral_status(public.test_user(29));
  select pg_sleep(1.5); commit" & first=$!
sleep 0.5
others=
for n in 28 27 26 25; do
  session "select public.referral_complete(public.test_user($n))" & others="$others $!"
  sleep 0.2
done
session "select public.referral_status(public.test_user(29))" & others="$others $!"
wait "$first"
for other in $others; do wait "$other"; done
psql -X -q -v ON_ERROR_STOP=1 -f "$test_root/tests/referral_race.sql"
