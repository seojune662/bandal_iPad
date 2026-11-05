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

    func testV1FavoritesAndBetweenStepValuesMigrateAndSharedEditsDoNotClobberSlots() throws {
        let suite = "NativePDFPaletteTests.\(UUID())", root = URL(fileURLWithPath: "/palette-test")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = NativePDFPalettePreferences.key(root: root)
        defaults.set(Data(#"{"version":1,"presets":[{"color":"violet","width":0.0317,"opacity":0.05}],"drawAndHold":false}"#.utf8), forKey: key.replacingOccurrences(of: ".v2.", with: ".v1."))
        let old = NativePDFPalettePreferences.load(root: root, defaults: defaults)
        XCTAssertEqual(old.favorites[0], .init(color: "violet", width: 0.0317, opacity: 0.05))
        XCTAssertEqual(old.recentPen, old.favorites[0]); XCTAssertEqual(old.recentHighlighter, .highlighter)
        XCTAssertFalse(old.drawAndHold)
        NativePDFPalettePreferences.update(root: root, defaults: defaults) { $0.favorites[1] = .init(color: "orange", width: 0.0067, opacity: 0.7) }
        let latest = NativePDFPalettePreferences.update(root: root, defaults: defaults) { $0.favorites[2] = .init(color: "green", width: 0.004, opacity: 0.5) }
        XCTAssertEqual(latest.favorites[0], old.favorites[0]); XCTAssertEqual(latest.favorites[1].color, "orange")
        XCTAssertEqual(latest.favorites[2].color, "green"); XCTAssertFalse(latest.drawAndHold)
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

    func testMalformedFavoriteDoesNotDiscardOtherUserSlots() throws {
        let value = try JSONDecoder().decode(NativePDFPalettePreferences.self, from: Data(#"{"version":2,"favorites":[{"width":"broken"},{"color":"green","width":0.0073,"opacity":0.5},{"color":"violet","width":0.04,"opacity":0.05}]}"#.utf8))
        XCTAssertEqual(value.favorites[0], .pen)
        XCTAssertEqual(value.favorites[1], .init(color: "green", width: 0.0073, opacity: 0.5))
        XCTAssertEqual(value.favorites[2], .init(color: "violet", width: 0.04, opacity: 0.05))
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
    func testFavoritesPropagateWithoutChangingPeerActiveStyleAndSelectPenExplicitly() {
        let suite = "NativePDFPaletteModels.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NativeWorkspaceStore(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let a = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "a.pdf", title: "A", kind: "pdf"), store: store, defaults: defaults)
        let b = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "b.pdf", title: "B", kind: "pdf"), store: store, defaults: defaults)
        b.chooseTool("highlighter"); b.chooseColor("green"); b.setWidth(0.01); b.setOpacity(0.2)
        a.chooseColor("violet"); a.setWidth(0.0073); a.setOpacity(0.65); a.saveFavorite(1)
        XCTAssertEqual(b.favorites[1], a.currentPreset)
        XCTAssertEqual(b.tool, "highlighter"); XCTAssertEqual(b.color, "green"); XCTAssertEqual(b.width, 0.01); XCTAssertEqual(b.opacity, 0.2)
        b.chooseFavorite(1)
        XCTAssertEqual(b.tool, "pen"); XCTAssertEqual(b.currentPreset, a.currentPreset)
        b.chooseTool("highlighter")
        XCTAssertEqual(b.currentPreset, .init(color: "green", width: 0.01, opacity: 0.2))
        b.saveFavorite(0) // Highlighter styles cannot accidentally replace a pen favorite.
        XCTAssertEqual(b.favorites[0], .pen)
        a.setShapeRecognition(false)
        XCTAssertFalse(b.shapeRecognitionEnabled)
        let c = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "c.pdf", title: "C", kind: "pdf"), store: store, defaults: defaults)
        XCTAssertFalse(c.shapeRecognitionEnabled); XCTAssertEqual(c.currentPreset, a.currentPreset)
    }

    @MainActor
    func testBallpointKeepsItsOwnStyleSharesPenFavoritesAndStampsFixedWidth() throws {
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
        model.chooseFavorite(1); XCTAssertEqual(model.tool, "ballpoint", "A favourite applies to the current pen-like tool")
        XCTAssertEqual(model.currentPreset, model.favorites[1])
        let reopened = NativePDFWorkspaceModel(document: doc, store: store, defaults: defaults)
        XCTAssertEqual(reopened.tool, "ballpoint"); XCTAssertEqual(reopened.currentPreset, model.favorites[1])
        let other = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "b.pdf", title: "B", kind: "pdf"), store: store, defaults: defaults)
        other.chooseTool("ballpoint"); XCTAssertEqual(other.currentPreset, model.favorites[1], "recentBallpoint seeds new documents")

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
    func testOnlyInkToolRetapOpensStyleAndDoesNotMutateStyle() {
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
        for tool in ["eraser", "lasso", "select", "text"] {
            model.chooseTool(tool); model.chooseTool(tool); XCTAssertFalse(model.showStyle, tool)
        }
        model.chooseTool("rect"); XCTAssertEqual(model.tool, "text")
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
}
