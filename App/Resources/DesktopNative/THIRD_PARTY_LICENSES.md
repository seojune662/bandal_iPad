# Third-Party Licenses & Attributions

## Orca (stablyai/orca)

- Source: <https://github.com/stablyai/orca>
- License: MIT
- Copyright (c) 2026 Lovecast Inc.

Bandal's design was informed by a study of the Orca codebase
(analysis notes: `docs/orca-analysis.md`, clone reviewed at
v1.4.169-rc.0). The following Bandal modules follow Orca **patterns and
parameters** — each was re-implemented from scratch in this repository;
**no verbatim Orca code was copied**:

| Bandal file | Orca inspiration |
|---|---|
| `src/main/features/agent/claude/modelProbe.ts` | `src/shared/claude-model-list-probe.ts` — `list_models` control_request probe with static fallback (re-implemented against the verified CLI 2.1.222 wire format) |
| `src/main/features/agent/eventBatcher.ts` | `src/main/ipc/native-chat.ts` — 40ms debounce / 250ms max-wait batching parameters |
| `src/main/features/browser/webviewPolicy.ts`, `hardenWebviews.ts` | hardened-`<webview>` recipe (fail-closed `will-attach-webview`, `will-navigate` + `will-redirect` guards, `setWindowOpenHandler` forwarding) |
| `src/renderer/src/stores/workspaceStore.ts`, `features/workspace/layoutPersistence.ts` | explicit ordered hydration + structural-diff save subscriber (no zustand persist) |
| `src/renderer/src/features/pdf/lib/scrollMemory.ts` | `PdfViewer.tsx` scroll-position LRU cache idea |
| `src/renderer/src/features/workspace/NewTabMenu.tsx` | typed "+"-omnibox tab-create menu concept |
| `src/renderer/src/features/onboarding/**` (wizard versioning, live preflight probes, dismissible preflight cards) | `use-onboarding-flow.ts`, `setup-guide/use-setup-guide-progress.ts`, `Landing.tsx` + `landing-preflight-issues.ts` |
| `docs/STYLEGUIDE.md` | `docs/STYLEGUIDE.md` document structure (role/anti-role token tables) |

Because these are independent re-implementations of ideas and
parameters, the MIT notice below is included for transparency and as a
good-faith attribution rather than as a strict license obligation. If
any Orca code is ever ported verbatim in the future, this notice (or a
file header) MUST be kept alongside it.

### MIT License (stablyai/orca)

```
MIT License

Copyright (c) 2026 Lovecast Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## SheetJS CE (vendored package)

- Version: 0.20.3
- Source: <https://cdn.sheetjs.com/xlsx-0.20.3/xlsx-0.20.3.tgz>
- License: Apache-2.0

The upstream tarball is shipped unmodified at `vendor/xlsx-0.20.3.tgz`; its
Apache-2.0 license text is included in the archive as `package/LICENSE`.

---

## Noto Sans KR (bundled font)

- Source: <https://github.com/notofonts/noto-cjk> (`Sans/SubsetOTF/KR/NotoSansKR-Regular.otf`)
- License: SIL Open Font License 1.1
- Copyright: Copyright 2014-2021 Adobe (http://www.adobe.com/), with Reserved
  Font Name 'Source'. Noto is a trademark of Google Inc.

Shipped **unmodified** at `resources/fonts/NotoSansKR-Regular.otf` and packaged
into `<Resources>/fonts/`. It is embedded (subset) into exported PDFs by
`src/main/features/pdf/exportPdf.ts`: pdf-lib's built-in Helvetica is
WinAnsi-only, so without a Unicode font every Hangul glyph in a text-box
annotation would export as `?`.

The OFL permits bundling and embedding. The full license text ships with the
font upstream and is reproduced at
<https://openfontlicense.org/open-font-license-official-text/>. Note the OFL's
Reserved Font Name clause: the file must not be redistributed under a modified
name, and this repository does not modify it.

---

Runtime npm dependencies (React, zustand, dockview, Milkdown, pdf.js,
better-sqlite3, chokidar, immer, uuid, react-pdf) are used unmodified
under their respective licenses; see `node_modules/<pkg>/LICENSE` and
the lockfile for exact versions. This file tracks only attributions that
are not already covered by standard package metadata.
