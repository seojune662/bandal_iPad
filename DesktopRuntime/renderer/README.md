# Original desktop renderer on iPad

The app loads `bandal-app://shell/index.html`. `bootstrap.ts` installs only the
WK native transport and platform compatibility functions, then dynamically imports
the **unchanged desktop `src/renderer/src/main.tsx`**. React, Dockview, all settings,
logos, original CSS, themes and Pretendard font subsets come from that source.
No web-demo adapter, example AI, mock dataset or rewritten product UI is used.
The desktop guided tour's original PDF asset is included because its source
imports that file, not as user data or a replacement application.

From the repository root:

```sh
# Refresh only deliberately when adopting a reviewed desktop revision.
node DesktopRuntime/scripts/snapshot-upstream.mjs /path/to/bandal
node DesktopRuntime/scripts/verify-snapshot.mjs /path/to/bandal

# Reproducible standalone install. If node_modules is an adjacent-desktop
# symlink created by the build, remove that symlink before installing locally.
pnpm --dir DesktopRuntime install --frozen-lockfile
node DesktopRuntime/scripts/build.mjs
node DesktopRuntime/scripts/test-renderer.mjs
```

The build may reuse the adjacent desktop's installed dependencies if no local
installation exists. `BANDAL_DESKTOP_SOURCE` selects another source checkout for
this fallback and optionally enables comparison against it in the tests.
The checked-in package and lock describe an independent install; no Electron
process or Node native speech/database module is shipped in the renderer.

`upstream/manifest.json` records SHA-256 and length for each copied file plus the
source revision. The build fails if copied source has been modified. Native
platform code belongs outside `upstream`. Backend shims are in `../backend`.

Native contract:

- JS request: `window.webkit.messageHandlers.bandal.postMessage({channel, request})`.
- `WKScriptMessageHandlerWithReply` resolves the actual response or rejects on failure.
- Native event: `window.__bandalReceive(channel, payload)`.
- A JSON object containing only `__bandalBytes: base64` revives to `Uint8Array`.
- `runtime:diagnostic` records unexpected errors. A visible error panel explains
  startup/uncaught failures rather than leaving a blank screen.
- `window.bandal.platform` is `ipad`; `window:openSettings` opens the existing
  React settings overlay through the native `ui:openSettings` event.
- File input changes and external file drops are intercepted before React,
  staged through the native begin/write/finish/cancel contract in 256 KiB
  chunks, then replayed only after the native `{path}` reply. The original
  synchronous `pathForFile` reads that path from `window.__bandalFilePaths`.
  Stale selections and failed writes are not replayed; custom drop payloads
  are retained. Native leases keep temporary files until their consuming
  repository call finishes, and retain failed imports for retry.

External websites must use separate WKWebViews without this privileged app
bridge. Missing features must report an actual unsupported/error state; this
transport never invents empty lists or successful operations.
