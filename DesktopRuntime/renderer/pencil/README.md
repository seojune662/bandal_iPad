# iPad input adapter

The desktop source snapshot remains unchanged. `index.mjs` is a Vite transform
that checks exact upstream source anchors before changing `InkLayer`'s input
ownership and sampling. If the desktop implementation changes, the build stops
until those anchors are reviewed. JSX markup, toolbars, styles, shape geometry,
undo history and storage calls remain the original desktop implementation.

- Mouse/trackpad input follows the original handlers.
- Pencil input keeps actual pressure (including zero), every available coalesced
  point and all move events received between animation frames. Predicted points
  never enter saved ink. iPadOS versions without coalesced events use the actual
  pointer event.
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
pinch delivery and interrupted-stroke preservation. The test also compares the
transformed JSX with upstream. Test fixture files are not imported by the app.

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
