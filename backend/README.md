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
