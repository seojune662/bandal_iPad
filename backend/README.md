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
