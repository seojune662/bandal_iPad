# Third-party components

- Bandal desktop components and icon: MIT; see `LICENSE` and `WebEditor/DESKTOP-THIRD-PARTY-LICENSES.md`.
- React, Milkdown/ProseMirror, Vite, Mammoth, JSZip, SheetJS and Silurus OOXML: exact versions are pinned in `WebEditor/pnpm-lock.yaml`; upstream licenses remain in installed packages. Review their bundled distribution notices before App Store submission.
- sherpa-onnx 1.13.8: Apache-2.0, https://github.com/k2-fsa/sherpa-onnx . The package includes ONNX Runtime under its upstream license.
- On-device speech models: separately downloaded, revision/size/hash pinned in `App/Recording/LocalSpeech.swift`; verify each model's redistribution terms before bundling models in a store release.
- Offline dictionary: source attribution and complete CC BY-SA 4.0 and WordNet license texts are included in `App/Resources/Dictionary/` and the application bundle.
- Apple frameworks are supplied by the operating system/SDK.

API provider keys, Supabase sessions, browser cookies, user documents and downloaded speech model binaries are not committed to this repository.
