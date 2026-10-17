> **Historical / 과거 구현 기록** — 이전 빌드의 구현·검증 기록이며, 삭제된 웹 UI·JavaScriptCore 경로가 포함될 수 있습니다. 현재 Swift 앱의 구조·빌드·검증 범위는 [README](../README.md)를 우선합니다. 아래 결과는 현재 빌드의 검증 결과가 아닙니다.

# iPad workspace layout

The iPad layout adapter is in `DesktopRuntime/renderer/ipad/layout/`. It composes
the existing React application, settings routes and Dockview panels. Files in
`DesktopRuntime/upstream` remain unchanged and retain their snapshot hashes.
The adapter rejects changed source anchors rather than silently applying a
partial transformation.

## Layout policy

- A persistent 56px desktop app icon rail sits at the far left, with the main
  sidebar in a separate 280px column beside it. The desktop destinations and
  ordering (including AI, Help, account and settings) are preserved. Course
  navigation, materials and document AI start closed. A saved desktop AI `open`
  value does not reopen an iPad assistant; its conversation and other parameters survive.
- The tab/navigation row is 48 CSS pixels high. The duplicate title/AI launch
  row is removed. The current document's AI action lives in the tab row.
  At narrow available tab widths the current titled tab is retained, with
  other tabs available in the open-tabs menu.
- Below 700px the main sidebar uses the width to the right of the icon rail;
  materials use the full width. At larger widths each panel docks automatically
  when at least 560px remains for the document, including the persistent 56px
  rail in the calculation. Main navigation plus the rail occupy 336px; materials
  use 320px. Users can choose an overlay using the pin control.
- Navigation and the right panel can both dock when space permits. In narrower
  windows the most recently requested panel takes priority and the other is
  temporarily suspended; resizing restores requested panels without reopening
  explicitly closed ones. Document AI and materials share the right side.
- Materials close when the active surface does not support them (including
  Learning). This also releases a pinned panel's width; the pin preference
  remains available when the user returns to a document and opens materials.
- AI uses the same available-width and pin policy, reserving the assistant's
  width in its document pane. Narrow windows temporarily use a drawer.
- iPad panel mode preferences use `bandal:ipad:panel-modes:v2`, migrating the
  previous pin keys. Width changes never overwrite these preferences. Saved
  panel modes do not reopen closed panels at launch.

## Split preservation

The minimum usable width is computed from the actual serialized Dockview split
tree and its proportions. Every document leaf needs 560px; horizontal dividers
reserve 8px. Two equally sized columns therefore need 1128px. Unequal columns
may require more width. Below 700px multiple groups always use one visible pane.

When space is insufficient, the adapter temporarily maximizes the active group
without replacing panels, moving tabs or recreating document editors. The tab
list includes tabs from the other groups while maximized. When enough space is
available, the original split reappears. User-requested maximization is not
automatically undone.

The adapter retains split proportions while it owns an automatic maximization.
Dockview serialization temporarily reveals maximized groups and can otherwise
change cached sizes. The adapter preserves the retained proportions in saved
layouts, removes `grid.maximizedNode`, and restores the existing groups at the
current viewport dimensions. Panel parameters continue to serialize normally;
editors are not recreated. Compact presentation therefore does not become a
saved user maximization after restart.

## Settings and touch access

Settings use their own navigation state, independent of the workspace's left
panel. At 760px and above a 240px category list sits beside the detail pane.
Below 760px the list and detail are separate views with visible list/back and
`← 앱으로 돌아가기` controls. The return action uses the same translation
and close route as the desktop application. Cmd/Ctrl+F returns to the list and
focuses search even from a narrow detail page. Checklist destinations enter the appropriate detail page,
and keyboard focus follows the visible view. Category IDs and the original
20 settings panels remain.

Course menu controls remain visible without hover. Material rows gain a
separate 44px more button that invokes the existing context-menu action; the
original row still owns selection, opening and drag behavior. Tab lists offer
close, new-tab and split actions without requiring right-click or a keyboard.
New-tab commands expose individual accessible buttons. New/open-tab menus
register native overlay rectangles, and anchored popovers clamp to the visual
viewport including keyboard resize and focus-pan offsets. Search inputs use
16px text to avoid input-driven page zoom. Overflow correction changes layout
insets while preserving anchor transforms, keeping native accessibility bounds
aligned with the visible menu rows.
The AI composer also provides 44px add, send, model and access-mode controls.
Modal AI drawers keep Tab/Shift-Tab focus inside, and Escape closes the drawer
and returns focus to its opener. Pinned AI panels retain normal document
keyboard navigation.

