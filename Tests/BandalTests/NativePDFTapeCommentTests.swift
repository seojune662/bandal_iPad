import XCTest
import UIKit
@testable import Bandal

@MainActor
final class NativePDFTapeCommentTests: XCTestCase {
    private let tapeData: [String: Any] = ["points": [["x": 0.1, "y": 0.2, "p": 0.5], ["x": 0.6, "y": 0.2, "p": 0.5]]]

    func testTapeAndCommentRowsValidateAndKeepTheRevealedFlag() throws {
        XCTAssertEqual(try NativePDFRepositoryValidation.kind("tape"), "tape")
        XCTAssertEqual(try NativePDFRepositoryValidation.kind("comment"), "comment")
        XCTAssertEqual((try NativePDFRepositoryValidation.data(tapeData, kind: "tape")["points"] as? [[String: Any]])?.count, 2)
        XCTAssertThrowsError(try NativePDFRepositoryValidation.data(["points": [["x": 0.1, "y": 0.2, "p": 0.5]]], kind: "tape"), "A tape needs a band, not a dot")
        let pin: [String: Any] = ["box": ["x": 0.4, "y": 0.4, "width": 0.03, "height": 0.02], "text": "다시 볼 것"]
        XCTAssertEqual(try NativePDFRepositoryValidation.data(pin, kind: "comment")["text"] as? String, "다시 볼 것")
        XCTAssertThrowsError(try NativePDFRepositoryValidation.data(["box": pin["box"]!], kind: "comment"))
        XCTAssertEqual(try NativePDFRepositoryValidation.style(["color": "blue", "width": 0.02, "opacity": 1, "revealed": true])["revealed"] as? Bool, true)
        XCTAssertNil(try NativePDFRepositoryValidation.style(["color": "blue", "width": 0.02, "opacity": 1, "revealed": false])["revealed"])
        XCTAssertThrowsError(try NativePDFRepositoryValidation.style(["color": "blue", "width": 0.02, "opacity": 1, "revealed": "yes"]))
    }

    func testTapeCoversItsBandAndRevealedTapeShowsThePaperThrough() throws {
        let size = CGSize(width: 200, height: 200)
        func render(_ style: [String: Any]) throws -> UIColor {
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                NativePDFObjectRenderer.draw(["kind": "tape", "data": tapeData, "style": style], in: context.cgContext,
                                             mapper: .whiteboard(size: size), image: nil)
            }
            let data = try XCTUnwrap(image.cgImage?.dataProvider?.data), bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            let scale = image.scale, row = Int(40 * scale), column = Int(70 * scale), width = Int(size.width * scale)
            let offset = (row * width + column) * 4
            return UIColor(red: CGFloat(bytes[offset]) / 255, green: CGFloat(bytes[offset + 1]) / 255, blue: CGFloat(bytes[offset + 2]) / 255, alpha: 1)
        }
        var white: CGFloat = 0
        try render(["color": "blue", "width": 0.04, "opacity": 1]).getWhite(&white, alpha: nil)
        XCTAssertLessThan(white, 0.95, "Hidden tape is opaque colour")
        try render(["color": "blue", "width": 0.04, "opacity": 1, "revealed": true]).getWhite(&white, alpha: nil)
        XCTAssertGreaterThan(white, 0.85, "Peeled-back tape lets the page show")
        let bounds = try XCTUnwrap(NativePDFObjectRenderer.hitBounds(["kind": "tape", "data": tapeData, "style": ["color": "blue", "width": 0.04, "opacity": 1]], mapper: .whiteboard(size: size)))
        XCTAssertEqual(bounds.width, 100, accuracy: 1); XCTAssertEqual(bounds.height, 8, accuracy: 1)
        let geometry = try XCTUnwrap(NativePDFRetainedObjectHitTest.prepare(object: ["kind": "tape", "data": tapeData, "style": ["color": "blue", "width": 0.04, "opacity": 1]], aspect: 1))
        XCTAssertFalse(NativePDFRetainedObjectHitTest.hits(entries: [.init(savedID: "t", mutationID: nil, geometry: geometry)], points: [CGPoint(x: 0.3, y: 0.205)]).isEmpty, "The eraser removes a tape")
    }

    func testTapeSlotsAndColourAreSharedAndSeparateFromThePen() {
        let suite = "NativePDFTape.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NativeWorkspaceStore(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = NativePDFWorkspaceModel(document: .init(courseID: "c", relativePath: "a.pdf", title: "A", kind: "pdf"), store: store, defaults: defaults)
        model.chooseTool("tape")
        XCTAssertTrue(model.usesColorSlots); XCTAssertTrue(model.usesWidthSlots); XCTAssertFalse(model.isInkTool)
        XCTAssertEqual(model.widthSlots, [3, 6, 9]); XCTAssertEqual(model.selectedWidthSlot, 1)
        model.chooseColor("violet"); model.chooseWidthSlot(2)
        XCTAssertEqual(model.activeColor, "violet"); XCTAssertEqual(model.palette.tapeWidth, NativePDFPaletteStyle.tapeSteps[9])
        model.chooseTool("pen")
        XCTAssertEqual(model.color, "ink", "Tape colour never changes the pen")
        XCTAssertEqual(NativePDFPalettePreferences.load(root: store.root, defaults: defaults).tapeColor, "violet")
        for tool in ["tape", "laser", "comment"] { model.chooseTool(tool); XCTAssertEqual(model.tool, tool) }
    }
}
