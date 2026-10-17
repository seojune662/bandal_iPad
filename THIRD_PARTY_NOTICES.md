# Third-party components

The current iPad application uses SwiftUI, UIKit, PDFKit, Metal and Swift storage/services. The former React/Dockview application, JavaScriptCore backend, npm dependencies, PDF.js assets and bundled Noto/Pretendard fonts are no longer part of this tree or app bundle.

- **Bandal code and icon:** MIT; see [LICENSE](LICENSE).
- **perfect-freehand legacy ink geometry:** the Swift port preserves the MIT attribution to Steve Ruiz (2021). The complete notice is retained in [NativePDFLegacyInk-LICENSE.txt](App/Native/Storage/NativePDFLegacyInk-LICENSE.txt) and in the bundled [native resource notices](App/Resources/DesktopNative/THIRD_PARTY_LICENSES.md). This port reproduces existing unversioned strokes; it does not require the npm package at runtime.
- **Mozilla Readability / Arc90 readability.js:** Apache-2.0. The bundled `article-extraction.js` includes the copyright notice and article extraction implementation. See [Readability-LICENSE](App/Resources/DesktopNative/Readability-LICENSE) and the [Readability source](https://github.com/mozilla/readability). The other two bundled scripts, `browser-agent.js` and `web-pip.js`, are Bandal browser integration code under the repository MIT license. These scripts operate on web content inside WebKit.
- **sherpa-onnx 1.13.8:** Apache-2.0, pinned in [project.yml](project.yml); see [upstream source and licenses](https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8). Its native package includes ONNX Runtime with upstream license notices. Downloaded package notices must accompany redistributed native components.
- **On-device speech models:** downloaded separately, with revision, size and SHA-256 pinned in [LocalSpeech.swift](App/Recording/LocalSpeech.swift). No model binaries are bundled in this repository; each model retains its own upstream terms.
- **Offline dictionary:** source attribution and complete CC BY-SA 4.0 and WordNet 3.0 license texts are included in [App/Resources/Dictionary](App/Resources/Dictionary/) and the application bundle. Sources are Princeton WordNet 3.0 and English Wiktionary via kaikki.org/wiktextract; see [UPSTREAM-ATTRIBUTION.txt](App/Resources/Dictionary/UPSTREAM-ATTRIBUTION.txt).
- **SwiftMath 1.7.3:** MIT; the native Markdown math renderer uses this Swift package. See [SwiftMath-LICENSE.txt](App/Resources/DesktopNative/SwiftMath-LICENSE.txt). Its unmodified mathFonts.bundle includes its font license notices, including the GUST Font License.
- **Apple frameworks:** supplied by the operating system and SDK.

The bundled [resource notices](App/Resources/DesktopNative/THIRD_PARTY_LICENSES.md) also retain the earlier Orca design acknowledgement as historical attribution. It does not identify an active Orca runtime dependency.

The optional Python PowerPoint conversion service and Supabase schema in `backend/` run separately from the iPad app. Their deployment dependencies are documented alongside those services.

API provider keys, account sessions, browser cookies, user documents and downloaded speech model binaries are not committed to this repository.
