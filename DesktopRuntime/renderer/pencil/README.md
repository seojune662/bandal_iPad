# iPad input adapter

The v5 shared geometry override is recorded in `upstream/manifest.json` and
`provenance/ink-v5-ipad-override.json`; historical v2–v4 geometry remains unchanged.
`index.mjs` is a Vite transform
that checks exact upstream source anchors before changing `InkLayer`'s input
ownership, sampling and live preview. If the desktop implementation changes,
the build stops until those anchors are reviewed. Toolbars, committed shape
geometry, undo history and storage calls remain the desktop implementation.

- Mouse/trackpad input follows the original handlers.
- Pencil input keeps actual pressure (including zero), every available coalesced
  point and all move events. The preview updates inside the input callback,
  without waiting for an animation frame or React render. iPadOS versions without
  coalesced events use the actual pointer event.
- New strokes use v5, retaining V4's accepted centerline and adding causal
  four-raw-sample pressure/speed response plus localized start/end taper. Pen
  pressure-only repeats share a display anchor; raw pressure/time/tilt remain
  intact. End taper only revisits 16 moving segments, and endpoint windows add
  at most 16 knots per segment. Travel/base factors and the settled serialized
  prefix are cached. Highlighters retain exact V4 geometry and constant width.
  One compound SVG fill covers measured/predicted ink and matches saved v5 geometry.
  WebKit still parses the full path on updates; separate fill/clip chunks caused
  visible coverage seams and are not used. No smoothing rewrites saved data.
- Available browser predictions are shown for at most 24 ms / 8 samples in a
  disposable straight tail with the last measured diameter factor. Predictions
  never act as curve controls for measured ink. They are replaced on every event and removed at stroke end
  or cancellation. Predictions never enter saved ink. There is no synthetic
  extrapolation when the browser does not expose predictions.
- Only the pointer that owns a stroke can move, complete or cancel it. An
  interrupted Pencil stroke commits its measured points; a palm cannot commit
  or discard another pointer's stroke.
- Fingers pan the PDF/whiteboard viewport. Two fingers send pinch changes through
  the existing PDF zoom handler, or resize the existing whiteboard page layout.
  The adapter changes the viewport's `touch-action` input policy without adding
  product UI. A live Pencil suppresses finger navigation until those fingers lift.

Run `node DesktopRuntime/renderer/pencil/test.mjs` from the repository root.
This loads the actual upstream `InkLayer` in WebKit and checks a real mouse
gesture, synthetic coalesced/pressure fixtures, palm ownership, finger pan,
pinch delivery and interrupted-stroke preservation. It also blocks animation
frames during a 640-sample stroke, checks immediate updates without React
commits, verifies stable measured prefixes and exact committed geometry, and
checks prediction removal on moves/cancellation. Full alpha masks at 1×/2×
compare curved/crossing pen and highlighter strokes, including prediction
replacement; full-image comparisons cover the delayed-save handoff. A host CPU benchmark compares
full-prefix and incremental geometry; it is not a physical device latency claim.
Test fixture files are not imported by the app.

`BandalUITests/PencilInputTests` exercises an actual simulator finger drag in the
full original whiteboard UI. XCUITest does not synthesize physical Pencil pressure;
device handwriting, palm rejection, latency and thermal behavior still require
physical iPad acceptance testing.

`persistence.ts` registers the original PDF and whiteboard save queues with the
native lifecycle barrier. Closed tabs remain registered until queued writes and
image preparations finish. Errors block release; edits made while another tab
is flushing require another pass. No storage implementation is replaced.
Run `node DesktopRuntime/renderer/pencil/test-persistence.mjs` for actual PDF-hook
serial IPC, whiteboard preparation, unmount, failed-save and multi-tab races.

`node Scripts/test-ink-v5-quality.mjs --native` checks actual Swift/TypeScript
profile, polygons, prediction tails and every measured prefix against shared
synthetic fixtures. Without `--native` it runs Node-only analytical/compatibility
checks. `node DesktopRuntime/renderer/pencil/test-live-preview.mjs` retains v4
regressions and checks v5 incremental paths without a browser. These checks
measure geometry, not physical Pencil latency or subjective writing quality.
