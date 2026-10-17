# Native app resources: licenses and attribution

This folder contains three scripts used only for interactions with web content in WebKit: article extraction, browser element actions, and web video picture-in-picture. The application UI, SQLite storage and service dispatcher are Swift. This folder contains no React/Dockview application, JavaScriptCore backend, npm runtime, PDF.js assets or web UI fonts. SwiftMath supplies its own native math font resource bundle.

## Readability

`article-extraction.js` includes Mozilla Readability, based on Arc90 readability.js, under Apache License 2.0. The source retains its copyright and license header, also preserved in `Readability-LICENSE`.

- Source: <https://github.com/mozilla/readability>
- Copyright (c) 2010 Arc90 Inc.
- License: <https://www.apache.org/licenses/LICENSE-2.0>

## Bandal web integration

`browser-agent.js` and `web-pip.js` are Bandal browser integration code distributed under the repository MIT license, copyright (c) 2026 Bandal contributors. They operate on webpage DOM content and do not host the application UI or storage engine.

## perfect-freehand Swift port

The native legacy ink geometry implementation preserves compatibility with perfect-freehand strokes. Its original notice is also retained beside the Swift source at `App/Native/Storage/NativePDFLegacyInk-LICENSE.txt`.

```text
MIT License

Copyright (c) 2021 Steve Ruiz

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

## Native speech and dictionary resources

The app's Swift package dependency sherpa-onnx 1.13.8 is Apache-2.0 and includes native dependency notices, including ONNX Runtime. Sources and license texts are supplied with that package: <https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8>. Speech models are downloaded separately; they are not bundled in this folder and retain their upstream terms.

The bundled offline dictionary has separate notices in the sibling `Dictionary` folder: `UPSTREAM-ATTRIBUTION.txt`, `LICENSE-CC-BY-SA-4.0.txt`, and `LICENSE-WordNet-3.0.txt`.

## Historical design acknowledgement: Orca

Earlier Bandal desktop design work studied Orca (stablyai/orca, v1.4.169-rc.0). Its patterns and parameters were independently reimplemented; no verbatim Orca code was copied in that work. The earlier TypeScript modules are no longer part of the native app. The original acknowledgement and MIT notice are retained for historical attribution, not as an active runtime dependency.

- Source: <https://github.com/stablyai/orca>
- Copyright (c) 2026 Lovecast Inc.

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

## SwiftMath

SwiftMath 1.7.3 is MIT licensed; see `SwiftMath-LICENSE.txt`. The unmodified package includes mathFonts.bundle with its original font licenses, including GUST-FONT-LICENSE.txt. It typesets Markdown mathematics natively without JavaScript or a web view.
