import QuickLook
import PDFKit
import UIKit
import XCTest
@testable import Bandal

@MainActor
final class DesktopTemporaryFileTests: XCTestCase {
    private func fixture() throws -> (URL, DesktopRuntime, DesktopFileServices, UIWindow, UIViewController) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        let service = DesktopFileServices(runtime: runtime), presenter = UIViewController(), window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = presenter; window.makeKeyAndVisible(); presenter.loadViewIfNeeded(); service.presenter = presenter
        return (root, runtime, service, window, presenter)
    }
    private func exportedFiles(_ root: URL) -> [URL] {
        let folder = root.appendingPathComponent("Temporary/Exports")
        return (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    func testExportCancelKeepsPreparedFileUntilPickerCompletion() async throws {
        let (root, _, service, window, presenter) = try fixture()
        defer { window.isHidden = true }
        let task = Task { try await service.handle(channel: "native:saveFile", request: ["suggestedName": "fixture.pdf", "data": Data([1, 2]).base64EncodedString()]) }
        let deadline = Date().addingTimeInterval(3)
        while presenter.presentedViewController == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let picker = try XCTUnwrap(presenter.presentedViewController as? UIDocumentPickerViewController)
        let file = try XCTUnwrap(exportedFiles(root).first)
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2]))
        service.documentPickerWasCancelled(picker)
        let result = try await task.value as! [String: Any]
        XCTAssertEqual(result["saved"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        presenter.dismiss(animated: false)
    }
    func testExportCompletionDoesNotDeleteDestinationOrOriginal() async throws {
        let (root, _, service, window, presenter) = try fixture()
        defer { window.isHidden = true }
        let destination = root.appendingPathComponent("user-saved.pdf"); try Data([8]).write(to: destination)
        let task = Task { try await service.handle(channel: "print:savePdfAs", request: ["suggestedName": "fixture.pdf", "base64": Data([1]).base64EncodedString()]) }
        let deadline = Date().addingTimeInterval(3)
        while presenter.presentedViewController == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let picker = try XCTUnwrap(presenter.presentedViewController as? UIDocumentPickerViewController), source = try XCTUnwrap(exportedFiles(root).first)
        service.documentPicker(picker, didPickDocumentsAt: [destination])
        let result = try await task.value as! [String: Any]
        XCTAssertEqual(result["canceled"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path)); XCTAssertEqual(try Data(contentsOf: destination), Data([8]))
        presenter.dismiss(animated: false)
    }
    func testQuickLookDismissCleansCopyButPreservesCourseMaterial() async throws {
        let (root, runtime, service, window, presenter) = try fixture()
        defer { window.isHidden = true }
        try await runtime.start()
        let course = try await runtime.invoke("courses:create", request: ["name": "Preview fixture", "color": "blue"]) as! [String: Any]
        let id = course["id"] as! String
        let material = try await runtime.invoke("materials:writeFile", request: ["courseId": id, "dirRelPath": "", "fileName": "preview.txt", "encoding": "utf8", "data": "original material"]) as! [String: Any]
        let path = material["relPath"] as! String
        _ = try await service.handle(channel: "materials:preview", request: ["courseId": id, "relPath": path])
        let deadline = Date().addingTimeInterval(3)
        while presenter.presentedViewController == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let preview = try XCTUnwrap(presenter.presentedViewController as? QLPreviewController)
        let file = try XCTUnwrap(service.previewController(preview, previewItemAt: 0).previewItemURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        service.previewControllerDidDismiss(preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let original = try await runtime.readMaterial(courseID: id, relativePath: path)
        XCTAssertEqual(String(data: original, encoding: .utf8), "original material")
        presenter.dismiss(animated: false)
    }
    func testLibraryPDFShareIncludesSavedInkAndKeepsOriginal() async throws {
        try await assertAnnotatedMaterial(channel: "materials:share")
    }
    func testLibraryPDFExportIncludesSavedInkAndKeepsOriginal() async throws {
        try await assertAnnotatedMaterial(channel: "materials:export")
    }
    private func assertAnnotatedMaterial(channel: String) async throws {
        let (root, runtime, service, window, presenter) = try fixture()
        defer { service.cancelPresentations(); window.isHidden = true }
        try await runtime.start()
        let course = try await runtime.invoke("courses:create", request: ["name": "Annotated export", "color": "blue"]) as! [String: Any]
        let courseID = course["id"] as! String
        let note = try await runtime.invoke("pdfNotes:create", request: ["courseId": courseID, "title": "Shared ink", "paper": "blank", "orientation": "portrait"]) as! [String: Any]
        let identity: [String: Any] = ["courseId": courseID, "relPath": note["relPath"]!]
        let original = try await runtime.readMaterial(courseID: courseID, relativePath: note["relPath"] as! String)
        _ = try await runtime.invoke("drawings:create", request: identity.merging([
            "page": 1, "kind": "ink", "data": ["inkVersion": 5, "points": [["x": 0.2, "y": 0.3, "p": 0.8], ["x": 0.8, "y": 0.6, "p": 0.8]]],
            "style": ["width": 0.03, "color": "red", "opacity": 1.0]
        ]) { _, value in value })
        let task = Task { try await service.handle(channel: channel, request: identity) }
        let deadline = Date().addingTimeInterval(10)
        while presenter.presentedViewController == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let exported = try XCTUnwrap(exportedFiles(root).first)
        let page = try XCTUnwrap(PDFDocument(url: exported)?.page(at: 0))
        let image = try XCTUnwrap(page.thumbnail(of: CGSize(width: 300, height: 424), for: .mediaBox).cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var redPixels = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
            if red > 130 && red > green + 40 && red > blue + 40 { redPixels += 1 }
        }
        XCTAssertGreaterThan(redPixels, 200, "The exact temporary file offered by the library must contain visible handwriting")
        let preserved = try await runtime.readMaterial(courseID: courseID, relativePath: note["relPath"] as! String)
        XCTAssertEqual(preserved, original)
        if let picker = presenter.presentedViewController as? UIDocumentPickerViewController { service.documentPickerWasCancelled(picker) }
        else {
            let share = try XCTUnwrap(presenter.presentedViewController as? UIActivityViewController)
            share.completionWithItemsHandler?(nil, false, nil, nil)
        }
        _ = try await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
        presenter.dismiss(animated: false)
    }
}
