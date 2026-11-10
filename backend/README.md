# Personal synchronization backend

`supabase/migrations/202610130001_personal_sync.sql` is a new, isolated Supabase
schema for Bandal iPad and the desktop adapter. It was applied to the existing
`bandal` Supabase project on 2026-10-13 using `supabase db query --linked`.
That direct application did not add an entry to Supabase migration history.
Reconcile that history before using `db push` against the same project; do not
blindly reapply the schema. A new project can use the migration normally.
It depends on Supabase's `auth.users`, `auth.uid()`, and Storage schemas.

Clients call `bandal_push(p_operation)` and `bandal_pull(p_after,p_limit)` with a
user access token and the project's publishable/anon key. Never ship a service
role key. `SupabaseSyncTransport` implements these exact RPCs and immutable asset
upload/download. A database is bound to its first sync account: use a separate
local database and asset directory per user.

Operations are immutable and idempotent. Local updates receive monotonically
increasing optimistic revisions; the server accepts only `baseRevision` matching
the current revision. A conflict preserves the latest local record in the local
conflict store and adopts the remote version. Restoring it creates a new ID.
Deletion is a retained tombstone. Wall-clock timestamps never resolve conflicts.

Change cursors are 64-bit sequence numbers; per-user advisory transaction locks
prevent commit-order gaps. Retain operation receipts, changes and tombstones until
a future acknowledged compaction protocol exists. Do not truncate these tables.

Allowed content kinds are mirrored in `SyncPolicy.allowedKinds`. API keys,
credentials, account sessions, browser cookies and device `workspace` layout are
not allowed. Domain payloads must also avoid embedding secrets; the generic
record store cannot infer whether arbitrary note text contains a password.

Assets live at `bandal-assets/<user UUID>/<SHA-256>`. Upload assets before publishing
a record referring to them, retain local files until confirmed, and use
`AssetStore.ensureAvailable` to download/verify on demand. Storage disallows
overwrite. All received files are checked for byte count and SHA-256 before
becoming available. The bucket accepts files up to 512 MiB; recordings above that
limit must be segmented or the product limit changed explicitly.

`tests/live-rollback.sql` passed against that project in a rolled-back transaction.
Local PostgreSQL tests cover RPC idempotency, conflict/tombstone behavior, anonymous
denial, cross-user RLS isolation and immutable Storage policies. Local Swift tests
exercise durability, retry, conflict handling and asset integrity without credentials.
Full device-to-device transfer and concurrent Storage HTTP uploads remain release
checks. Record payloads remain capped at 4 MiB after base64 decoding.

**Never run `tests/fixture.sql` against a live project.** It creates mock auth and
Storage infrastructure for `tests/run-local.sh`'s disposable PostgreSQL cluster.

## AI metering (1.4.0)

`supabase/migrations/202611060001_ai_metering.sql` adds the server side of the AI that
the iPad app gets from Bandal instead of the user's own keys. Apply it to the live
project with `supabase db query --linked -f …` (same reason as above: the migration
history is not reconciled). Everything is `service_role` only; the app reaches it
through the `ai-proxy` Edge Function, never PostgREST.

- Costs are µ¢ (1 µ¢ = $1e-8), prices are µ¢ per token (= $/MTok × 100) in `ai_models`.
  Models, budgets, task caps, the credit pack amount and the consent version live in
  `ai_models` / `ai_settings`, so they change with SQL and no app build.
- `ai_status(uid)` picks the plan from `ipad_entitlements` (Pro > Plus, unrevoked,
  unexpired); a trial gets the trial budget whatever its plan.
- `ai_begin` refuses a step whose input estimate exceeds what is left (month budget +
  credit) or the task cap; `ai_settle` charges the step at list price, month budget
  first, credit second, and writes `ai_usage_ledger`.
- `ai_grant_credit(source, ref)` pays once per `(source, ref)`; `ai_revoke_credit`
  takes a refunded pack back.

`supabase/functions/ai-proxy` (`verify_jwt = false`, it checks the user JWT itself):

