# Desktop continuation bridge

This adapter uses Python 3 standard libraries and the same SQLite record/outbox
schema and Supabase RPCs as `BandalCore`. It reads the desktop application's live
SQLite database in a read snapshot and preserves existing course, material,
drawing, highlight and task IDs. No command has been run against the user's live
desktop database as part of implementation.

## Offline exchange

```sh
python3 Tools/desktop-bridge/bridge.py export --desktop-db /path/to/bandal.db \
  --exchange /path/to/private-staging --pack /path/to/course.bandalpack
python3 Tools/desktop-bridge/bridge.py import --desktop-db /path/to/bandal.db \
  --exchange /path/to/private-staging --pack /path/to/from-ipad.bandalpack \
  --course-root /path/to/new-course-folders
```

The `.bandalpack` is version 1 JSON, shared with `App/Services/Exchange.swift`:
`{format,version,records:[StoredRecord],assets:[{materialID,sha256,byteCount,fileName,data}]}`.
Data fields are base64. Credentials, cookies and workspace layout are excluded.

`--exchange` is persistent, private staging, including outbox receipts, local
conflicts, immutable assets, source baselines, and import recovery backups. Keep
it between runs. Do not place it inside a course folder. Every changed source is
checked against its last baseline before import; unexpected desktop edits stop
the import with both versions preserved. Successful file replacements/deletions
retain their previous bytes under `backups/`. The importer journals file actions
and commits a marker inside the desktop DB transaction for crash recovery.

## Automatic sync

Set `BANDAL_SUPABASE_URL`, `BANDAL_SUPABASE_KEY` (publishable/anon),
`BANDAL_USER_ID`, and `BANDAL_ACCESS_TOKEN` in the process environment, then use
`cycle` for one export/sync/import pass or `watch` for repeated passes. Tokens are
not written to staging and their JWT subject must match the bound account.
`watch` stops on token expiration; the Electron integration gets a fresh session
for each `cycle`. Each user requires a separate staging directory.

## Desktop app integration staging

The current implementation is already applied to the adjacent desktop checkout.
For another clean desktop checkout at `92e998b`, apply **only**
`desktop-current.patch`, which contains the complete verified integration,
including the runtime, packaged helper build and latest merge fixes. Check it
first with `git apply --check`. The older integration/runtime/runner patch files
are development snapshots, not additional steps after the current patch.

```sh
python3 Tools/desktop-bridge/stage_integration.py --desktop /path/to/bandal \
  --output Tools/desktop-bridge/desktop-integration.patch
```

This command **only writes a reviewable patch**. It does not modify the desktop
checkout. The patch adds an iPad application menu with package export/import,
automatic account sync and status; imports use the existing main-process account
session and broadcast material/course/task changes to open views. Existing
drawings already listen for material refresh; the patch also refreshes highlights.

The staged runtime computes PDF geometry with desktop `pdf-lib`, so packaged use
does not need Swift/PDFKit. Standalone macOS CLI export uses `pdf_geometry.swift`
on the first encounter of a PDF; the geometry cache is keyed by its content hash.
`desktop-runtime-delta.patch` follows the original integration patch. Packaged
apps require a bundled one-file executable and do not depend on installed Python.
The release workflow builds PyInstaller 6.16 helpers natively for macOS arm64/x64
and Windows x64, checks source/binary digests before packaging, and includes the
macOS helper in code signing. Developer mode may use `python3`/`python` or
`BANDAL_PYTHON`; `BANDAL_IPAD_BRIDGE_EXECUTABLE` overrides the executable.
The arm64 macOS binary passed an export/import fixture with no Python on PATH.
Windows/x64 CI and notarized installer execution are still release gates.

The desktop profile binds durably to its first sync account before uploading.
Logging into another account cannot upload that profile's existing course data;
use a separate desktop profile. Switching automatic sync off retains the binding.

## Compatibility and validation

PDF display-space coordinates are migrated using actual CropBox and rotation;
the reverse conversion restores desktop coordinates and page-width stroke size.
Unknown drawing kinds/JSON fields and unknown database columns are preserved.
Unsupported future ink versions stop import. Source PDF revisions cannot silently
receive another revision's ink. Concurrent page edits merge distinct stroke IDs;
same-ID edits and ambiguous delete/edit races retain a conflict instead.