The SwiftUI application root requests a hidden system status bar. The layout
does not disable multitasking or orientation changes.

## Sidebar swipes and immediate tab dragging

Both side panels use the same gesture. Swipe right anywhere on the icon rail
to open the main sidebar; swipe an open panel toward its own screen edge (left
for the main sidebar, right for materials) to close it. Motion is recognized
after 8px of dominant horizontal movement with no hold timer, so taps and
vertical scrolling inside the panel are unaffected. While dragging, the panel
follows the finger with a compositor transform; release after 48px, or a
deliberate short flick, to commit, otherwise it springs back. Another finger,
pointer cancellation, resizing, pen/mouse input or an open settings/board
surface cancels the gesture. The recognizer lives in `sidebarSwipe.tsx` and
every open/close path (chrome button, icon rail, header toggle, backdrop,
Escape, close buttons and swipes) routes through `setIpadRail`. Gestures
beginning in the document continue to belong to scrolling, selection and
Pencil input.

Tab labels also start dragging after 8px of touch movement, with no long-press
wait. A stationary tap still selects a tab. Drag over another tab to reorder,
into another pane to move, or to a pane edge to split. The existing desktop
course move overlay and course-row targets handle transfers to another course.
Dragging onto the persistent Courses icon reveals the main sidebar, including
in compact windows where a pre-opened modal sidebar would block the tabs.
The dragged title follows the finger, while desktop drop previews indicate the
destination. Close buttons remain separate tap targets; unused tab-strip space
and the open-tabs list remain available for navigating overflow tabs.

The touch bridge dispatches through the desktop drag session and canonical
workspace drop/persistence handlers. It acquires native input ownership before
committing over PDF/browser surfaces. Cancellation, another contact, Escape or
leaving the app ends the session and clears preview/input ownership. These
behaviors have WebKit fixture coverage; physical-device gesture feel and
system edge-gesture interaction still need device acceptance.

## Native surface ownership

Course/material sheets are non-modal: they overlay the workspace, register as
`[data-bandal-native-overlay]` masks, and close on a tap outside, on native
contact (`bandal-ipad-native-contact` from the PDF host or browser guest), or
through their own X/pin icon controls. Only the AI drawer and settings block
native paper. Pinned panels change the document's actual bounds instead. Settings use the existing owner-based passthrough contract,
adapted to the same shared native surface manager.

Temporary HTML coverage is distinct from closing or suspending a document.
The docked PDF toolbar and Pencil policy are owned by `renderer/ipad/input/`.
The toolbar is ordinary in-flow chrome above the page scroller, so it never
covers the paper and needs no native input ownership; only its three popovers
and the collapsed corner control register native exclusion rectangles. This
layout adapter does not edit the native ink pipeline.

### Notes and page editing

A note is a generated PDF (`pdfNotes:create`: one page with a paper pattern
stored as PDF keywords), so it gets the native ink pipeline, the docked
toolbar and the page panel instead of a separate canvas. The legacy canvas
whiteboards stay listed as "이전 화이트보드": open, draw with the default tool,
or export to PDF; creation, rename, delete and the tool rail are retired.

The page panel (`renderer/nativePDF/PdfPagesPanel.tsx`) edits the document:
tap jumps, hold-and-drag reorders, the per-page menu rotates, duplicates,
deletes or inserts blank pages. Each edit is one `pdf:restructure` recipe. The
backend rewrites the file with pdf-lib, stamps a new `/ID` so pdf.js sees a new
fingerprint, remaps drawings, annotations, view state, recording anchors and
page-note links in one SQLite transaction, keeps the previous bytes under
`PDFOriginals/`, and writes the file last so a failed commit leaves both file
and rows untouched. The renderer suspends the native session (`layout
{visible:false}` + flush) before the call and remounts the viewer with a
versioned key and `?v=` URL afterwards, so the native host reopens the new
bytes with cleared undo history. Deleted pages soft-delete their ink; there is
no page-edit undo yet. Sync peers see the rewritten file as a replaced PDF.

Notes live in the course's `노트/` folder and the materials sidebar lists them
in a "노트" section (`renderer/ipad/touch/NotesGroup.tsx`) with a create
button; the rows are the ordinary `MaterialTree`, so rename, move, delete and
share work unchanged. The files tree hides that folder to avoid duplicates.

Page-panel gestures hold before dragging for every pointer type: a Pencil tap
only jumps. Drop slots are insert positions (`moveTarget` in `pageRecipe.ts`),
and after an edit the viewer restores the reader's content, not the old page
number, by remapping the session anchor through the recipe's `pageMap`.

