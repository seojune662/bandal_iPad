import XCTest
import UIKit
@testable import Bandal

/// The window buttons at the top right (공유 · 탭과 도구 표시 · 윈도우 관리 · 오른쪽 패널) over the dock: what lies under
/// them keeps clear of them, and pressing them leaves the chosen pane as it was.
final class NativeWorkspaceControlsOverlapTests: XCTestCase {
    private let reserve = NativeWorkspaceWindowControls.width + NativeWorkspaceWindowControls.trailing

    /// The dock's panes for a layout, as the dock lays them out, and each one's area under its strip.
    private func areas(_ preset: NativeDockPreset, size: CGSize, mode: NativeWorkspaceChromeMode, topEdge: NativeDockTopEdge) -> [CGRect] {
        var layout = NativeDockLayout(group: NativeDockGroup(tabs: ["a"], activeID: "a"))
        layout.apply(preset)
        let bounds = CGRect(origin: .zero, size: size)
        let panes = layout.geometry(in: bounds).panes.map(\.frame)
        let metrics = NativeDockStripMetrics.resolve(paneFrames: panes, bounds: bounds)
        return panes.map { NativeDockHeaderMetrics.contentFrame(for: $0, controlsHeight: mode.showsTabs ? metrics.total : 0, topEdge: topEdge) }
    }

