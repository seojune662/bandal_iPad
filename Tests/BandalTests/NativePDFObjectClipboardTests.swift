import XCTest
import UIKit
@testable import Bandal

@MainActor
final class NativePDFObjectClipboardTests: XCTestCase {
    func testRealStoreCopiesImageBytesAndPastesIntoAnotherCourseAfterSourceRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root)
        await store.start()
        try await store.createCourse(name: "원본 과목")
        let sourceCourse = try XCTUnwrap(store.selectedCourseID)
        let original = try XCTUnwrap(UIImage(data: imageBytes()))
        let asset = try await NativeEditorMediaImport.saveImage(original, courseID: sourceCourse, store: store)
        let row: [String: Any] = ["page": 1, "kind": "image",
            "data": ["box": ["x": 0.2, "y": 0.3, "width": 0.4, "height": 0.2], "image": ["relPath": asset.relativePath, "label": "원본 그림"]],
            "style": ["color": "ink", "width": 0.003, "opacity": 1]]
        let encoded = try await NativePDFObjectClipboard.encode([row], courseID: sourceCourse, store: store)
        XCTAssertNotNil(encoded.png.flatMap(UIImage.init(data:)))
        let resolved = try await store.invokePrivate("nativeMaterial:path", ["courseId": sourceCourse, "relPath": asset.relativePath])
        try FileManager.default.removeItem(atPath: XCTUnwrap(resolved as? String))
        try await store.createCourse(name: "받는 과목")
        let destination = try XCTUnwrap(store.selectedCourseID)
        let decoded = try await NativePDFObjectClipboard.decode(encoded.data)
        let image = try XCTUnwrap(decoded.images["0"])
        let saved = try await NativeEditorMediaImport.saveImage(image, courseID: destination, store: store)
        let placed = try NativePDFObjectClipboard.replacingAssets(in: decoded.rows, with: ["0": saved.relativePath])
        let data = try XCTUnwrap(placed.first?["data"] as? [String: Any])
        XCTAssertEqual((data["image"] as? [String: Any])?["relPath"] as? String, saved.relativePath)
        let pastedPath = try await store.invokePrivate("nativeMaterial:path", ["courseId": destination, "relPath": saved.relativePath])
        XCTAssertNotNil(UIImage(contentsOfFile: try XCTUnwrap(pastedPath as? String)))
        XCTAssertNotEqual(sourceCourse, destination)
    }
    func testMixedSelectionKeepsInkAndImageGeometryAndRewritesCourseAssetOwnership() throws {
        let png = try imageBytes()
        let style: [String: Any] = ["color": "blue", "width": 0.003, "opacity": 1]
        let ink: [String: Any] = ["id": "must-not-reuse", "page": 1, "kind": "ink", "data": ["inkVersion": 5,
            "points": [["x": 0.2, "y": 0.3, "p": 0.37, "t": 12.3], ["x": 0.4, "y": 0.5, "p": 0.83, "t": 25.4]]], "style": style]
        let image: [String: Any] = ["id": "old-image", "courseId": "source-course", "page": 1, "kind": "image",
            "data": ["box": ["x": 0.3, "y": 0.4, "width": 0.2, "height": 0.1], "image": ["clipboardAsset": "0", "label": "그림"]], "style": style]
        let payload = try JSONSerialization.data(withJSONObject: ["version": 1, "objects": [ink, image], "assets": ["0": png.base64EncodedString()]])
        let decoded = try NativePDFObjectClipboard.decodePayload(payload)
        XCTAssertEqual(decoded.rows.count, 2); XCTAssertEqual(decoded.images.count, 1)
        let placed = try NativePDFObjectClipboard.replacingAssets(in: decoded.rows, with: ["0": "assets/new-image.png"])
        XCTAssertNil(placed[0]["id"]); XCTAssertNil(placed[1]["id"]); XCTAssertNil(placed[1]["courseId"])
        XCTAssertEqual(placed[0]["data"] as? NSDictionary, ink["data"] as? NSDictionary)
        let imageData = try XCTUnwrap(placed[1]["data"] as? [String: Any])
        XCTAssertEqual(imageData["box"] as? NSDictionary, (image["data"] as? [String: Any])?["box"] as? NSDictionary)
        XCTAssertEqual((imageData["image"] as? [String: Any])?["relPath"] as? String, "assets/new-image.png")
        XCTAssertNil((imageData["image"] as? [String: Any])?["clipboardAsset"])
    }
    func testMissingImagePayloadCannotPasteAReferenceToAnotherCoursesFiles() throws {
        let row: [String: Any] = ["page": 1, "kind": "image",
            "data": ["box": ["x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2], "image": ["relPath": "assets/private.png", "label": "private"]],
            "style": ["color": "ink", "width": 0.003, "opacity": 1]]
        let missing = try JSONSerialization.data(withJSONObject: ["version": 1, "objects": [row], "assets": [:]])
        XCTAssertThrowsError(try NativePDFObjectClipboard.decodePayload(missing))
        XCTAssertThrowsError(try NativePDFObjectClipboard.replacingAssets(in: [row], with: [:]))
    }
    private func imageBytes() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }
        return try XCTUnwrap(image.pngData())
    }
}
