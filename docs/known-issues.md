# Known issues

Open bugs with enough context to resume cold in a new session. Both were found on
2026-10-19 while fixing the "PDF page not restored after relaunch" bug (the
save-side fix landed as commit `e15a2c2`, `fix(pdf): restore the saved page after
relaunch`). Both surface in the UI test
`BandalUITests/NativePDFDocumentFlowTests.testMultiplePDFsMarkdownDockingAndRestartPreserveInkToolsAndViewport`,
which is still expected to fail until both are resolved.

Shared test loop (simulator is shared with other sessions — serialize, see the
`simulator-shared-sessions` memory):

```
xcodegen generate
xcodebuild -project Bandal.xcodeproj -scheme Bandal \
  -destination 'platform=iOS Simulator,id=7A78DAF6-5DE6-4146-A6FF-F4C3EE0DB949' \
  -derivedDataPath .derivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO build-for-testing
# then test-without-building -only-testing:BandalUITests/NativePDFDocumentFlowTests/testMultiplePDFsMarkdownDockingAndRestartPreserveInkToolsAndViewport
```

Drag-trace is `NSLog("[bandal.dock] …")` (`NativeDockWorkspace.NativeDockDragPayload.trace`,
`#if DEBUG` + launch arg `--native-ui-testing`, which the test sets). View-state
diagnostics can be re-added as `NSLog("BANDALVP …")` in
`NativePDFWorkspace.swift` (the `open()` restore merge and the `flush()` save
block). Capture either with
`xcrun simctl spawn <SIM> log stream --style compact --predicate 'eventMessage CONTAINS "bandal.dock" OR eventMessage BEGINSWITH "BANDALVP"'`.

---

## 1. Merged-pane viewport page not restored after relaunch

**Symptom.** After docking a PDF tab into another pane's group (cross-pane merge)
and then fully quitting and relaunching, the PDF's scroll **page** is not restored
(it opens at page 1). Ink, tools, and zoom *are* restored. A standalone (never
merged) PDF tab restores its page correctly after the `e15a2c2` fix.

**Where it fails.** In the test, the post-relaunch `expectPage(2)` right after
`app.terminate()` … `app.launch()` (the second relaunch block, after the tab was
dragged into the markdown pane).

**Confirmed.**
- The save-side bug is fixed: with `e15a2c2`, every in-session flush of the PDF
  saves `page=2` (diagnostic `BANDALVP flush-save … page=Optional(2)`), and
  in-session reopens restore `page=2` (`diskPage=2 prefsPage=2`). The
  drag-neutralized full test (merge skipped) passes the post-relaunch
  `expectPage(2)`.
- With the merge actually performed, one clean run reached the relaunch check and
  `expectPage(2)` still failed (page 1) — so this is distinct from the save-side
  bug and specific to the **merged/docked** configuration.
- `pageCount` on restore is correct (3); zoom restores (1.1); ink restores (2).

**Not yet captured.** The post-merge flush values and the post-relaunch restore
values for the docked PDF — the flaky drag (issue #2) usually aborts the test
before that point, and the `BANDALVP` NSLogs shift timing enough to make the drag
fail more often, so a clean post-merge trace wasn't obtained.

**Suspected cause (unverified).** A restore-timing problem in a shared pane: when
the docked PDF becomes active in the merged group, its viewport restore
(`pendingViewportRestore` applied in `publishLayout` when visible + bounds) likely
runs before the shared pane's layout settles, or a later layout in the merged
group resets the scroll after the restore. Candidate fix: re-assert the pending
viewport restore until the host confirms the target page (instead of consuming it
on the first `publishLayout`), or key/scope the restore so a merged-group layout
pass doesn't drop it. Alternatively, confirm first whether a post-merge flush
persists `page=1` (save-side again in the merged config) by capturing the trace.

**Relevant code.** `App/Native/NativePDFWorkspace.swift` — `open()` restore merge
(`preferences.viewport?.restoring(...)`, `pendingViewportRestore`), `publishLayout()`
(applies `pendingViewportRestore` via `navigate`), `flush()` (persists
`persistedViewport`). `App/Desktop/PDF/NativePDFHost.swift` — `persistedViewport`,
`navigate(_:)`, `viewportState`.

---

## 2. Cross-pane tab drag is aborted by re-render churn

**Symptom.** Dragging a tab from one pane and dropping it onto another pane
(`aTab.press(forDuration:1, thenDragTo: markdown…)`) frequently fails to merge:
the drop never registers and the `merged` wait times out. Rate: ~0% failure on
`HEAD` (before the viewport fix), ~89% once the viewport fix makes the PDF restore
a non-top scroll (page 2).

**Where it fails.** The `merged` `XCTWaiter` right after the drag in the same test.

**Confirmed via `[bandal.dock]` trace of a failing drag.**
- `source.begin` fires (the drag's `itemsForBeginning` is called) and every pane's
  drop surface activates (`surface.active=true`).
- **No** `target.canHandle`, **no** `target.performDrop`, and **no** `source.end`
  — the lift begins but never becomes a moving drop session and never ends. That
  is a drag **lift abort**, not a rejected drop.
- It is correlated with the PDF being scrolled to page 2 (the correct restored
  state). On `HEAD` the PDF stayed at page 1 (the bug), so the lift was never
  perturbed — i.e. the viewport fix *unmasks* this pre-existing fragility.

**Ruled out.**
- **PDF gestures / hit-testing are NOT the cause.** Two fixes had *zero* effect on
  the trace (both reverted): (a) `.allowsHitTesting(false)` on `NativePDFBody`
  while a `nativeDockDragActive` environment flag was set; (b) a host-level
  `dragSuppressed` flag folded into `NativePDFHost.layout()`’s
  `pdfView.isUserInteractionEnabled` (so a concurrent re-layout could not
  re-enable it). Fully disabling the PDF body's touch handling did not change the
  `source.begin`-only trace, so the PDF is not swallowing the drag.

**Suspected cause (unverified).** SwiftUI re-render churn from the PDF's
restore/flush settling on reopen updates/invalidates the draggable tab
(`NativeDockDraggableTab`, a `UIViewRepresentable` with a `UIDragInteraction`)
during the long-press, aborting the lift. HEAD's near-noop page-1 restore settles
instantly, so the lift survives.

**Leads for next time.**
- A **settle wait before the drag** (wait for the PDF to report page 2, then a
  short quiesce) let the drag pass and reach the relaunch check in one run, but was
  not reliable and the NSLog diagnostics made it fail again — removed, not
  committed. Worth revisiting as either test hardening or a signal that reducing
  reopen churn fixes it.
- Reduce reopen churn: e.g. the restore `navigate()` calls `try flush()` at its
  start (`NativePDFHost.navigate`); a reopen that scrolls may emit/flush more than
  needed. Quieter settling may let the lift survive.
- Confirm the lift-abort hypothesis directly: log in
  `NativeDockDraggableTab.updateUIView` / `makeUIView` to see if the tab view is
  rebuilt during the press, and check for a `source.end` with a cancel operation.

**Relevant code.** `App/Native/NativeDockWorkspace.swift` —
`NativeDockDraggableTab` (UIDragInteraction source), `NativeDockDropSurface`
(UIDropInteraction target, `acceptsTouches` while `drag.transfer != nil`),
`NativeDockDragPayload.trace`. Churn source: `App/Native/NativePDFWorkspace.swift`
reopen/restore path.
