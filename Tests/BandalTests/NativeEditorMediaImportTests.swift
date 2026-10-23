import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import Bandal

@MainActor
final class NativeEditorMediaImportTests: XCTestCase {
    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 160, height: 80)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 80))
        }
    }
    func testPhotosProviderLoadsRealPixelsAndFilesProviderReleasesOriginal() async throws {
        let photo = try await NativeEditorMediaImport.load(NSItemProvider(object: image()), imagesOnly: true)
        XCTAssertNotNil(photo.image)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("한글 사진.png")
        try photo.data.write(to: file)
        let provider = NSItemProvider(object: file as NSURL)
        let loaded = try await NativeEditorMediaImport.load(provider, imagesOnly: true)
        try FileManager.default.removeItem(at: file)
        XCTAssertNotNil(UIImage(data: loaded.data), "Drop owns its data after the file provider revokes the URL")
    }
    func testInvalidImageAndFolderDoNotEnterPDF() throws {
        XCTAssertThrowsError(try NativeEditorMediaImport.decoded(Data("not pixels".utf8), name: "fake.png", type: .png, imagesOnly: true))
        XCTAssertThrowsError(try NativeEditorMediaImport.readFile(FileManager.default.temporaryDirectory, imagesOnly: false))
        let file = try NativeEditorMediaImport.decoded(Data("plain attachment".utf8), name: "memo.txt", type: .plainText, imagesOnly: false)
        XCTAssertNil(file.image)
    }
    func testDroppedAssetUsesDocumentCourseAndSurvivesSourceDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root)
        await store.start()
        try await store.createCourse(name: "받는 문서")
        let destination = try XCTUnwrap(store.selectedCourseID)
        try await store.createCourse(name: "현재 선택된 다른 과목")
        let saved = try await NativeEditorMediaImport.saveImage(image(), courseID: destination, store: store)
        let path = try await store.invokePrivate("nativeMaterial:path", ["courseId": destination, "relPath": saved.relativePath])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(path as? String)))
        XCTAssertNotNil(UIImage(data: bytes))
        XCTAssertNotEqual(store.selectedCourseID, destination)
        let another = try await NativeEditorMediaImport.saveImage(image(), courseID: destination, store: store)
        XCTAssertNotEqual(saved.relativePath, another.relativePath, "Repeated drops must not overwrite an earlier image")
    }
    func testMarkdownImagePreparationPreservesBytesAndBoundsPreviewPixels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-image-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200), format: format).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        }
        let bytes = try XCTUnwrap(source.pngData()), file = root.appendingPathComponent("source.png")
        try bytes.write(to: file)
        let encoded = try await NativeEditorMediaImport.fileBase64(file)
        XCTAssertEqual(Data(base64Encoded: encoded), bytes)
        let direct = try await NativeEditorMediaImport.base64(bytes)
        XCTAssertEqual(direct, encoded)
        let preview = await NativeEditorMediaImport.previewImage(fileURL: file)
        XCTAssertEqual(preview?.cgImage?.width, 1600)
        XCTAssertEqual(preview?.cgImage?.height, 800)
        let invalid = await NativeEditorMediaImport.previewImage(fileURL: root)
        XCTAssertNil(invalid)
        try FileManager.default.removeItem(at: file)
        let missing = await NativeEditorMediaImport.previewImage(fileURL: file)
        XCTAssertNil(missing)
    }

    func testCancelledMarkdownPreparationDoesNotProduceAnInsertionPayload() async throws {
        let cancelled = Task { try await NativeEditorMediaImport.base64(Data(repeating: 0x61, count: 1024 * 1024)) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("A cancelled editor must not receive an insertion payload") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let preview = Task { await NativeEditorMediaImport.previewImage(data: try! XCTUnwrap(image().pngData())) }
        preview.cancel()
        let result = await preview.value
        XCTAssertNil(result)
    }

    func testMarkdownAttachmentEscapesNamesAndPreservesSourceMarkup() {
        let markup = NativeEditorMediaImport.markdownLink(name: "사진 [1].png", path: "assets/한글 (1)#?.png", image: true)
        XCTAssertTrue(markup.contains("\\[1\\]"))
        XCTAssertTrue(markup.contains("%28")); XCTAssertTrue(markup.contains("%23"))
        let document = NativeRichTextDocument(markup)
        XCTAssertEqual(document.markdown, markup)
        XCTAssertTrue(document.runs.contains { $0.styles.contains("image") })
    }

    func testInsertedPDFImageIsImmediatelySelectedAndKeepsInkStyleAfterUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-image-selection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root)
        await store.start()
        try await store.createCourse(name: "Photos")
        let document = try await store.createNote(title: "Image position", paper: "blank", orientation: "portrait")
        let suite = "pdf-image-selection-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = NativePDFWorkspaceModel(document: document, store: store, defaults: defaults)
        defer { model.close() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        model.setAvailableWidth(800)
        model.attach(to: controller.view); model.layout(controller.view.bounds)
        let deadline = Date().addingTimeInterval(10)
        while model.isLoading, model.errorMessage == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isLoading); XCTAssertNil(model.errorMessage)
        guard !model.isLoading, model.errorMessage == nil else { return }
        model.chooseTool("pen"); model.chooseColor("red"); model.setWidth(0.008)
        model.pasteImage(image(), at: CGPoint(x: 0.4, y: 0.4), page: 1)
        let inserted = Date().addingTimeInterval(10)
        while model.isBusy, model.errorMessage == nil, Date() < inserted { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.drawingCount, 1)
        XCTAssertEqual(model.tool, "select", "The image must be movable immediately after it is placed")
        XCTAssertEqual(model.selectionCount, 1, "Resize handles need an active image selection")
        try await model.flush()
        model.undo()
        let undone = Date().addingTimeInterval(10)
        while model.isBusy, model.errorMessage == nil, Date() < undone { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.drawingCount, 0)
        model.chooseTool("pen")
        XCTAssertEqual(model.color, "red"); XCTAssertEqual(model.width, 0.008)
        try await model.flush()
    }
}
