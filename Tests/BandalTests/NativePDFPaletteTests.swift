import XCTest
import UIKit
@testable import Bandal

final class NativePDFPaletteTests: XCTestCase {
    func testNativeV1SharedStyleMigratesWithoutResettingWidthsOrViewport() throws {
        let old = Data(#"{"tool":"highlighter","color":"green","width":0.0123,"opacity":0.8,"previousTool":"pen","penColor":"red","highlighterColor":"green","toolsExpanded":false,"showPages":true,"showAnnotations":false,"viewport":{"revision":"r","page":2,"zoom":1.5,"progress":0.7,"horizontalProgress":0.1}}"#.utf8)
        let value = try JSONDecoder().decode(NativePDFWorkspacePreferences.self, from: old).validated()
        XCTAssertEqual(value.penStyle, .init(color: "red", width: 0.0123, opacity: 0.8))
        XCTAssertEqual(value.highlighterStyle, .init(color: "green", width: 0.0123, opacity: 0.34))
        XCTAssertEqual(value.opacity, 0.34)
        XCTAssertEqual(value.width, 0.0123)
        XCTAssertEqual(value.viewport?.page, 2)
        XCTAssertTrue(value.showPages); XCTAssertFalse(value.toolsExpanded)
        let again = try JSONDecoder().decode(NativePDFWorkspacePreferences.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(again, value)
    }

    func testV1PresetAndBetweenStepValuesMigrateAndSharedEditsDoNotClobberEachOther() throws {
        let suite = "NativePDFPaletteTests.\(UUID())", root = URL(fileURLWithPath: "/palette-test")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = NativePDFPalettePreferences.key(root: root)
        defaults.set(Data(#"{"version":1,"presets":[{"width":"broken"},{"color":"violet","width":0.0317,"opacity":0.05}],"drawAndHold":false}"#.utf8), forKey: key.replacingOccurrences(of: ".v2.", with: ".v1."))
        let old = NativePDFPalettePreferences.load(root: root, defaults: defaults)
        XCTAssertEqual(old.recentPen, .init(color: "violet", width: 0.0317, opacity: 0.05), "The first valid preset of version 1 was the pen in use")
        XCTAssertEqual(old.recentHighlighter, .highlighter); XCTAssertFalse(old.drawAndHold)
        NativePDFPalettePreferences.update(root: root, defaults: defaults) { $0.colorSlots["pen"] = ["orange"] }
        let latest = NativePDFPalettePreferences.update(root: root, defaults: defaults) { $0.widthSlots["pen"] = [0, 1, 2] }
        XCTAssertEqual(latest.recentPen, old.recentPen); XCTAssertEqual(latest.colors(for: "pen"), ["orange"])
        XCTAssertEqual(latest.widths(for: "pen"), [0, 1, 2]); XCTAssertFalse(latest.drawAndHold)
    }

    func testTwelveStepsHoldEveryEarlierDefaultAndLabelTheNearestStep() {
        for tool in ["pen", "ballpoint", "highlighter", "eraser"] {
            let steps = NativePDFPaletteStyle.steps(for: tool)
            XCTAssertEqual(steps.count, 12, tool)
            XCTAssertEqual(steps, steps.sorted(), tool)
            XCTAssertEqual(Set(steps).count, 12, tool)
            let slots = NativePDFPalettePreferences().widths(for: tool)
            XCTAssertEqual(slots.count, 3, tool); XCTAssertTrue(slots.allSatisfy(steps.indices.contains), tool)
        }
        for width in [NativePDFPenPreset.pen.width, NativePDFPenPreset.ballpoint.width, 0.002, 0.004, 0.008] {
            XCTAssertTrue(NativePDFPaletteStyle.penSteps.contains(width), "\(width)")
        }
        for width in [NativePDFPenPreset.highlighter.width, 0.0035, 0.006, 0.01] {
            XCTAssertTrue(NativePDFPaletteStyle.highlighterSteps.contains(width), "\(width)")
        }
        XCTAssertEqual(NativePDFPaletteStyle.eraserSteps[3], 0.005, "The eraser keeps its old radius by default")
        XCTAssertEqual(NativePDFPaletteStyle.nearestStep(0.0043, tool: "pen"), 5, "An old slider width shows its nearest step")
        XCTAssertEqual(NativePDFPaletteStyle.stepLabel(0), "1단계"); XCTAssertEqual(NativePDFPaletteStyle.stepLabel(11), "12단계")
    }

    func testSlotPreferencesDecodeFromOlderVersionTwoDataAndRejectBadSlots() throws {
        let old = try JSONDecoder().decode(NativePDFPalettePreferences.self, from: Data(#"{"version":2,"favorites":[],"drawAndHold":true}"#.utf8))
        XCTAssertEqual(old.colors(for: "pen"), ["ink", "blue", "red", "green"])
        XCTAssertEqual(old.widths(for: "highlighter"), [0, 5, 9])
        XCTAssertEqual(old.eraserMode, "stroke"); XCTAssertEqual(old.eraserRadius, 0.005)
        let bad = try JSONDecoder().decode(NativePDFPalettePreferences.self, from: Data(#"{"version":2,"colorSlots":{"pen":["pink","red","red"]},"widthSlots":{"pen":[1,99,2]},"eraserMode":"laser","eraserRadius":3}"#.utf8))
        XCTAssertEqual(bad.colors(for: "pen"), ["red"], "Unknown and repeated colours are dropped")
        XCTAssertEqual(bad.widths(for: "pen"), [2, 5, 8], "An out-of-range step falls back to the defaults")
        XCTAssertEqual(bad.eraserMode, "stroke"); XCTAssertEqual(bad.eraserRadius, 0.005)
        var value = NativePDFPalettePreferences()
        value.colorSlots["pen"] = ["violet"]; value.widthSlots["eraser"] = [0, 4, 11]; value.eraserMode = "partial"; value.eraserRadius = 0.012
        let again = try JSONDecoder().decode(NativePDFPalettePreferences.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(again, value)
    }

    @MainActor
    func testWidthAndColorSlotsAreSharedAndTheOpenSlotKeepsItsStep() {
        let suite = "NativePDFPaletteSlots.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NativeWorkspaceStore(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let a = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "a.pdf", title: "A", kind: "pdf"), store: store, defaults: defaults)
        let b = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "b.pdf", title: "B", kind: "pdf"), store: store, defaults: defaults)
        XCTAssertEqual(a.widthSlots, [2, 5, 8]); XCTAssertEqual(a.selectedWidthSlot, 1, "The default pen width is the middle slot")
        a.chooseWidthSlot(0); XCTAssertEqual(a.width, 0.002); XCTAssertNil(a.editingWidthSlot)
        a.chooseWidthSlot(0); XCTAssertEqual(a.editingWidthSlot, 0, "Tapping the chosen slot opens its twelve steps")
        XCTAssertFalse(a.showStyle)
        a.setWidthStep(3, slot: 0)
        XCTAssertEqual(a.width, 0.0025); XCTAssertEqual(a.widthSlots, [3, 5, 8]); XCTAssertEqual(a.selectedWidthSlot, 0)
        XCTAssertEqual(b.widthSlots, [3, 5, 8], "Slots are workspace-wide"); XCTAssertEqual(b.width, 0.004, "A peer keeps its active width")
        a.addColorSlot("orange"); XCTAssertEqual(a.color, "orange"); XCTAssertTrue(b.colorSlots.contains("orange"))
        a.removeColorSlot("orange"); XCTAssertFalse(a.colorSlots.contains("orange")); XCTAssertEqual(a.color, "orange", "Removing a slot keeps the active colour")
        a.chooseTool("highlighter"); XCTAssertEqual(a.widthSlots, [0, 5, 9]); XCTAssertEqual(a.selectedWidthSlot, 1)
        a.chooseTool("eraser"); XCTAssertEqual(a.widthSlots, [1, 3, 6]); XCTAssertEqual(a.selectedWidthSlot, 1)
        a.chooseWidthSlot(2); XCTAssertEqual(a.palette.eraserRadius, 0.012); XCTAssertEqual(b.palette.eraserRadius, 0.012)
        a.setEraserMode("partial"); XCTAssertEqual(b.palette.eraserMode, "partial")
        a.setEraserMode("laser"); XCTAssertEqual(a.palette.eraserMode, "partial")
        let stored = NativePDFPalettePreferences.load(root: store.root, defaults: defaults)
        XCTAssertEqual(stored.eraserMode, "partial"); XCTAssertEqual(stored.widths(for: "pen"), [3, 5, 8])
    }

    func testFavoritesStoredByEarlierBuildsAreIgnoredAndEverythingElseIsKept() throws {
        // What 1.4.2 (24) wrote: three favourite pens (one emptied, one broken) and a pen type on every preset.
        let stored = Data(#"{"version":2,"favorites":[{"color":"red","width":0.004,"opacity":0.9,"kind":"pen"},null,{"width":"broken"}],"recentPen":{"color":"blue","width":0.002,"opacity":1,"kind":"pen"},"recentBrush":{"color":"green","width":0.005,"opacity":1,"kind":"brush"},"colorSlots":{"pen":["violet"]},"widthSlots":{"pen":[0,4,11]},"tapePageOnly":false,"drawAndHold":false}"#.utf8)
        let value = try JSONDecoder().decode(NativePDFPalettePreferences.self, from: stored)
        XCTAssertEqual(value.recentPen, .init(color: "blue", width: 0.002, opacity: 1)); XCTAssertEqual(value.recentBrush, .init(color: "green", width: 0.005, opacity: 1))
        XCTAssertEqual(value.colors(for: "pen"), ["violet"]); XCTAssertEqual(value.widths(for: "pen"), [0, 4, 11])
        XCTAssertFalse(value.tapePageOnly); XCTAssertFalse(value.drawAndHold)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertNil(written["favorites"], "The key is not written back"); XCTAssertNil((written["recentPen"] as? [String: Any])?["kind"])
        for favorites in [#""broken""#, "7", "{}", "null"] {
            XCTAssertEqual(try JSONDecoder().decode(NativePDFPalettePreferences.self, from: Data(#"{"version":2,"favorites":\#(favorites),"eraserMode":"partial"}"#.utf8)).eraserMode, "partial", favorites)
        }
        // A document's own styles carried the pen type too.
        let document = try JSONDecoder().decode(NativePDFWorkspacePreferences.self, from: Data(#"{"tool":"brush","color":"red","width":0.005,"opacity":1,"previousTool":"pen","penColor":"ink","highlighterColor":"yellow","penStyle":{"color":"ink","width":0.004,"opacity":0.95,"kind":"pen"},"brushStyle":{"color":"red","width":0.005,"opacity":1,"kind":"brush"}}"#.utf8)).validated()
        XCTAssertEqual(document.tool, "brush"); XCTAssertEqual(document.penStyle, .pen); XCTAssertEqual(document.brushStyle, .init(color: "red", width: 0.005, opacity: 1))
    }

    func testLegacySliderValuesStayReachableWithoutChangingActualStroke() {
        XCTAssertEqual(NativePDFPaletteStyle.opacityRange(0.05, highlighter: true), 0.05...0.34)
        var prefs = NativePDFWorkspacePreferences()
        prefs.tool = "highlighter"; prefs.width = 0.0017; prefs.opacity = 0.05
        XCTAssertEqual(prefs.validated().width, 0.0017)
        XCTAssertEqual(prefs.drawingStyle["width"] as? Double, 0.014)
        XCTAssertEqual(prefs.drawingStyle["opacity"] as? Double, 0.05)
    }

    @MainActor
    func testAPeersPenEditsDoNotChangeAnOpenDocumentsActiveStyleAndSeedNewDocuments() {
        let suite = "NativePDFPaletteModels.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NativeWorkspaceStore(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let a = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "a.pdf", title: "A", kind: "pdf"), store: store, defaults: defaults)
        let b = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "b.pdf", title: "B", kind: "pdf"), store: store, defaults: defaults)
        b.chooseTool("highlighter"); b.chooseColor("green"); b.setWidth(0.01); b.setOpacity(0.2)
        a.chooseColor("violet"); a.setWidth(0.0073); a.setOpacity(0.65)
        XCTAssertEqual(b.tool, "highlighter"); XCTAssertEqual(b.currentPreset, .init(color: "green", width: 0.01, opacity: 0.2))
        a.setShapeRecognition(false)
        XCTAssertFalse(b.shapeRecognitionEnabled)
        let c = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "c.pdf", title: "C", kind: "pdf"), store: store, defaults: defaults)
        XCTAssertFalse(c.shapeRecognitionEnabled); XCTAssertEqual(c.currentPreset, a.currentPreset)
    }

    @MainActor
    func testBallpointKeepsItsOwnStyleAndStampsFixedWidth() throws {
        let suite = "NativePDFPaletteBallpoint.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NativeWorkspaceStore(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let doc = NativeDocumentReference(courseID: "c", relativePath: "a.pdf", title: "A", kind: "pdf")
        let model = NativePDFWorkspaceModel(document: doc, store: store, defaults: defaults)
        model.chooseColor("red"); model.setWidth(0.012)
        model.chooseTool("ballpoint")
        XCTAssertEqual(model.currentPreset, .ballpoint); XCTAssertTrue(model.isPenLike); XCTAssertTrue(model.isInkTool)
        model.chooseColor("blue"); model.setWidth(0.002)
        model.chooseTool("pen"); XCTAssertEqual(model.currentPreset, .init(color: "red", width: 0.012, opacity: 0.95))
        model.chooseTool("ballpoint"); XCTAssertEqual(model.currentPreset, .init(color: "blue", width: 0.002, opacity: 1))
        let reopened = NativePDFWorkspaceModel(document: doc, store: store, defaults: defaults)
        XCTAssertEqual(reopened.tool, "ballpoint"); XCTAssertEqual(reopened.penKind, "ballpoint"); XCTAssertEqual(reopened.currentPreset, model.currentPreset)
        reopened.chooseTool("pen"); XCTAssertEqual(reopened.currentPreset, .init(color: "red", width: 0.012, opacity: 0.95))
        let other = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "b.pdf", title: "B", kind: "pdf"), store: store, defaults: defaults)
        other.chooseTool("ballpoint"); XCTAssertEqual(other.currentPreset, .init(color: "blue", width: 0.002, opacity: 1), "recentBallpoint seeds new documents")

        var preferences = NativePDFWorkspacePreferences(); preferences.tool = "ballpoint"
        XCTAssertEqual(preferences.drawingStyle["fixedWidth"] as? Bool, true)
        preferences.tool = "pen"; XCTAssertNil(preferences.drawingStyle["fixedWidth"])
        preferences.lassoMode = "weird"; XCTAssertEqual(preferences.validated().lassoMode, "freeform")
        let legacy = try JSONDecoder().decode(NativePDFPalettePreferences.self, from: Data(#"{"version":2,"favorites":[],"drawAndHold":true}"#.utf8))
        XCTAssertEqual(legacy.recentBallpoint, .ballpoint)

        XCTAssertEqual(try NativePDFRepositoryValidation.style(["color": "ink", "width": 0.003, "opacity": 1, "fixedWidth": true])["fixedWidth"] as? Bool, true)
        XCTAssertNil(try NativePDFRepositoryValidation.style(["color": "ink", "width": 0.003, "opacity": 1, "fixedWidth": false])["fixedWidth"])
        XCTAssertThrowsError(try NativePDFRepositoryValidation.style(["color": "ink", "width": 0.003, "opacity": 1, "fixedWidth": "yes"]))
        let style = try JSONDecoder().decode(NativePDFInkStyle.self, from: Data(#"{"color":"ink","width":0.003,"opacity":1}"#.utf8))
        XCTAssertNil(style.fixedWidth)
        let input = NativePDFStrokeInput(courseId: "c", relPath: "a.pdf", page: 1, kind: "ink", data: .init(points: [.init(x: 0.1, y: 0.1, p: 0.5)], inkVersion: 5),
                                         style: .init(color: "ink", width: 0.003, opacity: 1, fixedWidth: true), clientMutationId: UUID().uuidString)
        XCTAssertEqual((try NativePDFHost.json(input)["style"] as? [String: Any])?["fixedWidth"] as? Bool, true)
    }

    @MainActor
    func testRetapOpensTheToolsOptionsAndDoesNotMutateStyle() {
        let suite = "NativePDFPaletteRetap.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NativeWorkspaceStore(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "a.pdf", title: "A", kind: "pdf"), store: store, defaults: defaults)
        let original = model.currentPreset
        model.chooseTool("pen"); XCTAssertTrue(model.showStyle); XCTAssertEqual(model.currentPreset, original)
        model.chooseTool("pen"); XCTAssertFalse(model.showStyle)
        model.chooseColor("ink"); XCTAssertTrue(model.showStyle)
        model.showStyle = false; model.chooseWidthSlot(1); XCTAssertEqual(model.editingWidthSlot, 1); XCTAssertFalse(model.showStyle)
        model.chooseTool("highlighter"); model.setOpacity(0.9)
        XCTAssertEqual(model.opacity, 0.34)
        for tool in ["eraser", "lasso", "tape"] {
            model.chooseTool(tool); XCTAssertFalse(model.showStyle, tool); model.chooseTool(tool); XCTAssertTrue(model.showStyle, tool)
        }
        for tool in ["select", "laser", "comment", "text"] {
            model.chooseTool(tool); model.chooseTool(tool); XCTAssertFalse(model.showStyle, tool)
        }
        model.chooseTool("rect"); XCTAssertEqual(model.tool, "text")
    }

    @MainActor
    func testThePlainPenIsTheFirstAndDefaultPenTypeAndWritesAsBeforeThePenTypes() {
        let suite = "NativePDFPalettePlainPen.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NativeWorkspaceStore(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "a.pdf", title: "A", kind: "pdf"), store: store, defaults: defaults)
        XCTAssertEqual(NativePDFPenPreset.kinds.first, "pen")
        XCTAssertEqual(model.tool, "pen"); XCTAssertEqual(model.penKind, "pen")
        XCTAssertEqual(model.currentPreset, .init(color: "ink", width: 0.004, opacity: 0.95), "The pen of a new document, as before the pen types")
        XCTAssertEqual(model.widthSlots, [2, 5, 8]); XCTAssertEqual(model.colorSlots, ["ink", "blue", "red", "green"])
        // Its stroke: the first pen's V4 ink, widened so a step draws as thick as it did with V5; pressure on (no fixed width).
        let preferences = NativePDFWorkspacePreferences()
        XCTAssertEqual(preferences.tool, "pen")
        XCTAssertEqual(preferences.drawingStyle["color"] as? String, "ink")
        XCTAssertEqual(preferences.drawingStyle["width"] as? Double ?? 0, 0.004 * NativePDFPaletteStyle.penWidthScale, accuracy: 1e-12)
        XCTAssertEqual(NativePDFInkSurface.Tool().inkVersion, 5, "Only the workspace's plain 펜 asks for V4")
        XCTAssertEqual(preferences.drawingStyle["opacity"] as? Double, 0.95); XCTAssertEqual(Set(preferences.drawingStyle.keys), ["color", "width", "opacity"])
        XCTAssertFalse(NativePDFInkSurface.Tool().brush)
        // Away to another pen type or tool and back: the plain pen and its style return.
        model.chooseColor("blue"); model.choosePenKind("brush"); model.chooseTool("eraser"); model.choosePenKind("pen")
        XCTAssertEqual(model.tool, "pen"); XCTAssertEqual(model.currentPreset, .init(color: "blue", width: 0.004, opacity: 0.95))
    }

    @MainActor
    func testBrushIsAPenTypeWithItsOwnStyleWidthScaleAndPressureCurve() throws {
        let suite = "NativePDFPaletteBrush.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NativeWorkspaceStore(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "a.pdf", title: "A", kind: "pdf"), store: store, defaults: defaults)
        model.chooseTool("brush"); XCTAssertTrue(model.isPenLike); XCTAssertEqual(model.currentPreset, .brush); XCTAssertEqual(model.penKind, "brush")
        model.showStyle = true; model.choosePenKind("pen")
        XCTAssertEqual(model.tool, "pen"); XCTAssertTrue(model.showStyle, "A pen type picked in the pen settings leaves them open")
        model.choosePenKind("brush"); XCTAssertTrue(model.showStyle); model.chooseColor("green")
        model.chooseTool("eraser"); model.choosePen(); XCTAssertEqual(model.tool, "brush", "The 펜 button returns to the type used last"); XCTAssertEqual(model.color, "green")
        let stored = NativePDFPalettePreferences.load(root: store.root, defaults: defaults)
        XCTAssertEqual(stored.recentBrush.color, "green")
        XCTAssertEqual(try JSONDecoder().decode(NativePDFPalettePreferences.self, from: JSONEncoder().encode(stored)), stored)
        let old = try JSONDecoder().decode(NativePDFPalettePreferences.self, from: Data(#"{"version":2,"drawAndHold":true}"#.utf8))
        XCTAssertEqual(old.recentBrush, .brush)
        XCTAssertEqual(old.tapePageOnly, true); XCTAssertFalse(old.lassoInkOnly); XCTAssertFalse(old.eraserHighlighterOnly); XCTAssertFalse(old.highlighterStraight)

        // 붓 is ordinary ink: a wider stroke and its own pressure curve, no new stored field.
        var preferences = NativePDFWorkspacePreferences(); preferences.tool = "brush"; preferences.width = 0.005
        XCTAssertEqual(preferences.drawingStyle["width"] as? Double ?? 0, 0.008, accuracy: 1e-12); XCTAssertNil(preferences.drawingStyle["fixedWidth"])
        XCTAssertEqual(Set(preferences.drawingStyle.keys), ["color", "width", "opacity"])
        XCTAssertEqual(preferences.validated().tool, "brush")
        XCTAssertEqual(NativePDFInkSurface.brushPressure(0), 0); XCTAssertEqual(NativePDFInkSurface.brushPressure(0.4), 1)
        XCTAssertEqual(NativePDFInkSurface.brushPressure(0.2), pow(0.5, 1.8), accuracy: 1e-9)
        XCTAssertLessThan(NativePDFInkSurface.brushPressure(0.04), 0.03, "A light touch draws a hairline")
    }

    @MainActor
    func testToolOptionsAreSharedAndTheMemoStampReadsTodayAndYesterday() {
        let suite = "NativePDFPaletteOptions.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NativeWorkspaceStore(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let a = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "a.pdf", title: "A", kind: "pdf"), store: store, defaults: defaults)
        let b = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "b.pdf", title: "B", kind: "pdf"), store: store, defaults: defaults)
        a.setEraserHighlighterOnly(true); a.setLassoInkOnly(true); a.setTapePageOnly(false); a.setHighlighterStraight(true)
        XCTAssertTrue(b.palette.eraserHighlighterOnly); XCTAssertTrue(b.palette.lassoInkOnly); XCTAssertFalse(b.palette.tapePageOnly); XCTAssertTrue(b.palette.highlighterStraight)
        XCTAssertEqual(a.palette.tapeColor, "yellow", "New tape is the design's amber")

        let calendar = Calendar.current, now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 15))!
        let ko = Locale(identifier: "ko-KR")
        XCTAssertEqual(NativePDFCommentPopover.stamp(calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9, minute: 10)), ko, now: now), "오늘 09:10")
        XCTAssertEqual(NativePDFCommentPopover.stamp(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 14, minute: 20)), ko, now: now), "어제 14:20")
        XCTAssertTrue(NativePDFCommentPopover.stamp(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 8, minute: 5)), ko, now: now).hasSuffix(" 08:05"))
    }

    @MainActor
    func testSwatchesAreTheSameRGBAsNativeInkInBothAppearances() {
        for item in NativePDFWorkspaceModel.colors {
            for appearance in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: appearance)
                let shown = UIColor(item.color).resolvedColor(with: traits)
                let drawn = NativePDFInkSurface.color(item.name).resolvedColor(with: traits)
                var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
                var dr: CGFloat = 0, dg: CGFloat = 0, db: CGFloat = 0, da: CGFloat = 0
                XCTAssertTrue(shown.getRed(&sr, green: &sg, blue: &sb, alpha: &sa))
                XCTAssertTrue(drawn.getRed(&dr, green: &dg, blue: &db, alpha: &da))
                XCTAssertEqual(sr, dr, accuracy: 0.0001); XCTAssertEqual(sg, dg, accuracy: 0.0001); XCTAssertEqual(sb, db, accuracy: 0.0001)
                XCTAssertEqual(sa, da, accuracy: 0.0001)
            }
        }
    }

    /// The pill sits on the page's centre while its room allows, otherwise right of the thumbnails button,
    /// and it is placed by layout alone: the same answers the window used to work out from the pill's measured frame.
    func testThePillIsPlacedOnThePageCentreAsFarAsItsRoomAllows() {
        let bias = (NativePDFFloatingPalette.trailingReserve - NativePDFFloatingPalette.leadingReserve) / 2
        XCTAssertEqual(bias, -41)
        func origin(_ width: CGFloat, room: CGFloat = 600, bias: CGFloat = bias) -> CGFloat { NativePDFPalettePlacement.origin(width: width, room: 0...room, bias: bias) }
        XCTAssertEqual(origin(300), 109, "Room to spare: the pill's middle is the page's, 41 pt left of the room's")
        XCTAssertEqual(origin(560), 0, "20 pt each side is less than the 41 pt it would move: it keeps to the room's left edge")
        XCTAssertEqual(origin(600), 0)
        XCTAssertEqual(origin(700), 0, "A row wider than its room starts at the left edge, clear of the thumbnails button")
        XCTAssertEqual(origin(300, bias: 0), 150, "A pane's own palette sits on the middle of its room")
        XCTAssertEqual(origin(93), 212.5, "The collapsed pill")
        // What the offset from the measured frame gave: the room's left edge, plus the spare room, less what it moved toward the page's centre.
        for width in stride(from: CGFloat(80), through: 640, by: 7) {
            let spare = max(0, 600 - width) / 2
            XCTAssertEqual(origin(width), spare - min(spare, 41), accuracy: 0.001, "\(width)")
        }
    }

    /// The row an 11-inch iPad gives a PDF with both side panels open: narrower than any the suites ran at on the
    /// 13-inch simulator, and the only one that slides its colours or scrolls whole. 1.4.2 (30) hung there on iPadOS 27.
    func testTheRowBetweenBothPanelsSlidesItsColoursOnAnElevenInchPadAndFitsWholeOnAThirteenInchOne() {
        func room(_ window: Double) -> CGFloat {
            let chrome = NativeWorkspaceChromeLayout(width: window, leftOpen: true, rightOpen: true)
            XCTAssertTrue(chrome.leftPinned && chrome.rightPinned, "\(window)")
            let centre = CGFloat(window - 48 - 2 - chrome.leftWidth - chrome.rightWidth)
            return centre - NativeDockCard.inset * 2 - NativePDFFloatingPalette.leadingReserve - NativePDFFloatingPalette.trailingReserve
        }
        XCTAssertEqual(room(1376), 616); XCTAssertEqual(room(1210), 450); XCTAssertEqual(room(1194), 434); XCTAssertEqual(room(1180), 420)
        let wide = NativePDFFloatingPalette.stage(fitting: room(1376), slots: 3)
        XCTAssertEqual(wide?.tools, 5.5); XCTAssertNil(wide?.colors, "13-inch: every tool cell and every colour")
        let narrow = NativePDFFloatingPalette.stage(fitting: room(1210), slots: 3)
        XCTAssertEqual(narrow?.tools, 2.5); XCTAssertEqual(narrow?.colors, 1, "11-inch Pro (M4 and later): the colours slide in a strip one swatch wide")
        XCTAssertNil(NativePDFFloatingPalette.stage(fitting: room(1194), slots: 3), "11-inch Pro before the M4: the whole row scrolls")
        XCTAssertNil(NativePDFFloatingPalette.stage(fitting: room(1180), slots: 3), "11-inch Air: the whole row scrolls")
        // A panel dragged narrower gives the older 11-inch Pro the sliding colours too.
        let dragged = NativeWorkspaceChromeLayout(width: 1194, leftOpen: true, rightOpen: true, leftRequested: 200, rightRequested: 320)
        let span = CGFloat(1194 - 48 - 2 - dragged.leftWidth - dragged.rightWidth) - NativeDockCard.inset * 2 - NativePDFFloatingPalette.leadingReserve - NativePDFFloatingPalette.trailingReserve
        XCTAssertEqual(NativePDFFloatingPalette.stage(fitting: span, slots: 3)?.colors, 2)
    }

    func testAStripFadesOnlyTheEdgesThatHaveCellsBeyondThem() {
        typealias Edges = NativePDFPaletteStripEdges
        // One swatch and the start of the next in view (42 pt), three swatches in all (98 pt).
        XCTAssertEqual(Edges.resolve(offset: 0, container: 42, content: 98), Edges(leading: false, trailing: true))
        XCTAssertEqual(Edges.resolve(offset: 30, container: 42, content: 98), Edges(leading: true, trailing: true))
        XCTAssertEqual(Edges.resolve(offset: 56, container: 42, content: 98), Edges(leading: true, trailing: false))
        XCTAssertEqual(Edges.resolve(offset: 0, container: 98, content: 98), Edges(), "Cells that all fit fade neither edge")
        XCTAssertEqual(Edges.resolve(offset: 0.5, container: 97.5, content: 98), Edges(), "Half a point is not another cell")
        XCTAssertEqual(Edges.resolve(offset: 0, container: 42, content: 0), Edges(), "A strip not laid out yet")
    }
}
