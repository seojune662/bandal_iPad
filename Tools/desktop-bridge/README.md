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

This bridge currently projects courses, ordinary material files, Markdown notes,
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