### Lasso and shape snapping

`lasso` is an iPad-only tool value added to the upstream `InkTool` union at
build time. InkLayer (transformed in `renderer/nativePDF/index.mjs`) records
the loop, selects strokes and shapes whose sample points fall inside it
(`renderer/nativePDF/lasso.ts`, even-odd in `(x, y * aspect)`), publishes the
loop as a preview object and the union box as the selection frame, and moves
the group on drag with one history step (`updateMany` added to `useDrawings`).
The toolbar shows the count with 삭제/해제 through `lassoStore`; only one page
holds a selection at a time. Native draws the loop and frame; the Swift tool
allowlists include `lasso` so the Pencil reaches the editor instead of PDFKit
text selection.

Shape snapping: when a pen stroke rests for 0.6 s after its last movement
(`NativePDFInkSurface.updateHoldSnap`, light haptic), the completed stroke is
flagged and the host emits `strokeHold` before the journaled `stroke`. Once the
ink is saved and acknowledged, `recognizeShape` (`shapeRecognition.ts`: RDP
simplification, closed-loop test, corner count and fill ratio) replaces it
with a `line`, `rect` or `ellipse` row through `swap`, a one-step `replace`
history action, so one undo brings the raw stroke back. Triangles and arrows
are not recognized.

### Navigation rendering

The GPU ink path keeps its reprojected Metal frame through scrolling and
pinching; the raster fallback image (`scene`) is only a hand-off aid before the
first retained install and is dropped when an erase lands, so erased strokes
cannot reappear during navigation. `NativePDFRenderViewport` pads the visible
rect along the scroll axis and snaps it to a 64 pt grid within the pixel
budget, so most scroll frames reuse the staged drawable; during a live pinch
the surface defers restaging until the gesture ends (`finishLiveZoom`). The
host coalesces `viewport` events to 80 ms and formats accessibility
diagnostics only under `--ui-testing`. Device builds should pass
`SWIFT_OPTIMIZATION_LEVEL=-O`; the native PDF path is DEBUG-gated.

## Verification

Run from the repository root:

```sh
node DesktopRuntime/renderer/ipad/layout/test.mjs
node DesktopRuntime/scripts/verify-snapshot.mjs
```

The layout test parses every adapted production source, renders the actual
adapted settings application, assistant wrapper and chat composer in WebKit, and uses real
Dockview groups with editable content. It checks 11 viewport widths, settings
list/detail navigation, actual tab-menu commands inside keyboard-sized and
panned visual viewports, native menu masks, touch menu access, blockers, pin limits and persistence,
panel priority and modal ownership, computed composer touch sizes, preservation of
unsaved editor values, restored split topology/proportions and user maximization.
It does not establish physical-device
Pencil behavior, UIKit mask ordering, hardware keyboard behavior or status-bar
appearance; those require the native integration/device acceptance checks.


## Opt-in native mixed soak

`Tests/BandalUITests/IPadMixedSoakTests.swift` skips in the ordinary suite.
`BANDAL_IPAD_SOAK_SECONDS` enables a requested duration of at least one second;
`BANDAL_IPAD_SOAK=1` enforces a minimum 7200-second measured loop. A shorter run
qualifies the test harness and must not be reported as two-hour acceptance.
The test prints elapsed time, cycles, canonical drawing count, pending ACKs,
latest saved Markdown marker and restart count after each completed cycle.

Run on a dedicated simulator after regenerating/building the test target. For
example, prefix the existing Xcode test command with
`TEST_RUNNER_BANDAL_IPAD_SOAK_SECONDS=120` and select
`-only-testing:BandalUITests/IPadMixedSoakTests`. For the full run use
`TEST_RUNNER_BANDAL_IPAD_SOAK=1`, disable parallel testing and allow at least
8100 seconds per test (`-maximum-test-execution-time-allowance 8100`). The test
reads both the runner's unprefixed names and literal `TEST_RUNNER_` variants.

The isolated fixture cycles native PDF synthetic strokes and canonical ACKs,
docked toolbar coverage, settings and materials coverage, Markdown
editing and tab switching, orientation changes, background/foreground, periodic
cold app launches and a final persisted-data check. It does not exercise remote
browser content, service login, physical Pencil pressure/palm rejection, display
latency or OS-driven memory-pressure termination. Browser chrome has a separate
`BrowserWorkspaceTests` case. A passing scoped WebKit fixture or a parsed Swift
file is not evidence that this native soak has run.
