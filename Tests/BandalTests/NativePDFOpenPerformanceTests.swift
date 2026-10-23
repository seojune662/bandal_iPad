import XCTest
import PDFKit
import CryptoKit
@testable import Bandal

/// Opt-in measurements against a local copy; never bundles private user data.
@MainActor
final class NativePDFOpenPerformanceTests: XCTestCase {
    func testPrivateDocumentSnapshotBenchmark() throws {
        guard let path = ProcessInfo.processInfo.environment["BANDAL_PRIVATE_PDF_REPLAY_DIRECTORY"], !path.isEmpty else {
            throw XCTSkip("Provide a local private replay directory to measure document ingestion")
        }
        let root = URL(fileURLWithPath: path)
        let bytes = try Data(contentsOf: root.appendingPathComponent("rows.json"))
        let parseStart = CACurrentMediaTime()
        let rows = try XCTUnwrap(DesktopJSON.decode(bytes) as? [[String: Any]])
        let parseMS = (CACurrentMediaTime() - parseStart) * 1000
        let pdf = try XCTUnwrap(PDFDocument(url: root.appendingPathComponent("paper.pdf")))
        let store = NativePDFDrawingSnapshotStore()
        let start = CACurrentMediaTime()
        let changed = try store.apply(["drawings": rows], pageCount: pdf.pageCount)
        let ingestMS = (CACurrentMediaTime() - start) * 1000
        XCTAssertEqual(store.orderedRows.count, rows.count)
        XCTAssertFalse(changed.isEmpty)
        let persistence = NativePDFPersistence(courseID: "fixture", relativePath: "paper.pdf",
            documentRevision: String(repeating: "a", count: 64), backend: { _, _ in [] }, host: { _, _ in [:] })
        persistence.receiveCoordinatedSnapshot(drawings: rows, annotations: nil, drawingIDs: nil, annotationIDs: nil)
        var next = rows
        let last = try XCTUnwrap(next.indices.last)
        let changedID = try XCTUnwrap(next[last]["id"] as? String)
        next[last]["updatedAt"] = "benchmark-peer-update"
        let peerStart = CACurrentMediaTime()
        persistence.receiveCoordinatedSnapshot(drawings: next, annotations: nil, drawingIDs: [changedID], annotationIDs: nil)
        let peerUpdateMS = (CACurrentMediaTime() - peerStart) * 1000
        XCTAssertEqual(persistence.rows.count, rows.count)
        XCTAssertEqual(persistence.rows.last?["updatedAt"] as? String, "benchmark-peer-update")
        let report: [String: Any] = ["rows": rows.count, "pages": pdf.pageCount,
            "jsonBytes": bytes.count, "parseMS": parseMS, "snapshotIngestMS": ingestMS, "peerUpdateMS": peerUpdateMS]
        print("[PDF_OPEN_BENCHMARK] " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self))
    }

    func testPrivateWorkspaceOpenAndAppendBenchmark() async throws {
        guard let path = ProcessInfo.processInfo.environment["BANDAL_PRIVATE_PDF_REPLAY_DIRECTORY"], !path.isEmpty else {
            throw XCTSkip("Provide the prepared local replay fixture to measure workspace open and page append")
        }
        let fixture = URL(fileURLWithPath: path, isDirectory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceOpenBenchmark-" + UUID().uuidString)
        var canRemoveRoot = true
        defer { if canRemoveRoot { try? FileManager.default.removeItem(at: root) } }
        // Parsing and encoding thousands of fixture rows are setup work, never
        // part of the measured user interaction. No source backup is modified.
        let prepared = try Self.prepareWorkspaceReplay(fixture: fixture, root: root)
        let store = NativeWorkspaceStore(storageRoot: root)
        await store.start()
        XCTAssertTrue(store.isReady)
        await store.selectCourse(prepared.course)
        let sceneDeadline = CACurrentMediaTime() + 5
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }), CACurrentMediaTime() < sceneDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible(); window.layoutIfNeeded(); controller.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let suite = "WorkspaceOpenBenchmark-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        weak var closingModel: NativePDFWorkspaceModel?
        var failure: Error?
        do {
            let document = NativeDocumentReference(courseID: prepared.course, relativePath: "paper.pdf", title: "Replay", kind: "pdf")
            let model = NativePDFWorkspaceModel(document: document, store: store, defaults: defaults)
            closingModel = model
            defer { model.close() }
            model.setAvailableWidth(controller.view.bounds.width)
            let openStart = CACurrentMediaTime()
            model.attach(to: controller.view)
            model.layout(controller.view.bounds)
            let openDeadline = openStart + 120
            while model.isLoading, model.errorMessage == nil, CACurrentMediaTime() < openDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let openMS = (CACurrentMediaTime() - openStart) * 1000
            XCTAssertNil(model.errorMessage, "Opening the copied fixture must succeed")
            XCTAssertFalse(model.isLoading, "Workspace open exceeded the benchmark safety timeout")
            guard model.errorMessage == nil, !model.isLoading else { throw ReplayFailure.open }
            XCTAssertEqual(model.pageCount, prepared.pages)
            XCTAssertEqual(model.drawingCount, prepared.rows, "All original ink must be available after opening")
            let original = root.appendingPathComponent("PDFOriginals/" + prepared.digest + ".pdf")
            XCTAssertEqual(try Self.digest(original), prepared.digest, "Opening must preserve the original material copy")

            let appendStart = CACurrentMediaTime()
            model.addPage(after: model.pageCount)
            let appendDeadline = appendStart + 120
            while (model.isBusy || model.isLoading || model.pageCount != prepared.pages + 1), model.errorMessage == nil, CACurrentMediaTime() < appendDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let appendMS = (CACurrentMediaTime() - appendStart) * 1000
            XCTAssertNil(model.errorMessage, "Appending to the copied fixture must not produce a conflict")
            XCTAssertFalse(model.isBusy || model.isLoading, "Page append exceeded the benchmark safety timeout")
            XCTAssertEqual(model.pageCount, prepared.pages + 1)
            guard model.errorMessage == nil, !model.isBusy, !model.isLoading, model.pageCount == prepared.pages + 1 else { throw ReplayFailure.append }
            XCTAssertEqual(model.drawingCount, prepared.rows, "Page append must preserve all existing ink")
            XCTAssertEqual(PDFDocument(url: prepared.url)?.pageCount, prepared.pages + 1)
            XCTAssertEqual(try Self.digest(original), prepared.digest, "The recovery original must remain unchanged after append")
            XCTAssertNotEqual(try Self.digest(prepared.url), prepared.digest)
            try await store.flushDocuments()
            let report: [String: Any] = ["rows": prepared.rows, "beforePages": prepared.pages, "afterPages": model.pageCount,
                "openMS": openMS, "appendMS": appendMS, "errors": 0]
            print("[PDF_WORKSPACE_BENCHMARK] " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self))
        } catch { failure = error }
        // close() owns its save barrier. Wait for its store registration to
        // release the model before deleting this temporary, copied fixture.
        let closeDeadline = CACurrentMediaTime() + 10
        while closingModel != nil, CACurrentMediaTime() < closeDeadline { try await Task.sleep(for: .milliseconds(20)) }
        canRemoveRoot = closingModel == nil
        if let failure { throw failure }
        XCTAssertNil(closingModel, "The benchmark's editor must complete its close barrier")
    }

    func testPrivateCourseSwitchReopenBenchmark() async throws {
        guard let path = ProcessInfo.processInfo.environment["BANDAL_PRIVATE_PDF_REPLAY_DIRECTORY"], !path.isEmpty else {
            throw XCTSkip("Provide the prepared local replay fixture to measure course-switch reopen")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CourseReopenBenchmark-" + UUID().uuidString)
        var canRemoveRoot = false
        defer { if canRemoveRoot { try? FileManager.default.removeItem(at: root) } }
        let prepared = try Self.prepareWorkspaceReplay(fixture: URL(fileURLWithPath: path), root: root)
        let store = NativeWorkspaceStore(storageRoot: root)
        await store.start(); XCTAssertTrue(store.isReady)
        try await store.createCourse(name: "Other subject")
        let otherCourse = try XCTUnwrap(store.selectedCourseID)
        let sceneDeadline = CACurrentMediaTime() + 5
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }), CACurrentMediaTime() < sceneDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded(); controller.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let suite = "CourseReopenBenchmark-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        weak var closingModel: NativePDFWorkspaceModel?
        func openOnce() async throws -> Double {
            let reference = NativeDocumentReference(courseID: prepared.course, relativePath: "paper.pdf", title: "Replay", kind: "pdf")
            let model = NativePDFWorkspaceModel(document: reference, store: store, defaults: defaults)
            closingModel = model
            defer { model.close() }
            model.setAvailableWidth(controller.view.bounds.width)
            let start = CACurrentMediaTime()
            model.attach(to: controller.view); model.layout(controller.view.bounds)
            while model.isLoading, model.errorMessage == nil, CACurrentMediaTime() < start + 120 {
                try await Task.sleep(for: .milliseconds(20))
            }
            let elapsed = (CACurrentMediaTime() - start) * 1000
            XCTAssertNil(model.errorMessage); XCTAssertFalse(model.isLoading)
            XCTAssertEqual(model.drawingCount, prepared.rows, "Every reopen must display all original ink")
            guard model.errorMessage == nil, !model.isLoading else { throw ReplayFailure.open }
            try await store.flushDocuments()
            return elapsed
        }
        var measurements: [Double] = []
        for _ in 0..<3 {
            await store.selectCourse(prepared.course)
            measurements.append(try await openOnce())
            let deadline = CACurrentMediaTime() + 10
            while closingModel != nil, CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertNil(closingModel, "Close must finish its journal barrier before switching courses")
            guard closingModel == nil else { throw ReplayFailure.open }
            await store.selectCourse(otherCourse)
        }
        XCTAssertEqual(try Self.digest(prepared.url), prepared.digest)
        let report: [String: Any] = ["rows": prepared.rows, "coldOpenMS": measurements[0], "reopenMS": Array(measurements.dropFirst()), "errors": 0]
        print("[PDF_COURSE_REOPEN_BENCHMARK] " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self))
        canRemoveRoot = true
    }

    private enum ReplayFailure: Error { case open, append }
    private struct PreparedReplay {
        let course: String
        let url: URL
        let rows: Int
        let pages: Int
        let digest: String
    }
    private static func prepareWorkspaceReplay(fixture: URL, root: URL) throws -> PreparedReplay {
        let rows = try XCTUnwrap(DesktopJSON.decode(Data(contentsOf: fixture.appendingPathComponent("rows.json"))) as? [[String: Any]])
        let context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        let library = NativeLibraryRepository(context: context)
        _ = try NativePDFRepository(context: context)
        let course = try XCTUnwrap((try library.handle("courses:create", ["name": "Replay", "color": "blue"]) as? [String: Any])?["id"] as? String)
        let folder = try context.courseFolder(course)
        let target = folder.appendingPathComponent("paper.pdf")
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("paper.pdf"), to: target)
        let pageCount = try XCTUnwrap(PDFDocument(url: target)?.pageCount)
        try context.transaction {
            for row in rows {
                let data = String(decoding: try JSONSerialization.data(withJSONObject: try XCTUnwrap(row["data"])), as: UTF8.self)
                let style = String(decoding: try JSONSerialization.data(withJSONObject: try XCTUnwrap(row["style"])), as: UTF8.self)
                _ = try context.run("INSERT INTO pdf_drawings(id,course_id,rel_path,page,kind,data_json,style_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)",
                                    [try XCTUnwrap(row["id"] as? String), course, "paper.pdf", try XCTUnwrap(row["page"]), try XCTUnwrap(row["kind"]), data, style,
                                     row["createdAt"] ?? "fixture", row["updatedAt"] ?? "fixture"])
            }
        }
        return PreparedReplay(course: course, url: target, rows: rows.count, pages: pageCount, digest: try digest(target))
    }
    private static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