When run without the Electron projector environment, the legacy Python-only CLI
fallback covers courses, ordinary material files, Markdown notes,
PDF drawings/highlights and course tasks. Other desktop tables (personal boards,
recording sessions, conversation/learning history) are left untouched and are not
claimed to have an equivalent desktop projection yet. Unrecognized content
records received from iPad remain durably stored in staging.
Recording assets use the shared `recording:<UUID>` package identifier and retain
their validated `Recordings/<UUID>.wav` path. They transfer through packages and
account sync, but are not yet projected into desktop recording-session UI tables.
iPad folder/page-note relations and unknown Material payload fields are preserved
in staging; desktop folder presentation is not inferred from these fields.
Packages are capped at 64 MiB raw assets and 100 MiB encoded JSON, matching iPad.

Run `python3 -m unittest discover -s Tools/desktop-bridge -p 'test_*.py' -v` for
fixture roundtrips. The tests never connect to the live desktop DB or cloud.

## Shared desktop TypeScript projector

The new iPad architecture runs the unchanged desktop repositories in JavaScriptCore.
`projector-host.cjs` runs the same bundled projection code on the desktop through
the app's Electron binary (`ELECTRON_RUN_AS_NODE=1`) and its own `better-sqlite3`
binding. It does not load an incompatible system-Node SQLite addon. The Python
bridge continues to own the existing transport, account binding, cursor, outbox,
operation receipts and immutable asset directory.

Before a network exchange or package import changes staging records, a durable
`pending_projection` marker is recorded. On restart, the bridge obtains missing
assets and materializes those accepted records before another local export or
push. An interrupted download/import cannot turn old desktop bytes into a newer
remote edit. Existing staging databases reconcile once when this recovery version
is installed. Unresolved records remain excluded from local export until the user
chooses a conflict version; replaying historical conflicts does not reopen a
resolution. The legacy fallback stops on a conflicting edit and retains the marker.

The new projection covers courses/groups, materials, Markdown notes, PDF ink and
highlights, personal whiteboards, tasks, completed recordings with transcripts and
anchors, conversations/messages, favorites, and learning project files. Learning
state, article snapshots, quiz/review result files and generated artifacts are
content-addressed assets, so a large learning state does not have to fit in the
4 MiB per-record limit. Import pauses the original learning runtime, validates the
original manifest/state, and publishes state last. Settings, API keys, auth tokens,
cookies, device layout, CLI execution state and tool grants are not synchronized.
Unknown canonical fields and unprojected record kinds remain in the local cache.

The first run seeds original stable IDs from `desktop_map`, captures pending local
edits using the legacy mapping, and drains legacy imports before recording the
`typescript-projector-v1` handoff. It keeps prior outbox operation IDs, remote cursor
and `_bandal_bridge_commits` receipts. Subsequent file-index rebuilding restores IDs
from the canonical mapping instead of assigning a second identity to the file.

File changes and SQL projection use a recovery journal. Distinct ink object IDs
merge; concurrent edits to one object are retained as conflicts. A restore made
after additional local edits creates another visible conflict containing those
newer edits. Binary conflict assets are hash-verified and retained separately.
Remote recording deletion currently becomes a durable conflict rather than
removing original audio; this is an explicit remaining projection limitation.

The shared projector integration has been applied to the adjacent desktop
checkout. Its four files were checked against the staged previous hashes before
application and verified against the resulting hashes afterward. Unrelated desktop
changes were preserved. The arm64 packaged Python helper was rebuilt and passed
export/import with Python absent from PATH; the desktop main-process type check
also passed. These are local checks, not a released desktop update.

`staged-projector/` retains the review bundle. To prepare an update against the
current adjacent checkout:

```sh
node DesktopRuntime/backend/build-backend.mjs
python3 Tools/desktop-bridge/stage_projector.py --desktop /path/to/bandal \
  --output Tools/desktop-bridge/staged-projector
```

Review `desktop-projector.patch` and `manifest.json`. The generated backend is a
separate content-addressed file, deliberately omitted from the readable patch.
The readable patch can be empty when only that generated backend changed.
Before applying, compare each existing file to `previousSHA256`; after applying
the patch and copying `resources/ipad-bridge/backend.js`, verify all target hashes.
Rebuild the packaged Python helper whenever `bridge.py` changes. Existing desktop
packaging includes the entire `resources/ipad-bridge` directory and checks the
helper source/binary hashes; do not ship the old helper with the new script.

The native projector fixture uses a temporary copy of a generated desktop DB:

```sh
node DesktopRuntime/backend/test-backend.mjs --pdf --projector
node DesktopRuntime/backend/test-backend.mjs --legacy --sync
node DesktopRuntime/backend/test-streams.mjs
```

It verifies old IDs, outbox operations, cursor, migration receipts, original 37
schema migrations, remote note imports, intervening desktop edits, recording/learning
assets, and the actual Electron SQLite ABI. No production DB or cloud account is
used by these fixtures. Release installers and a physical two-device account
roundtrip remain separate acceptance checks.