| Route | Purpose |
| --- | --- |
| `GET /config` | enabled models (badge = input price ÷ Auto's), Auto model, usage, consent version |
| `POST /consent` | `{provider, version}` |
| `POST /v1/anthropic`, `/v1/openai` | provider body; headers `X-Bandal-Task` (UUID), `X-Bandal-Kind` |

The relay keeps only known body fields, forces streaming, caps output, turns on
Anthropic prompt caching, streams the provider's bytes through unchanged and appends
`data: {"bandal_usage": {...}}`. Upstream errors are passed on and not charged; a stream
cut off by the client or the network is charged with an estimate. Secrets:
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY` (optional `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`
for a fake upstream in local tests).

Tests: `sh tests/run-local.sh` (SQL) and `cd supabase/functions && deno test`.

## App Store verification (1.4.0)

`202611060002_ipad_store.sql` + Edge Functions `ipad-store` and
`ipad-store-notifications` (both `verify_jwt = false`) keep `ipad_entitlements` current
for the AI plan. JWS are verified with `@apple/app-store-server-library` against Apple's
roots (`_shared/store/certificates.ts`), production first and sandbox when Apple says so.

- `ipad-store` (user JWT): `{action:"sync", transactions:[jws…]}` from
  `Transaction.currentEntitlements`, and `{action:"redeem", transaction: jws}` for the
  credit pack `app.bandal.ipad.credit.pack1` (pays `ai_settings.pack_ucents` once per
  transaction; the app finishes the transaction only after this succeeds).
- Ownership: a purchase made signed in carries the user id as `appAccountToken`; one
  without a token belongs to the first account that syncs it. Another account gets
  `purchase_owned_by_another_account`. Older signatures never overwrite newer ones.
- `ipad-store-notifications` (Apple, `{signedPayload}`): applies every subscription
  notification; DID_FAIL_TO_RENEW/GRACE_PERIOD extends the plan to the grace end,
  DID_RENEW/EXPIRED/GRACE_PERIOD_EXPIRED/REFUND/REVOKE clear grace, a refunded pack
  takes its credit back. Applying is idempotent, so retries are harmless.
- Sandbox (TestFlight/Xcode) purchases are free, so they count only for accounts listed in
  `APPLE_SANDBOX_ALLOWED_USER_IDS` (comma-separated user ids, or `*` for everyone, which
  App Review needs: reviewers buy in the sandbox with their own accounts); others get
  `sandbox_tester_required`. Family-shared copies are ignored (Family Sharing is off).
- A pack refunded before it was redeemed is recorded in `ipad_pack_revocations` and never pays.
- Secrets: `APPLE_APP_ID` (6824053530), `APPLE_SANDBOX_ALLOWED_USER_IDS`. ASC → App Information → App Store Server
  Notifications (V2), production and sandbox URL:
  `https://<project>.supabase.co/functions/v1/ipad-store-notifications`.

## Schools ("set up my school")

`202611100002_schools.sql` + Edge Function `schools` (`verify_jwt = false`). One catalogue for
every account: the 18 schools bundled with the app are seeded as verified (the seed block comes
from `deno run --allow-read scripts/seed-schools.ts`); a school nobody has set up yet is looked
up once by an AI routine and kept, unverified, for everyone after. `service_role` only.

| Route | Purpose |
| --- | --- |
| `GET /search?q=&country=` | no sign-in (onboarding); `{schools: [School]}`, verified first, at most 20 |
| `POST /setup` `{query, country, locale}` | signed in; `{status: "cached" or "found", school}`, or `{status: "not_found"}` |
| `POST /suggest` `{schoolId, links}` | signed in; a student's edits, kept in `school_link_suggestions` for review, never applied |

- Matching: `school_key` is the name in lower case without whitespace or a trailing
  대학교/대학/university/univ; one school per key and country. Aliases are compared without the
  suffix rule, so the bundled alias "대구" (경북대학교) does not answer for "대구대학교".
- `/setup` returns a known school as `cached`, also when an earlier run for the same normalized
  query produced it. Otherwise one AI run: 3 per account per UTC day (`429 RATE_LIMITED`) and 500
  a day for all accounts together (`503`), both constants in `school_setup_begin`.
- The routine (`_shared/schools/routine.ts`) is one Messages API turn on `ai_settings.auto_model`
  with the server tools web search (3 uses) and web fetch (12), at low effort when the Models API
  says the model takes it. Its answer is untrusted: only https links on the homepage's own domain
  survive, each checked with HEAD then GET (public addresses only, redirects not followed). No
  homepage that answers means `not_found`.
- What a run finds is shared, so it is stored unverified (school and links), and under the
  model's name only when the typed name abbreviates it ("서울과기대" → 서울과학기술대학교). Otherwise
  it keeps the typed name: a query written to steer the model cannot end up as another school's
  entry. If a school of the model's name already exists, that one is returned untouched.
- Bandal pays: `ai_begin`/`ai_settle` are not involved. The cost (tokens at `ai_models` prices
  plus $0.01 per search) goes to `school_setup_runs.cost_ucents`. No further request is made once
  a run has cost $0.05; the cost is only known between requests, so the tool limits are what
  bounds a single one.
- Secrets: `ANTHROPIC_API_KEY` (the ai-proxy's). Web search and web fetch must be enabled for
  that organization in the Claude Console.

## Referral ("친구 초대", 1.4.1)

`202611110001_referral.sql` + Edge Function `referral` (`verify_jwt = false`). Every account has
one six-character code (`ABCDEFGHJKMNPQRSTUVWXYZ23456789`: no 0/O, no 1/I/L). An invitee enters
a friend's code once; when the app reports the invitee's first course, both sides get
7,000,000 µ¢ ($0.07) of AI credit through `ai_grant_credit` (source `referral`), which is spent
after the month's budget and never expires. `service_role` only.

| Route | Purpose |
| --- | --- |
| `GET /check?code=` | no sign-in; `{valid}`: whether the code exists, nothing else about it |
| `POST /claim` `{code}` | signed in; `{status: "claimed"}`, also for the same code again. `404 INVALID_CODE`, `409 OWN_CODE`, `409 ALREADY_CLAIMED` |
| `POST /complete` | signed in, no body; `{status: "rewarded", creditMicrocents, referrerRewarded}`, `{status: "none"}` (no claim) or `{status: "already"}` |
| `GET /status` | signed in; `{code, completed, limit, creditMicrocents, claim: {code, completed} or null}`. Makes the account's code the first time |

- The amounts are two functions at the top of the migration, `referral_reward()` and
  `referral_cap()`, so they change with SQL and no app build. The Edge Function decides nothing.
- `/complete` is the app's word that a first course exists; the server cannot check it, and
  accounts are cheap. `referral_daily_grants()` (400, $28) is the most referral grants paid in
  any 24 hours for everyone together. Past it `referral_complete` raises `referral_paused`, the
  function answers 503, the claim stays open and the app's next `/complete` is paid once older
  grants have aged out. Watch `select count(*) from ai_credit_grants where source = 'referral'
  and granted_at > now() - interval '1 day'`.
- The rules go by account: one claim per invitee, never one's own code, and an inviter is paid
  for the first five invitees who complete (later invitees are still paid themselves). No device
  is identified; the tables hold user ids, codes and timestamps.
- The server cannot see courses, so `/complete` is the app's word for "signed in and made a
  first course". A claim can be made before or after that; the app calls `/complete` once both
  are true and may repeat it (`already`).
- Codes come from `gen_random_uuid()` (no extension), and a taken code is drawn again. Typed
  codes are trimmed and upper-cased by the function; anything that is not six characters of the
  alphabet is answered without a query.
- `referral_complete` is one transaction: the claim row is locked, then both accounts' `ai:`
  advisory locks (the ones `ai_grant_credit` takes) with the lower user id first, then the
  inviter's `referral_code.completed` counter is raised, and the nth completion pays the
  inviter when n ≤ 5. The grants are `('referral', 'claim:<claim id>:referee')` and
  `…:referrer` in `ai_credit_grants`, which pays a ref once. Deleting one of the two accounts
  in the same instant can deadlock with it (the cascades lock the other way round): Postgres
  aborts one of the two, nothing is half done, and a retry goes through.
- Account deletion: a code goes with its account; a claim goes with its invitee and outlives
  its inviter (`referrer_id` → null), so the invitee is still paid and cannot be invited twice.
  The counter is on the inviter's code row rather than counted from claims, so deleting invitee
  accounts does not give the five paid places back. Grants belong to their own account.
- `tests/run-local.sh` also runs several sessions at once (the sixth invitee, the same invitee
  twice, two accounts that invited each other, one account's first status twice) and checks
  the outcome with `referral_race.sql`.
