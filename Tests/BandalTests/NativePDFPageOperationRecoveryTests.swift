import XCTest
import PDFKit
import Combine
@testable import Bandal

@MainActor
final class NativePDFPageOperationRecoveryTests: XCTestCase {
    func testRetryAfterDestinationSaveFailureResumesCommittedPageChange() async throws {
        try await exerciseRecovery(.destinationSave)
    }

    func testRetryAfterNewRevisionOpenFailureDoesNotRepeatCommittedMutation() async throws {
        try await exerciseRecovery(.reopen)
    }

    private enum Failure { case destinationSave, reopen }
    private func exerciseRecovery(_ failure: Failure) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PageOperationRecovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await runRecovery(failure, root: root)
    }

    private func runRecovery(_ failure: Failure, root: URL) async throws {
        let context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        let library = NativeLibraryRepository(context: context)
        let pdf = try NativePDFRepository(context: context)
        let course = try XCTUnwrap((try library.handle("courses:create", ["name": "Recovery", "color": "blue"]) as? [String: Any])?["id"] as? String)
        let created = try XCTUnwrap(try pdf.handle("pdfNotes:create", ["courseId": course, "title": "Fixture", "paper": "blank", "orientation": "portrait"]) as? [String: Any])
        let path = try XCTUnwrap(created["relPath"] as? String)
        let url = try context.materialURL(courseID: course, relativePath: path)
        let request: [String: Any] = ["courseId": course, "relPath": path]
        let binding = try pdf.checkBinding(request)
        let initialRevision = try XCTUnwrap(binding["documentRevision"] as? String)
        let data: [String: Any] = ["box": ["x": 0.2, "y": 0.2, "width": 0.3, "height": 0.2]]
        let row = try XCTUnwrap(try pdf.handle("drawings:create", request.merging([
            "page": 1, "kind": "rect", "data": data,
            "style": ["color": "blue", "width": 0.004, "opacity": 1.0]]) { _, new in new }) as? [String: Any])
        let drawingID = try XCTUnwrap(row["id"] as? String)
        let originalJSON = try XCTUnwrap(context.query("SELECT data_json FROM pdf_drawings WHERE id=?", [drawingID]).first?["data_json"] as? String)
        let store = NativeWorkspaceStore(storageRoot: root)
        await store.start(); XCTAssertTrue(store.isReady)
        let sceneDeadline = CACurrentMediaTime() + 5
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }), CACurrentMediaTime() < sceneDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let suite = "PageOperationRecovery-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var replacementEvents = 0
        let subscription = store.events.sink { event in
            if event.channel == "nativeWorkspace:materialReplaced" { replacementEvents += 1 }
        }
        defer { subscription.cancel() }
        weak var closingModel: NativePDFWorkspaceModel?
        var caught: Error?
        do {
            let document = NativeDocumentReference(courseID: course, relativePath: path, title: "Fixture", kind: "pdf")
            let model = NativePDFWorkspaceModel(document: document, store: store, defaults: defaults)
            closingModel = model
            defer { model.close() }
            model.attach(to: controller.view); model.layout(controller.view.bounds)
            let openDeadline = CACurrentMediaTime() + 10
            while model.isLoading, model.errorMessage == nil, CACurrentMediaTime() < openDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(model.errorMessage); XCTAssertFalse(model.isLoading)
            XCTAssertEqual(model.pageCount, 1); XCTAssertEqual(model.drawingCount, 1)
            // Both faults occur after the page-file transaction has committed.
            // Initial page-one flush and unchanged view-state remapping succeed.
            if failure == .destinationSave {
                try context.db.exec("CREATE TRIGGER fail_destination BEFORE INSERT ON pdf_view_state WHEN NEW.page=2 BEGIN SELECT RAISE(ABORT,'injected destination save failure'); END;")
            } else {
                try context.db.exec("CREATE TRIGGER fail_destination BEFORE INSERT ON pdf_view_state WHEN NEW.page=2 BEGIN UPDATE pdf_drawings SET data_json='invalid JSON'; END;")
            }
            model.addPage(after: 1)
            let failureDeadline = CACurrentMediaTime() + 15
            while model.errorMessage == nil, CACurrentMediaTime() < failureDeadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertNotNil(model.errorMessage, "The real storage fault must reach the editor's retry state")
            XCTAssertFalse(model.isBusy)
            XCTAssertEqual(PDFDocument(url: url)?.pageCount, 2)
            XCTAssertEqual(try context.query("SELECT * FROM native_pdf_page_receipts").count, 1)
            XCTAssertEqual(try context.query("SELECT * FROM native_pdf_page_history").count, 1)
            XCTAssertEqual(replacementEvents, 1)
            let committed = try XCTUnwrap(context.query("SELECT bound_sha FROM pdf_document_bindings").first?["bound_sha"] as? String)
            XCTAssertNotEqual(committed, initialRevision)
            let failedView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? PDFView }.first)
            XCTAssertFalse(failedView.isUserInteractionEnabled, "A stale or partially opened surface must keep input blocked")
            if failure == .reopen {
                XCTAssertEqual(model.pageCount, 2, "This failure happens after open adopted the committed revision")
                XCTAssertTrue(model.isLoading)
            } else { XCTAssertEqual(model.pageCount, 1) }

            try context.db.exec("DROP TRIGGER fail_destination")
            try context.run("UPDATE pdf_drawings SET data_json=? WHERE id=?", [originalJSON, drawingID])
            model.retry()
            let retryDeadline = CACurrentMediaTime() + 15
            while (model.isBusy || model.isLoading || model.page != 2), model.errorMessage == nil, CACurrentMediaTime() < retryDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(model.errorMessage); XCTAssertFalse(model.isBusy); XCTAssertFalse(model.isLoading)
            XCTAssertEqual(model.pageCount, 2); XCTAssertEqual(model.page, 2); XCTAssertEqual(model.drawingCount, 1)
            XCTAssertEqual(PDFDocument(url: url)?.pageCount, 2)
            XCTAssertEqual(try context.query("SELECT * FROM native_pdf_page_receipts").count, 1)
            XCTAssertEqual(try context.query("SELECT * FROM native_pdf_page_history").count, 1)
            XCTAssertEqual(replacementEvents, 1, "Retry must not reenter the external-mutation/old-host flush barrier")
            let reopenedView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? PDFView }.first)
            XCTAssertEqual(reopenedView.document?.pageCount, 2)
            XCTAssertEqual(reopenedView.document?.documentURL?.deletingPathExtension().lastPathComponent, committed)
            XCTAssertTrue(reopenedView.isUserInteractionEnabled)
            try await model.flush()
        } catch { caught = error }
        let closeDeadline = CACurrentMediaTime() + 10
        while closingModel != nil, CACurrentMediaTime() < closeDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(closingModel, "The retry fixture must finish its close barrier")
        if let caught { throw caught }
    }
}