    /// Every mode × layout × window size × top edge: an area under the buttons is told by how much, and an editor that
    /// keeps its content `trailing` from the right and, with the tools hidden, 44 + `extraDrop` down, clears them.
    func testWhateverLiesUnderTheButtonsIsToldHowToClearThem() {
        let sizes = [CGSize(width: 1376 - 48, height: 1032), CGSize(width: 1210 - 48, height: 834), CGSize(width: 1032 - 48, height: 1376),
                     CGSize(width: 834 - 48, height: 1210), CGSize(width: 694 - 48, height: 1032), CGSize(width: 507 - 48, height: 1032)]
        for size in sizes {
            for edge in [NativeDockTopEdge.statusBar, .window, .flush] {
                let controls = try! XCTUnwrap(NativeWorkspaceWindowControls.frame(dockWidth: size.width, reserve: reserve, topEdge: edge))
                XCTAssertEqual(controls.maxX, size.width - NativeWorkspaceWindowControls.trailing)
                for mode in NativeWorkspaceChromeMode.allCases {
                    for preset in NativeDockPreset.allCases {
                        for area in areas(preset, size: size, mode: mode, topEdge: edge) {
                            let value = NativeWorkspaceControlAvoidance.resolve(area: area, controls: controls, mode: mode)
                            let label = "\(size) \(edge) \(mode) \(preset) \(area)"
                            let under = area.intersects(controls)
                            XCTAssertEqual(value.trailing > 0, under, label)
                            if mode.showsTabs { XCTAssertEqual(value, .none, "With the tabs shown the strip has the buttons' row: " + label) }
                            guard under else { XCTAssertEqual(value, .none, label); continue }
                            // Beside the buttons: the content's right edge is left of them.
                            XCTAssertLessThanOrEqual(area.maxX - value.trailing, controls.minX + 0.001, label)
                            if mode == .toolsHidden {
                                let top = area.minY + NativeWorkspaceControlAvoidance.editorDrop + value.extraDrop
                                XCTAssertGreaterThanOrEqual(top, controls.maxY + NativeWorkspaceControlAvoidance.gap - 0.001, "Below the buttons: " + label)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The owner's screen: a browser on the left, a note on the right, the tabs and tools hidden, full screen on iPadOS 26
    /// and later. The right pane's area starts 24 pt down, under the status bar, and must still keep clear.
    func testRightPaneOfASplitFullScreenWithEverythingHiddenClearsTheButtons() {
        let size = CGSize(width: 1376 - 48, height: 1032)
        let panes = areas(.columns, size: size, mode: .toolsHidden, topEdge: .statusBar)
        XCTAssertEqual(panes.count, 2)
        let controls = NativeWorkspaceWindowControls.frame(dockWidth: size.width, reserve: reserve, topEdge: .statusBar)
        let right = try! XCTUnwrap(panes.max { $0.minX < $1.minX }), left = try! XCTUnwrap(panes.min { $0.minX < $1.minX })
        XCTAssertEqual(right.minY, 24, "Under the status bar")
        let value = NativeWorkspaceControlAvoidance.resolve(area: right, controls: controls, mode: .toolsHidden)
        XCTAssertEqual(value.trailing, reserve)
        XCTAssertGreaterThan(value.extraDrop, 0)
        XCTAssertEqual(NativeWorkspaceControlAvoidance.resolve(area: left, controls: controls, mode: .toolsHidden), .none)
        // The pinned right panel has the buttons above it: nothing in the dock is under them.
        XCTAssertNil(NativeWorkspaceWindowControls.frame(dockWidth: size.width, reserve: 0, topEdge: .statusBar))
    }

    /// The PDF palette stays in its row beside the buttons while it loses nothing there, and goes under them otherwise.
    @MainActor func testPaletteKeepsItsRowBesideTheButtonsOnlyWhenNothingIsLost() {
        let slots = 4
        XCTAssertTrue(NativePDFFloatingPalette.fitsBeside(controls: 0, pageWidth: 300, slots: slots), "No buttons over the pane")
        XCTAssertTrue(NativePDFFloatingPalette.fitsBeside(controls: reserve, pageWidth: 1300, slots: slots), "A wide page: the whole row fits beside")
        XCTAssertFalse(NativePDFFloatingPalette.fitsBeside(controls: reserve, pageWidth: 200, slots: slots))
        // Wherever it is beside, the stage it shows is the one the whole width would give.
        for width in stride(from: 200.0, through: 1400, by: 10) {
            guard NativePDFFloatingPalette.fitsBeside(controls: reserve, pageWidth: width, slots: slots) else { continue }
            let whole = width - NativePDFFloatingPalette.leadingReserve - NativePDFFloatingPalette.trailingReserve
            XCTAssertNotNil(NativePDFFloatingPalette.stage(fitting: whole - reserve, slots: slots))
        }
    }

    // MARK: Touch focus

    /// A touch on the window buttons, or on a popover presented over the dock, does not choose the pane under it; any
    /// other touch on a pane does.
    @MainActor func testTouchesOnTheButtonsOrOnAPresentationKeepTheChosenPane() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1376, height: 1032))
        let root = UIView(frame: window.bounds); window.addSubview(root)
        let pane = UIView(frame: CGRect(x: 700, y: 0, width: 676, height: 1032)); root.addSubview(pane)
        let controls = UIView(frame: CGRect(x: 1376 - 179, y: 29.5, width: 169, height: 40)); root.addSubview(controls)
        let presented = UIView(frame: CGRect(x: 1000, y: 80, width: 280, height: 300)); window.addSubview(presented)
        window.isHidden = false
        let inControls = CGPoint(x: 1300, y: 50), inPane = CGPoint(x: 900, y: 500)
        XCTAssertTrue(NativeDockTouchFocus.counts(view: pane, location: inPane, window: window, root: root, excluded: [controls]))
        XCTAssertFalse(NativeDockTouchFocus.counts(view: root, location: inControls, window: window, root: root, excluded: [controls]),
                       "The buttons are drawn in the same screen: their region is what keeps them out")
        XCTAssertFalse(NativeDockTouchFocus.counts(view: presented, location: CGPoint(x: 1100, y: 200), window: window, root: root, excluded: []),
                       "공유's popover is presented over the screen, not part of it")
        controls.isHidden = true
        XCTAssertTrue(NativeDockTouchFocus.counts(view: root, location: inControls, window: window, root: root, excluded: [controls]),
                      "A hidden marker excludes nothing")
        let elsewhere = UIWindow(frame: window.bounds)
        let foreign = UIView(frame: controls.frame); elsewhere.addSubview(foreign)
        XCTAssertTrue(NativeDockTouchFocus.counts(view: pane, location: inControls, window: window, root: root, excluded: [foreign]),
                      "A marker in another window excludes nothing here")
    }
}
