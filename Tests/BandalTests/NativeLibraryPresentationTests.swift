import XCTest
import UIKit
import PDFKit
import UniformTypeIdentifiers
@testable import Bandal

final class NativeLibraryPresentationTests: XCTestCase {
    func testColumnsFollowFolderAncestorsAndStopAtMissingFolder() {
        let leaf = NativeMaterial(relPath: "강의/과제/문제.pdf", name: "문제.pdf", kind: "pdf")
        let nested = NativeMaterial(relPath: "강의/과제", name: "과제", kind: "dir", children: [leaf])
        let parent = NativeMaterial(relPath: "강의", name: "강의", kind: "dir", children: [nested])
        let unrelated = NativeMaterial(relPath: "메모.md", name: "메모.md", kind: "note")
        let columns = NativeLibraryPresentation.columns(folder: "강의/과제", materials: [unrelated, parent])
        XCTAssertEqual(columns.map(\.path), ["", "강의", "강의/과제"])
        XCTAssertEqual(columns.first?.materials, [parent, unrelated])
        XCTAssertEqual(columns.last?.materials, [leaf])
        XCTAssertEqual(NativeLibraryPresentation.columns(folder: "강의/삭제됨/아래", materials: [parent]).map(\.path), ["", "강의"])
    }

    func testSourceFilesAreCopiedAndDuplicateNamesRemainIndependent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("사진.png")
        let bytes = Data("original image bytes".utf8)
        try bytes.write(to: source)
        let staging = root.appendingPathComponent("staging")
        var first: NativeLibrarySourceAsset? = try NativeLibrarySourceAsset.stage(source, under: staging)
        let second = try NativeLibrarySourceAsset.stage(source, under: staging)
        let firstURL = try XCTUnwrap(first?.url)
        XCTAssertNotEqual(firstURL, second.url)
        XCTAssertEqual(firstURL.lastPathComponent, "사진.png")
        XCTAssertEqual(try Data(contentsOf: second.url), bytes)
        first = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes, "Tray cleanup must never delete the user's original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertThrowsError(try NativeLibrarySourceAsset.stage(root, under: staging))
    }

    func testDragProviderRetainsSourceAndExportsImageFileBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.png")
        let bytes = Data([1, 4, 9, 16])
        try bytes.write(to: source)
        var asset: NativeLibrarySourceAsset? = try NativeLibrarySourceAsset.stage(source, under: root.appendingPathComponent("staging"))
        let stagedURL = try XCTUnwrap(asset?.url)
        let provider = try XCTUnwrap(asset?.provider())
        asset = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path), "Removing a tray item cannot invalidate an active drag")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.image.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let transferred: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) { url, error in
                do { continuation.resume(returning: try Data(contentsOf: XCTUnwrap(url))) }
                catch { continuation.resume(throwing: error) }
            }
        }
        XCTAssertEqual(transferred, bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    @MainActor
    func testPDFAndImageThumbnailsRenderOffMainThreadAndCacheByRevision() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("lecture.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 450)).writePDF(to: pdf) { renderer in
            renderer.beginPage()
            UIColor.white.setFill(); renderer.cgContext.fill(CGRect(x: 0, y: 0, width: 300, height: 450))
            UIColor.blue.setFill(); renderer.cgContext.fill(CGRect(x: 30, y: 50, width: 180, height: 100))
        }
        let imageURL = root.appendingPathComponent("photo.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 800)).image { renderer in
            UIColor.red.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
        }
        try XCTUnwrap(image.pngData()).write(to: imageURL)
        let cache = NativeLibraryThumbnailCache()
        let firstPDF = await cache.image(url: pdf, revision: "1")
        let cachedPDF = await cache.image(url: pdf, revision: "1")
        let changedPDF = await cache.image(url: pdf, revision: "2")
        XCTAssertNotNil(firstPDF)
        XCTAssertTrue(firstPDF === cachedPDF)
        XCTAssertFalse(firstPDF === changedPDF, "A changed file must not keep the previous cached preview")
        let preview = await cache.image(url: imageURL, revision: "1")
        let bitmap = try XCTUnwrap(preview?.cgImage)
        XCTAssertLessThanOrEqual(max(bitmap.width, bitmap.height), 540)
    }

    @MainActor
    func testDocumentPreviewIncludesSavedObjectsAndTextHighlights() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let base = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 320), format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
        }
        let row: [String: Any] = ["id": "saved-shape", "page": 1, "kind": "rect",
                                  "data": ["box": ["x": 0.2, "y": 0.2, "width": 0.5, "height": 0.4]],
                                  "style": ["color": "#FF0000", "width": 0.02, "opacity": 1.0]]
        let annotation: [String: Any] = ["color": "blue", "rects": [["x": 0.1, "y": 0.8, "width": 0.7, "height": 0.1]]]
        let composed = NativeLibraryDocumentThumbnailCache.composite(base: base, rows: [row], annotations: [annotation], images: [:])
        XCTAssertNotEqual(composed.pngData(), base.pngData(), "Saved objects must not disappear from a blank-paper note preview")
        let objectOnly = NativeLibraryDocumentThumbnailCache.composite(base: base, rows: [row], annotations: [], images: [:])
        XCTAssertNotEqual(objectOnly.pngData(), base.pngData())
        XCTAssertNotEqual(composed.pngData(), objectOnly.pngData(), "PDF text highlights also belong in the preview")
    }

    @MainActor
    func testLibraryMaterialURLResolvesThroughNativeRuntimeAndDropsIntoEditor() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root)
        await store.start()
        try await store.createCourse(name: "자료 드래그")
        let course = try XCTUnwrap(store.selectedCourseID)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 50)).image { renderer in
            UIColor.systemTeal.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 80, height: 50))
        }
        let data = try XCTUnwrap(image.pngData())
        let value = try await store.invoke("materials:writeFile", ["courseId": course, "dirRelPath": "", "fileName": "Library.png", "encoding": "base64", "data": data.base64EncodedString()])
        let relative = try XCTUnwrap((value as? [String: Any])?["relPath"] as? String)
        let url = try await NativeLibraryMaterialAccess.url(store: store, courseID: course, relativePath: relative)
        XCTAssertEqual(try Data(contentsOf: url), data)
        let provider = NativeLibraryAssetProvider.make(url: url)
        XCTAssertTrue(NativeEditorMediaImport.supports(provider, imagesOnly: true))
        let dropped = try await NativeEditorMediaImport.load(provider, imagesOnly: true)
        XCTAssertNotNil(dropped.image)
        XCTAssertEqual(dropped.name, "Library.png")
    }

    @MainActor
    func testThumbnailPageQueriesExcludeOtherPagesAndDeletedRowsWithoutChangingWholeDocumentReads() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        let library = NativeLibraryRepository(context: context)
        let pdf = try NativePDFRepository(context: context)
        let courseResult = try library.handle("courses:create", ["name": "페이지 필터", "color": "blue"])
        let course = try XCTUnwrap((courseResult as? [String: Any])?["id"] as? String)
        let created = try pdf.handle("pdfNotes:create", ["courseId": course, "title": "두 페이지", "paper": "blank", "orientation": "portrait"])
        let relative = try XCTUnwrap((created as? [String: Any])?["relPath"] as? String)
        let url = try context.materialURL(courseID: course, relativePath: relative)
        let document = try XCTUnwrap(PDFDocument(url: url))
        document.insert(try XCTUnwrap(document.page(at: 0)?.copy() as? PDFPage), at: 1)
        XCTAssertTrue(document.write(to: url))
        let identity: [String: Any] = ["courseId": course, "relPath": relative]
        var drawingIDs: [String] = []
        for page in 1...2 {
            var drawing = identity
            drawing["page"] = page; drawing["kind"] = "rect"
            drawing["data"] = ["box": ["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.2]]
            drawing["style"] = ["color": "blue", "width": 0.004, "opacity": 1.0]
            let saved = try pdf.handle("drawings:create", drawing)
            drawingIDs.append(try XCTUnwrap((saved as? [String: Any])?["id"] as? String))
            var annotation = identity
            annotation["page"] = page; annotation["color"] = "yellow"
            annotation["rects"] = [["x": 0.1, "y": 0.7, "width": 0.3, "height": 0.05]]
            annotation["anchor"] = ["quote": "page", "prefix": "", "suffix": ""]
            _ = try pdf.handle("annotations:create", annotation)
        }
        XCTAssertEqual(try pdf.listDrawings(identity).count, 2)
        XCTAssertEqual(try pdf.listAnnotations(identity).count, 2)
        var firstPage = identity; firstPage["page"] = 1
        XCTAssertEqual(try pdf.listDrawings(firstPage).map { $0["id"] as? String }, [drawingIDs[0]])
        XCTAssertEqual(try pdf.listAnnotations(firstPage).map { ($0["page"] as? NSNumber)?.intValue }, [1])
        _ = try pdf.handle("drawings:delete", ["ids": [drawingIDs[0]]])
        XCTAssertTrue(try pdf.listDrawings(firstPage).isEmpty)
        XCTAssertEqual(try pdf.listDrawings(identity).map { $0["id"] as? String }, [drawingIDs[1]])
        var invalid = identity; invalid["page"] = 0
        XCTAssertThrowsError(try pdf.listDrawings(invalid))
        XCTAssertThrowsError(try pdf.listAnnotations(invalid))
    }

    @MainActor
    func testPDFDragExportsPendingInkInsteadOfOriginalFileURL() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root)
        await store.start()
        try await store.createCourse(name: "필기 드래그")
        let course = try XCTUnwrap(store.selectedCourseID)
        let result = try await store.invoke("pdfNotes:create", ["courseId": course, "title": "Drag ink", "paper": "blank", "orientation": "portrait"])
        let relative = try XCTUnwrap((result as? [String: Any])?["relPath"] as? String)
        let url = try await NativeLibraryMaterialAccess.url(store: store, courseID: course, relativePath: relative)
        let original = try Data(contentsOf: url)
        var saves = 0
        let token = store.registerDocumentFlush(id: course + ":" + relative) {
            saves += 1
            _ = try await store.invoke("drawings:create", [
                "courseId": course, "relPath": relative, "page": 1, "kind": "ink",
                "data": ["inkVersion": 5, "points": [["x": 0.2, "y": 0.3, "p": 0.8], ["x": 0.8, "y": 0.6, "p": 0.8]]],
                "style": ["width": 0.03, "color": "red", "opacity": 1.0]
            ])
        }
        defer { store.unregisterDocumentFlush(token) }
        let provider = NativeLibraryPDFDragExport.provider(store: store, document: .init(
            courseID: course, relativePath: relative, title: "Drag ink", kind: "pdf"))
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                       "Receivers must not be able to bypass the annotated file")
        let data = try await droppedPDF(provider)
        XCTAssertEqual(saves, 1, "The provider must flush edits before preparing the drag")
        let secondRead = try await droppedPDF(provider)
        XCTAssertEqual(data, secondRead)
        XCTAssertEqual(saves, 1, "A receiver can request the same representation more than once")
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let image = try XCTUnwrap(page.thumbnail(of: CGSize(width: 300, height: 424), for: .mediaBox).cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var redPixels = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
            if red > 130 && red > green + 40 && red > blue + 40 { redPixels += 1 }
        }
        XCTAssertGreaterThan(redPixels, 200, "The drag payload must contain visible handwriting")
        XCTAssertEqual(try Data(contentsOf: url), original, "Exporting must preserve the source PDF")
    }

    @MainActor
    func testPDFDragReportsSaveFailureWithoutFallingBackToOriginal() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root)
        let token = store.registerDocumentFlush(id: "pending-ink") { throw DesktopRuntimeError("저장 실패") }
        defer { store.unregisterDocumentFlush(token) }
        let provider = NativeLibraryPDFDragExport.provider(store: store, document: .init(
            courseID: "course", relativePath: "paper.pdf", title: "Paper", kind: "pdf"))
        do { _ = try await droppedPDF(provider); XCTFail("A failed save must fail the drag") }
        catch {}
    }

    private func droppedPDF(_ provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                do {
                    guard let url else { throw error ?? DesktopRuntimeError("PDF가 전달되지 않았습니다.") }
                    continuation.resume(returning: try Data(contentsOf: url))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
