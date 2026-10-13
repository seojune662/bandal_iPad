import QuickLook
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
}
