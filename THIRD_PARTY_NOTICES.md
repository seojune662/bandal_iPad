# Third-party components

- Bandal desktop components and icon: MIT; see `LICENSE` and `WebEditor/DESKTOP-THIRD-PARTY-LICENSES.md`.
- The original desktop renderer and repository snapshot is recorded in `DesktopRuntime/upstream/manifest.json`. React, Dockview, Milkdown/ProseMirror, Vite, PDF.js, pdf-lib, perfect-freehand, Mammoth, JSZip, SheetJS and Silurus OOXML versions are pinned in `DesktopRuntime/pnpm-lock.yaml`; upstream licenses remain in installed packages. The earlier standalone editor is retained under `WebEditor` for history, but is not the application entry point.
- Original desktop and Noto Sans KR PDF font notices are preserved in `DesktopRuntime/assets/PDF/THIRD_PARTY_LICENSES.md` and copied into the app at build time. Pretendard font subsets are bundled from the desktop dependency. Review distribution notices before App Store submission.
- PDF.js 5.4.296 CMaps, standard fonts and WebAssembly decoders are bundled locally under `Desktop/pdfjs`. The build copies the package Apache-2.0 `LICENSE`, Adobe `cmaps/LICENSE`, Foxit/PDFium and Liberation font notices, and decoder notices from `wasm/` alongside the exact assets; `pdfjs/manifest.json` verifies every distributed file.
- sherpa-onnx 1.13.8: Apache-2.0, https://github.com/k2-fsa/sherpa-onnx . The package includes ONNX Runtime under its upstream license.
- On-device speech models: separately downloaded, revision/size/hash pinned in `App/Recording/LocalSpeech.swift`; verify each model's redistribution terms before bundling models in a store release.
- Offline dictionary: source attribution and complete CC BY-SA 4.0 and WordNet license texts are included in `App/Resources/Dictionary/` and the application bundle.
- Apple frameworks are supplied by the operating system/SDK.

API provider keys, Supabase sessions, browser cookies, user documents and downloaded speech model binaries are not committed to this repository.
