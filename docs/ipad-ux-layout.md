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

The sidebar boundary has a subtle 16×112px grip, centered vertically. Swipe it
right to open the main sidebar or left to close it. Motion is recognized after
8px with no hold timer. Release after 48px, or a deliberate short flick, to
commit. The grip provides progress feedback; the document width changes only
when the gesture commits. A tap or keyboard activation also toggles it.
Vertical movement, reversal, another finger, pointer cancellation, resizing or
opening settings cancels the gesture. The grip sits inside the sidebar boundary
and is registered with native hit testing; gestures beginning in the document
continue to belong to scrolling, selection and Pencil input.

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

Course/material sheets and AI drawers hold named full-surface blockers through
`renderer/ipad/nativeSurfaces.ts`. Pinned panels change the document's actual
bounds instead. Settings use the existing owner-based passthrough contract,
adapted to the same shared native surface manager.

Temporary HTML coverage is distinct from closing or suspending a document.
The floating PDF palette and Pencil policy are owned by `renderer/ipad/input/`;
this layout adapter does not edit the native ink pipeline.

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
movable palette input ownership, settings and materials coverage, Markdown
editing and tab switching, orientation changes, background/foreground, periodic
cold app launches and a final persisted-data check. It does not exercise remote
browser content, service login, physical Pencil pressure/palm rejection, display
latency or OS-driven memory-pressure termination. Browser chrome has a separate
`BrowserWorkspaceTests` case. A passing scoped WebKit fixture or a parsed Swift
file is not evidence that this native soak has run.
