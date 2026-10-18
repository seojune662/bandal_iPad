import UIKit
import WebKit
import PDFKit
import CryptoKit

/// PDFKit and Metal compositor for the native document workspace.
/// PDF scrolling, Pencil input and retained objects share one coordinate system.
@MainActor
final class NativePDFHost: NSObject, UIPencilInteractionDelegate {
    typealias Invoke = (String, [String: Any]) async throws -> Any
    var emit: (String, Any) -> Void = { _, _ in }
    var onDiagnostic: (String, String) -> Void = { _, _ in }
    private let root: URL
    private let invoke: Invoke
    private let journal: NativePDFJournalQueue
    /// The native workspace owns its own UI and persistence bridge. Its
    /// production path does not depend on the legacy renderer's DEBUG flag.
    private let directEnabled: Bool
    private struct JournalJob {
        let ticket: NativePDFJournalQueue.Ticket
        let item: NativePDFDocument
        let input: NativePDFStrokeInput
        let final: Bool, ordered: Bool
        let prepared: NativePDFJournalQueue.PreparedStroke?
    }
    private var journalJobs: [UInt64: JournalJob] = [:]
    private weak var container: UIView?
    private weak var shell: WKWebView?
    private var documents: [String: NativePDFDocument] = [:]
    private var inputOwners: [String: NSObject] = [:]
    private func ownerKey(_ surface: String, _ generation: String) -> String { surface + "\u{0}" + generation }
    private var openGenerations: [String: String] = [:] // Active renderer ownership.
    private var openingGenerations: [String: String] = [:] // Latest asynchronous open request.
    private var replacingGenerations: [String: String] = [:] // Input suspended while its disk snapshot is captured.
    private var rectangles: [String: CGRect] = [:]
    private var holes: [String: [CGRect]] = [:]
    private var visibleSurfaces: Set<String> = []
    private var occludedSurfaces: Set<String> = []
    private var layoutRevisions: [String: Int] = [:]
    private var hostOccluded = false
    private var hostInputBlocked = false
    private var hostOverlays: [CGRect] = []
    private var memoryObserver: NSObjectProtocol?
    private var reportedJournalTimingCounts: [String: Int] = [:]
    private func reportJournalTimings() {
        for phase in ["checkpoint", "commit", "ack", "fileSync", "directorySync"] {
            guard let statistics = journal.timingStatistics[phase],
                  reportedJournalTimingCounts[phase] != statistics.count else { continue }
            reportedJournalTimingCounts[phase] = statistics.count
            if statistics.shouldLog { onDiagnostic("nativePDF.journalTiming", "\(phase).\(statistics.logCode)") }
        }
    }
    private var isEnabled: Bool {
        if directEnabled { return true }
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "bandal.nativePDF.enabled")
        #else
        return false
        #endif
    }

    init(root: URL, journalQueue: NativePDFJournalQueue? = nil, directEnabled: Bool = false, invoke: @escaping Invoke) throws {
        self.root = root; self.invoke = invoke; journal = journalQueue ?? NativePDFSharedJournal.queue(root: root)
        self.directEnabled = directEnabled
        super.init()
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.documents.values.forEach { $0.releaseCaches() } }
        }
    }
    func attach(to container: UIView, shell: WKWebView? = nil) {
        self.container = container; self.shell = shell
        // One interaction on the shared container: the first responder is the
        // shell web view or a PDF view, both descendants, so the tap reaches it.
        if !container.interactions.contains(where: { $0 is UIPencilInteraction }) {
            container.addInteraction(UIPencilInteraction(delegate: self))
        }
    }
    /// The system preference (Settings › Apple Pencil) decides the action; the
    /// renderer applies it to the active document's tool.
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        let action: String
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser: action = "switchEraser"
        case .switchPrevious: action = "switchPrevious"
        case .showColorPalette, .showInkAttributes: action = "showColorPalette"
        default: return
        }
        for (identifier, item) in documents where visibleSurfaces.contains(identifier) && !item.pdfView.isHidden {
            item.onEvent("pencilTap", ["action": action])
        }
    }
    func setPresentation(blocked: Bool, inputBlocked: Bool, overlays: [CGRect]) {
        if (blocked || inputBlocked) && !(hostOccluded || hostInputBlocked) { flush() }
        hostOccluded = blocked; hostInputBlocked = inputBlocked; hostOverlays = overlays
        layout()
    }
    func clearTextSelection(surfaceID: String, generation: String) {
        guard let item = documents[surfaceID], item.generation == generation else { return }
        item.pdfView.clearSelection()
    }
    /// Returns the page to where it was before the keyboard reveal; called before the edit is committed.
    func restoreTextScroll(surfaceID: String, generation: String) {
        guard let item = documents[surfaceID], item.generation == generation else { return }
        item.restoreScrollAfterTextEditing()
    }
    /// Installs (or removes) the live text box on one page of a document.
    func setTextEditor(surfaceID: String, generation: String, page: Int, view: NativePDFTextInputView?) {
        guard let item = documents[surfaceID], item.generation == generation else { return }
        item.textEditor = view.map { (page: page, view: $0) }
        if view == nil { item.cancelKeyboardReveal(); item.restoreScrollAfterTextEditing() } else { item.revealTextEditorWhenKeyboardShows() }
    }
    func canHandle(_ channel: String) -> Bool { channel.hasPrefix("pdfNative:") }
    func handle(_ channel: String, request: [String: Any]) async throws -> Any {
        if channel == "pdfNative:capabilities" {
            #if DEBUG
            let development = true
            #else
            let development = false
            #endif
            return ["enabled": isEnabled,
                    "development": development, "version": 1, "inkVersion": 5, "drawingPatch": 1, "objectScenePatch": 1, "nativeInkErase": 1, "renderer": "PDFKit/UIKit/Metal"]
        }
        if channel == "pdfNative:setEnabled" {
            #if DEBUG
            guard let enabled = request["enabled"] as? Bool else { throw NativePDFError.invalid("PDF 검증 설정을 확인해 주세요.") }
            UserDefaults.standard.set(enabled, forKey: "bandal.nativePDF.enabled")
            return ["enabled": enabled]
            #else
            throw NativePDFError.invalid("PDF 검증 전환은 개발 빌드에서만 사용할 수 있습니다.")
            #endif
        }
        let identifier = try Self.string(request, "surfaceId"), generation = try Self.string(request, "generation")
        if channel == "pdfNative:open" {
            guard isEnabled else { throw NativePDFError.invalid("네이티브 PDF 검증 기능이 꺼져 있습니다.") }
            let course = try Self.string(request, "courseId"), path = try Self.string(request, "relPath")
            if let current = documents[identifier], current.generation == generation, openGenerations[identifier] == generation {
                guard current.courseID == course, current.relativePath == path else { throw NativePDFError.invalid("PDF 표면 식별자가 변경되었습니다.") }
                return current.state
            }
            let previous = documents[identifier]
            let ownershipKey = ownerKey(identifier, generation)
            let inputOwner = inputOwners[ownershipKey] ?? NSObject()
            inputOwners[ownershipKey] = inputOwner
            let previousOwner = previous.flatMap { inputOwners[ownerKey(identifier, $0.generation)] }
            openingGenerations[identifier] = generation
            var adopted = false
            defer {
                if !adopted {
                    NativePDFInputOwnership.shared.releaseAll(owner: inputOwner, returningTo: previousOwner)
                    if inputOwners[ownershipKey] === inputOwner { inputOwners.removeValue(forKey: ownershipKey) }
                } else if let previous, previous.generation != generation {
                    inputOwners.removeValue(forKey: ownerKey(identifier, previous.generation))
                }
                if openingGenerations[identifier] == generation { openingGenerations.removeValue(forKey: identifier) }
                if replacingGenerations[identifier] == generation {
                    replacingGenerations.removeValue(forKey: identifier)
                    if !adopted, let previous, documents[identifier] === previous {
                        // The old generation remains authoritative until successful
                        // installation, including ACKs while file/binding I/O waits.
                        do { try previous.setVisible(visibleSurfaces.contains(identifier)) }
                        catch { previous.onEvent("error", ["message": error.localizedDescription]) }
                        layout()
                    }
                }
            }
            guard let source = try await invoke("nativeMaterial:path", ["courseId": course, "relPath": path]) as? String else { throw NativePDFError.invalid("PDF 자료를 찾지 못했습니다.") }
            let root = root
            let snapshot = try await Task.detached(priority: .userInitiated) { try Self.snapshot(path: source, root: root) }.value
            guard openingGenerations[identifier] == generation else { throw CancellationError() }
            // Canonical drawings remain bound to the first verified PDF
            // revision across close/reopen, rename and sync. Never relabel old
            // ink with the hash of a replacement file at the same path.
            guard let binding = try await invoke("nativePDF:binding", ["courseId": course, "relPath": path, "documentRevision": snapshot.revision]) as? [String: Any],
                  binding["documentRevision"] as? String == snapshot.revision,
                  let materialID = binding["materialID"] as? String, !materialID.isEmpty else {
                throw NativePDFError.invalid("PDF 원본과 필기 연결을 확인하지 못했습니다. 자료를 보존한 채 다시 열어 주세요.")
            }
            guard openingGenerations[identifier] == generation else { throw CancellationError() }
            guard let pdf = PDFDocument(url: snapshot.url), !pdf.isLocked, pdf.pageCount > 0 else { throw NativePDFError.invalid("PDF를 열지 못했습니다. 잠금 또는 파일 형식을 확인해 주세요.") }
            // Freeze only the surface being replaced before taking its disk
            // snapshot. Otherwise an await could admit a final point after the
            // pending list was captured and then close its last visible owner.
            if let previous, documents[identifier] === previous {
                replacingGenerations[identifier] = generation
                try previous.setVisible(false)
                guard previous.operationLedger.pendingEraseCount == 0 else {
                    throw NativePDFError.invalid("지우기 저장 결과를 확인한 뒤 PDF를 다시 열어 주세요.")
                }
            }
            // Only orphaned disk records are recovery. Opening a second pane
            // must not finalize or ACK the first pane's live measured contact.
            let pending = try await journal.pending(courseID: course, relativePath: path, retryFailed: true).filter {
                NativePDFInputOwnership.shared.claim(root: root, course: course, path: path,
                    mutation: $0.input.clientMutationId, owner: inputOwner, replacing: previousOwner)
            }
            try reconcileJournal()
            guard openingGenerations[identifier] == generation else { throw CancellationError() }
            guard pending.allSatisfy({ $0.documentRevision == snapshot.revision }) else {
                throw NativePDFError.invalid("PDF 원본이 바뀌어 이전 문서의 미전송 필기를 보존했습니다. 원본 복구 후 다시 열어 주세요.")
            }
            // A process ending during estimated-property correction recovers
            // the last durable measured checkpoint as its final payload.
            for record in pending where record.provisional == true { try journal.enqueueStroke(record.input, documentRevision: record.documentRevision) }
            try await journal.barrier(retryFailed: true)
            try reconcileJournal()
            guard openingGenerations[identifier] == generation else { throw CancellationError() }
            try documents[identifier]?.close()
            documents.removeValue(forKey: identifier)
            rectangles.removeValue(forKey: identifier); holes.removeValue(forKey: identifier)
            visibleSurfaces.remove(identifier); occludedSurfaces.remove(identifier); layoutRevisions.removeValue(forKey: identifier)
            var testingDirectPencil = false
            #if DEBUG
            // Exercise UIKit's real recognizer dispatch with XCTest fingers in
            // a separate fixture library. Never enable it in the user's data.
            let arguments = ProcessInfo.processInfo.arguments
            let isolatedLegacy = root.lastPathComponent == "BandalDesktop-UI-Tests" && arguments.contains("--ui-testing")
            let isolatedNative = root.lastPathComponent == "BandalDesktop-Native-UI-Tests" && arguments.contains("--native-ui-testing")
            testingDirectPencil = (isolatedLegacy || isolatedNative) && arguments.contains("--native-pencil-dispatch-fixture")
            #endif
            let item = NativePDFDocument(id: identifier, generation: generation, courseID: course, relativePath: path,
                                         revision: snapshot.revision, document: pdf, testingDirectPencil: testingDirectPencil)
            item.usesNativeChrome = directEnabled
            item.onDiagnostic = { [weak self] event, code in self?.onDiagnostic(event, code) }
            item.onEvent = { [weak self, weak item] type, body in
                guard let self, let item, self.documents[identifier] === item,
                      self.openGenerations[identifier] == generation else { return }
                self.emit("pdfNative:event", ["surfaceId": identifier, "generation": generation, "type": type, "payload": body])
            }
            item.onDurabilityBarrier = { [weak self] in
                guard let self else { throw CancellationError() }
                try self.drainJournalSynchronously(retryFailed: true)
            }
            item.onStroke = { [weak self, weak item] page, stroke in
                guard let self, let item else { throw CancellationError() }
                let started = CACurrentMediaTime()
                defer { item.recordLatency("commitCallback", startedAt: started); self.reportJournalTimings() }
                let input = NativePDFStrokeInput(courseId: course, relPath: path, page: page, kind: stroke.kind,
                                                data: NativePDFStrokeData(points: stroke.points, inkVersion: stroke.inkVersion), style: stroke.style,
                                                clientMutationId: stroke.mutationID, documentRevision: item.revision, heldShape: stroke.heldShape)
                try self.admitJournal(input, item: item, final: true)
            }
            item.onCheckpoint = { [weak self, weak item] page, stroke in
                guard let self, let item else { throw CancellationError() }
                let started = CACurrentMediaTime()
                defer { item.recordLatency("checkpointCallback", startedAt: started); self.reportJournalTimings() }
                let input = NativePDFStrokeInput(courseId: course, relPath: path, page: page, kind: stroke.kind,
                    data: NativePDFStrokeData(points: stroke.points, inkVersion: stroke.inkVersion), style: stroke.style,
                    clientMutationId: stroke.mutationID, documentRevision: item.revision, heldShape: stroke.heldShape)
                try self.admitJournal(input, item: item, final: false)
            }
            item.resolveImage = { [weak self] object in
                guard let self else { throw CancellationError() }
                return try await self.resolveImage(object: object, courseID: course)
            }
            for record in pending { item.addPending(record.input, notify: false) }
            documents[identifier] = item; openGenerations[identifier] = generation
            adopted = true
            container?.addSubview(item.pdfView)
            item.pdfView.isHidden = true
            return item.state.merging(["pending": try pending.map { try Self.json($0.input) }]) { _, new in new }
        }
        if channel == "pdfNative:close" {
            if let item = documents[identifier], item.generation == generation {
                _ = try await sealAndDrain(item)
                guard documents[identifier] === item, openGenerations[identifier] == generation else { throw CancellationError() }
                try item.close(); documents.removeValue(forKey: identifier); rectangles.removeValue(forKey: identifier); holes.removeValue(forKey: identifier)
                if let owner = inputOwners.removeValue(forKey: ownerKey(identifier, generation)) { NativePDFInputOwnership.shared.releaseAll(owner: owner) }
                visibleSurfaces.remove(identifier); occludedSurfaces.remove(identifier); layoutRevisions.removeValue(forKey: identifier)
            }
            // A failed live close must retain its generation so the existing
            // renderer writer can retry flush/ACK/close. Pending opens without
            // a live document are still invalidated by an explicit close.
            if openGenerations[identifier] == generation { openGenerations.removeValue(forKey: identifier) }
            if openingGenerations[identifier] == generation { openingGenerations.removeValue(forKey: identifier) }
            return [:]
        }
        guard openGenerations[identifier] == generation,
              let item = documents[identifier], item.generation == generation else { throw NativePDFError.invalid("PDF 표면이 닫혔거나 변경되었습니다.") }
        switch channel {
        case "pdfNative:layout":
            // Keep the latest layout authority while a replacement's disk
            // snapshot is captured, but never resume that frozen input surface.
            // If replacement fails, its defer restores this latest visibility.
            let replacing = replacingGenerations[identifier] != nil
            if let revision = request["revision"] as? Int {
                guard revision > (layoutRevisions[identifier] ?? 0) else { return ["revision": layoutRevisions[identifier] ?? 0] }
                layoutRevisions[identifier] = revision
            }
            let visible = request["visible"] as? Bool ?? false
            if !replacing { try item.setVisible(visible) }
            if visible { visibleSurfaces.insert(identifier) } else { visibleSurfaces.remove(identifier) }
            if request["occluded"] as? Bool == true { occludedSurfaces.insert(identifier) } else { occludedSurfaces.remove(identifier) }
            if let value = request["rect"] as? [String: Double], let x = value["x"], let y = value["y"], let w = value["width"], let h = value["height"], [x,y,w,h].allSatisfy(\.isFinite), w > 0, h > 0 {
                rectangles[identifier] = CGRect(x: x, y: y, width: w, height: h)
            } else { rectangles.removeValue(forKey: identifier); item.pdfView.isHidden = true }
            holes[identifier] = (request["holes"] as? [[String: Double]] ?? []).prefix(32).compactMap { value in
                guard let x = value["x"], let y = value["y"], let width = value["width"], let height = value["height"], [x,y,width,height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
                return CGRect(x: x, y: y, width: width, height: height)
            }
            layout(); return ["revision": layoutRevisions[identifier] ?? 0]
        case "pdfNative:snapshot":
            return try item.snapshot(request)
        case "pdfNative:objectScene":
            return try item.objectScene(request)
        case "pdfNative:navigate":
            try item.navigate(request); return item.state
        case "pdfNative:find":
            try item.flush()
            item.pdfView.findInteraction.presentFindNavigator(showingReplace: false)
            return [:]
        case "pdfNative:ack":
            let started = CACurrentMediaTime()
            defer { item.recordLatency("ackCallback", startedAt: started); reportJournalTimings() }
            let mutation = try Self.string(request, "clientMutationId")
            // Renderer acks only after its canonical create/receipt resolves.
            let drawingID = try Self.string(request, "drawingId")
            try reconcileJournal()
            guard let owner = inputOwners[ownerKey(identifier, generation)],
                  NativePDFInputOwnership.shared.claim(root: root, course: item.courseID, path: item.relativePath, mutation: mutation, owner: owner) else {
                throw NativePDFError.invalid("다른 PDF 창의 필기를 저장 완료로 처리할 수 없습니다.")
            }
            try item.operationLedger.validateStrokeAcknowledgement(mutationID: mutation, drawingID: drawingID)
            try await journal.acknowledge(mutation, courseID: item.courseID, relativePath: item.relativePath)
            try reconcileJournal()
            guard documents[identifier] === item, openGenerations[identifier] == generation else { throw CancellationError() }
            try item.operationLedger.acknowledgeStroke(mutationID: mutation, drawingID: drawingID)
            item.acknowledgePreview(mutationID: mutation, drawingID: drawingID)
            NativePDFInputOwnership.shared.release(root: root, course: item.courseID, path: item.relativePath, mutation: mutation, owner: owner)
            return [:]
        case "pdfNative:eraseResult":
            guard item.nativeInkEraseEnabled else { throw NativePDFError.invalid("네이티브 지우기가 활성화되지 않았습니다.") }
            try item.operationLedger.acceptEraseResult(request)
            item.refreshOverlays(pages: (request["page"] as? NSNumber).map { [$0.intValue] })
            return ["operationId": request["operationId"]!, "operationSequence": request["operationSequence"]!, "outcome": request["outcome"]!]
        case "pdfNative:mutationStatus":
            guard let input = request["input"] as? [String: Any], input["courseId"] as? String == item.courseID,
                  input["relPath"] as? String == item.relativePath, input["documentRevision"] as? String == item.revision else {
                throw NativePDFError.invalid("다른 문서의 필기 저장 상태를 확인할 수 없습니다.")
            }
            let result = try await invoke("nativePDF:mutationStatus", input)
            if let receipt = result as? [String: Any], receipt["status"] as? String == "deleted", let mutation = input["clientMutationId"] as? String {
                let page = item.pending[mutation]?.page
                item.pending.removeValue(forKey: mutation); item.refreshOverlays(pages: page.map { [$0] })
            }
            return result
        case "pdfNative:diagnostics":
            let queue = journal.state
            return item.diagnostics.merging(["journalTiming": journal.timingStatistics.mapValues(\.diagnostics),
                "journalQueue": ["pendingJobs": queue.queuedJobs, "pendingBytes": queue.queuedBytes,
                    "failed": queue.failedTicket != nil, "issued": queue.issued.value, "completed": queue.completed.value]]) { _, new in new }
        case "pdfNative:pageGeometry":
            guard let page = request["page"] as? Int else { throw NativePDFError.invalid("편집할 PDF 페이지를 확인해 주세요.") }
            return try item.pageGeometry(page)
        case "pdfNative:flush":
            let through = try await sealAndDrain(item)
            guard documents[identifier] === item, openGenerations[identifier] == generation else { throw CancellationError() }
            guard let owner = inputOwners[ownerKey(identifier, generation)] else { throw CancellationError() }
            let recovered = try await journal.pending(courseID: item.courseID, relativePath: item.relativePath)
                .filter { NativePDFInputOwnership.shared.claim(root: root, course: item.courseID, path: item.relativePath,
                    mutation: $0.input.clientMutationId, owner: owner) }
                .filter { !item.nativeInkEraseEnabled || !item.operationLedger.containsLiveStroke($0.input.clientMutationId) }
            try reconcileJournal()
            guard documents[identifier] === item, openGenerations[identifier] == generation else { throw CancellationError() }
            var response: [String: Any] = ["pending": try recovered.map { try Self.json($0.input) }, "viewport": item.viewportState]
            if item.nativeInkEraseEnabled {
                response["pendingOperations"] = item.operationLedger.pendingOperations.filter {
                    ($0["operationSequence"] as? Int ?? Int.max) <= through
                }
                response["throughOperationSequence"] = through
            }
            return response
        default: throw NativePDFError.invalid("알 수 없는 PDF 작업입니다.")
        }
    }
    private func admitJournal(_ input: NativePDFStrokeInput, item: NativePDFDocument, final: Bool) throws {
        try input.validate()
        guard input.documentRevision == item.revision else { throw NativePDFError.invalid("필기 원본 연결이 바뀌었습니다.") }
        guard let owner = inputOwners[ownerKey(item.id, item.generation)],
              NativePDFInputOwnership.shared.claim(root: root, course: item.courseID, path: item.relativePath,
                mutation: input.clientMutationId, owner: owner) else {
            throw NativePDFError.invalid("이 필기는 다른 PDF 창에서 저장하고 있습니다.")
        }
        let ordered = final && item.nativeInkEraseEnabled
        let prepared = final ? NativePDFJournalQueue.PreparedStroke() : nil
        var ticket: NativePDFJournalQueue.Ticket?
        let admit = {
            let completion: NativePDFJournalQueue.Completion = { [weak self, weak item] result in
                guard let self else { return }
                do { try self.reconcileJournal() }
                catch { item?.onEvent("error", ["message": error.localizedDescription]) }
                if case let .failure(error) = result {
                    item?.onEvent("error", ["message": error.localizedDescription])
                    self.onDiagnostic("nativePDF.journalQueue", "write.failed.retained")
                }
                self.reportJournalTimings()
            }
            if final {
                ticket = try self.journal.enqueueStroke(input, documentRevision: item.revision,
                    preparedTransport: prepared, completion: completion)
            } else {
                ticket = try self.journal.enqueueCheckpoint(input, documentRevision: item.revision, completion: completion)
            }
        }
        if ordered {
            let reservation = try item.operationLedger.reserveStroke(input, admit: admit)
            if !reservation.admitted { return }
        } else { try admit() }
        guard let ticket else { preconditionFailure("Successful journal admission must own a ticket") }
        journalJobs[ticket.value] = JournalJob(ticket: ticket, item: item, input: input,
            final: final, ordered: ordered, prepared: prepared)
        // Surface transfers ownership after this synchronous callback succeeds.
        // Both the queue and this pending display retain the original value.
        // UIKit streams pressure/azimuth corrections in many small batches after
        // the lift; each one must reach the journal now, but re-encoding the row
        // and revalidating the page scene per batch was a third of the main
        // thread. The first checkpoint still installs the row synchronously so
        // the live stroke hands off without a gap.
        if final || item.pending[input.clientMutationId] == nil { item.addPending(input); item.refreshOverlays(pages: [input.page]) }
        else { item.deferPendingDisplay(input) }
    }
    private func reconcileJournal() throws {
        let completed = journal.state.completed.value
        let ready = journalJobs.keys.filter { $0 <= completed }.sorted()
        for key in ready {
            guard let job = journalJobs[key] else { continue }
            var payload: [String: Any]?
            if job.final {
                guard let transport = job.prepared?.value else {
                    throw NativePDFError.invalid("저장된 필기의 전송 준비 상태를 확인하지 못했습니다.")
                }
                payload = job.ordered ? try job.item.operationLedger.makeStrokeDurable(job.input, transport: transport) : transport.payload
            }
            journalJobs.removeValue(forKey: key); job.prepared?.release()
            job.item.recordJournal(job.input.kind, phase: job.final ? "commit" : "checkpoint")
            if let payload { job.item.onEvent("stroke", payload) }
        }
    }
    private func sealAndDrain(_ item: NativePDFDocument) async throws -> Int {
        var sealFailure: Error?
        do { try item.flush() } catch { sealFailure = error }
        var through = item.operationLedger.throughOperationSequence
        // Even a full queue must get its explicit retry/drain opportunity;
        // otherwise a retained Surface completion could never be re-admitted.
        try await drainJournal(retryFailed: true)
        if let sealFailure {
            guard let admission = sealFailure as? NativePDFJournalQueue.AdmissionError,
                  case .full = admission else { throw sealFailure }
            try item.flush()
            through = item.operationLedger.throughOperationSequence
            try await drainJournal(retryFailed: true)
        }
        return through
    }
    private func drainJournal(retryFailed: Bool) async throws {
        do { try await journal.barrier(retryFailed: retryFailed) }
        catch { try reconcileJournal(); throw error }
        try reconcileJournal(); reportJournalTimings()
    }
    private func drainJournalSynchronously(retryFailed: Bool) throws {
        do { try journal.barrierSynchronously(retryFailed: retryFailed) }
        catch { try reconcileJournal(); throw error }
        try reconcileJournal(); reportJournalTimings()
    }
    func layout() {
        guard let container else { return }
        let sourceView = shell as UIView? ?? container
        for (identifier, item) in documents {
            let hidden = hostOccluded || replacingGenerations[identifier] != nil || occludedSurfaces.contains(identifier) || !visibleSurfaces.contains(identifier)
            item.pdfView.isHidden = hidden
            item.pdfView.accessibilityElementsHidden = hidden
            item.pdfView.isUserInteractionEnabled = !hidden && !hostInputBlocked
            #if DEBUG
            item.presentationDiagnostics = "hostBlocked=\(hostOccluded ? 1 : 0) hostInputBlocked=\(hostInputBlocked ? 1 : 0) layoutRevision=\(layoutRevisions[identifier] ?? 0)"
            #endif
            guard !hidden, let rect = rectangles[identifier] else { item.pdfView.isHidden = true; continue }
            let factor = shell?.scrollView.zoomScale ?? 1
            let source = CGRect(x: rect.minX * factor, y: rect.minY * factor, width: rect.width * factor, height: rect.height * factor)
            let unclipped = sourceView.convert(source, to: container)
            let frame = unclipped.intersection(sourceView.convert(sourceView.bounds, to: container)).intersection(container.bounds)
            guard !frame.isNull, !frame.isEmpty else { item.pdfView.isHidden = true; continue }
            let frameChanged = item.pdfView.frame != frame
            if frameChanged { item.pdfView.frame = frame }
            container.bringSubviewToFront(item.pdfView)
            let offsetX = unclipped.minX - frame.minX, offsetY = unclipped.minY - frame.minY
            let localHoles: [CGRect] = (holes[identifier] ?? []).map { hole in
                let x = hole.minX * factor + offsetX, y = hole.minY * factor + offsetY
                return CGRect(x: x, y: y, width: hole.width * factor, height: hole.height * factor)
            }
            let globalHoles = hostOverlays.compactMap { overlay -> CGRect? in
                let converted = sourceView.convert(CGRect(x: overlay.minX * factor, y: overlay.minY * factor, width: overlay.width * factor, height: overlay.height * factor), to: container)
                let overlap = converted.intersection(frame)
                guard !overlap.isNull, !overlap.isEmpty else { return nil }
                return overlap.offsetBy(dx: -frame.minX, dy: -frame.minY)
            }
            item.pdfView.excludedRects = localHoles + globalHoles
            #if DEBUG
            item.refreshPresentationDiagnostics()
            #endif
            if frameChanged { item.prepareNavigation() }
        }
    }
    func flush() { for item in documents.values { do { try item.flush() } catch { item.onEvent("error", ["message": error.localizedDescription]) } } }
    /// Include retained documents from retired renderers in the save barrier.
    /// Their old JS listeners can no longer report a failed checkpoint.
    func flushForRecovery() throws {
        for attempt in 0..<2 {
            var firstFailure: Error?
            var admissionFailure: Error?
            for item in documents.values {
                do { try item.flush() }
                catch {
                    if let admission = error as? NativePDFJournalQueue.AdmissionError, case .full = admission {
                        if admissionFailure == nil { admissionFailure = error }
                    } else if firstFailure == nil { firstFailure = error }
                }
            }
            try drainJournalSynchronously(retryFailed: true)
            // Arbitrary Surface errors retain the existing one-attempt-per-
            // explicit-barrier contract. Only queue capacity can be relieved
            // by this completed drain and merits one immediate re-admission.
            if let firstFailure { throw firstFailure }
            if let admissionFailure {
                if attempt == 1 { throw admissionFailure }
            } else { return }
        }
    }
    func closeAll() {
        // Invalidate opens that are still awaiting a file/binding response too.
        // They do not yet appear in documents and must not recreate a surface
        // after the renderer that owns them has terminated.
        openGenerations.removeAll(); openingGenerations.removeAll(); replacingGenerations.removeAll()
        visibleSurfaces.removeAll(); occludedSurfaces.removeAll()
        rectangles.removeAll(); holes.removeAll(); layoutRevisions.removeAll()
        do { try flushForRecovery() }
        catch { onDiagnostic("nativePDF.journalQueue", "retired.flush.failed.retained") }
        for (id, item) in documents {
            // If durable flushing fails, retain measured input for recovery,
            // but a retired renderer can never expose or control this view.
            item.pdfView.isHidden = true
            item.pdfView.accessibilityElementsHidden = true
            item.pdfView.isUserInteractionEnabled = false
            do { try item.close(); documents.removeValue(forKey: id); openGenerations.removeValue(forKey: id); rectangles.removeValue(forKey: id); holes.removeValue(forKey: id)
                if let owner = inputOwners.removeValue(forKey: ownerKey(id, item.generation)) { NativePDFInputOwnership.shared.releaseAll(owner: owner) }
                visibleSurfaces.remove(id); occludedSurfaces.remove(id); layoutRevisions.removeValue(forKey: id) }
            catch { item.onEvent("error", ["message": error.localizedDescription]) }
        }
    }
    private func resolveImage(object: [String: Any], courseID: String) async throws -> UIImage {
        let data = object["data"] as? [String: Any] ?? [:]
        let kind = object["kind"] as? String
        let source = data[kind == "clip" ? "clip" : "image"] as? [String: Any] ?? [:]
        guard let path = source["relPath"] as? String,
              let resolved = try await invoke("nativeMaterial:path", ["courseId": courseID, "relPath": path]) as? String else { throw NativePDFError.invalid("PDF에 포함된 이미지를 찾지 못했습니다.") }
        let root = root
        let copy = try await Task.detached(priority: .utility) { try Self.snapshot(path: resolved, root: root) }.value
        if kind != "clip" {
            guard let image = UIImage(contentsOfFile: copy.url.path) else { throw NativePDFError.invalid("이미지 자료를 해석하지 못했습니다.") }; return image
        }
        guard let document = PDFDocument(url: copy.url), let number = source["page"] as? Int, let page = document.page(at: number-1) else { throw NativePDFError.invalid("자료 조각의 PDF 페이지를 찾지 못했습니다.") }
        let geometry = NativePDFPageCoordinates(page: page)
        let crop = source["crop"] as? [String: Double] ?? ["x": 0, "y": 0, "width": 1, "height": 1]
        let scale = min(2, 2048 / max(geometry.width, geometry.height))
        let whole = page.thumbnail(of: CGSize(width: geometry.width * scale, height: geometry.height * scale), for: .cropBox)
        guard let cg = whole.cgImage else { throw NativePDFError.invalid("PDF 자료 조각을 그리지 못했습니다.") }
        let pixels = CGRect(x: (crop["x"] ?? 0) * Double(cg.width), y: (crop["y"] ?? 0) * Double(cg.height), width: (crop["width"] ?? 1) * Double(cg.width), height: (crop["height"] ?? 1) * Double(cg.height)).intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !pixels.isEmpty, let clipped = cg.cropping(to: pixels) else { throw NativePDFError.invalid("PDF 자료 조각의 범위가 잘못되었습니다.") }
        return UIImage(cgImage: clipped)
    }
    private static func string(_ request: [String: Any], _ key: String) throws -> String {
        guard let value = request[key] as? String, !value.isEmpty, value.count < 8_192 else { throw NativePDFError.invalid("PDF 작업 정보가 올바르지 않습니다.") }; return value
    }
    nonisolated static func json(_ value: NativePDFStrokeInput) throws -> [String: Any] {
        // Keep measured doubles intact. JSONEncoder followed by Foundation's
        // generic JSON parser can introduce an NSDecimalNumber conversion.
        let points = value.data.points.map { point -> [String: Any] in
            var item: [String: Any] = ["x": point.x, "y": point.y, "p": point.p]
            if let t = point.t { item["t"] = t }
            if let tiltX = point.tiltX { item["tiltX"] = tiltX }
            if let tiltY = point.tiltY { item["tiltY"] = tiltY }
            return item
        }
        var style: [String: Any] = ["color": value.style.color, "width": value.style.width, "opacity": value.style.opacity]
        if value.style.fixedWidth == true { style["fixedWidth"] = true }
        var result: [String: Any] = [
            "courseId": value.courseId, "relPath": value.relPath, "page": value.page,
            "kind": value.kind, "clientMutationId": value.clientMutationId,
            "data": ["points": points, "inkVersion": value.data.inkVersion],
            "style": style
        ]
        if let revision = value.documentRevision { result["documentRevision"] = revision }
        if let shape = value.heldShape { result["heldShape"] = shape.journalPayload }
        guard JSONSerialization.isValidJSONObject(result) else { throw NativePDFError.invalid("PDF 입력을 변환하지 못했습니다.") }
        return result
    }
    nonisolated private static func snapshot(path: String, root: URL) throws -> (url: URL, revision: String) {
        let file = try DesktopMaterialFile(path: path, root: root)
        let cache = root.appendingPathComponent("NativePDFCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let temporary = cache.appendingPathComponent(UUID().uuidString + ".part")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw NativePDFError.invalid("PDF 임시 파일을 만들지 못했습니다.") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let target = try FileHandle(forWritingTo: temporary)
        defer { try? target.close() }
        var hash = SHA256(), offset: UInt64 = 0
        while offset < UInt64(file.size) {
            let data = try file.read(offset: offset, count: Int(min(256 * 1024, UInt64(file.size) - offset)))
            guard !data.isEmpty else { throw NativePDFError.invalid("PDF 복사 도중 파일이 바뀌었습니다.") }
            hash.update(data: data); try target.write(contentsOf: data); offset += UInt64(data.count)
        }
        try target.synchronize()
        let revision = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let output = cache.appendingPathComponent(revision + ".pdf")
        if !FileManager.default.fileExists(atPath: output.path) { try FileManager.default.moveItem(at: temporary, to: output) }
        return (output, revision)
    }
}

@MainActor
private final class NativePDFDocument: NSObject, @preconcurrency PDFViewDelegate, @preconcurrency PDFPageOverlayViewProvider {
    let id: String, generation: String, courseID: String, relativePath: String, revision: String
    let document: PDFDocument
    let operationLedger: NativePDFOperationLedger
    private(set) var nativeInkEraseEnabled = false
    private struct EraseContext { let operationID: String; let epoch: Int }
    private var eraseContexts: [Int: EraseContext] = [:]
    let pdfView = NativePDFApertureView()
    var onStroke: ((Int, NativePDFCompletedStroke) throws -> Void)?
    var onDurabilityBarrier: (() throws -> Void)?
    var onCheckpoint: ((Int, NativePDFCompletedStroke) throws -> Void)?
    var onEvent: (String, [String: Any]) -> Void = { _, _ in }
    var onDiagnostic: (String, String) -> Void = { _, _ in }
    #if DEBUG
    var presentationDiagnostics = "" { didSet { updateAccessibilityState() } }
    func refreshPresentationDiagnostics() { updateAccessibilityState() }
    #endif
    private var journalCounts: [String: Int] = [:]
    private var latencyStatistics: [String: NativePDFLatencySamples] = [:]
    func recordLatency(_ phase: String, startedAt: CFTimeInterval) {
        latencyStatistics[phase, default: NativePDFLatencySamples()].record(milliseconds: (CACurrentMediaTime() - startedAt) * 1000)
        if let statistics = latencyStatistics[phase], statistics.shouldLog {
            onDiagnostic("nativePDF.hostTiming", "\(phase).\(statistics.logCode)")
        }
    }
    func recordJournal(_ kind: String, phase: String) {
        let key = "\(kind == "highlighter" ? "highlighter" : "ink").\(phase)", count = (journalCounts[key] ?? 0) + 1
        journalCounts[key] = count
        if count <= 20 || count.isMultiple(of: 50) { onDiagnostic("nativePDF.journal", "\(key).\(count)") }
    }
    var pending: [String: NativePDFStrokeInput] = [:]
    var pendingOrder: [String] = []
    private var acknowledgedRows: [String: String] = [:]
    var resolveImage: (([String: Any]) async throws -> UIImage)?
    private let images = NSCache<NSString, UIImage>()
    private var imageTasks: [String: Task<Void, Never>] = [:]
    private var imageFailures: Set<String> = []
    private var overlays: [Int: NativePDFInkSurface] = [:]
    var textEditor: (page: Int, view: NativePDFTextInputView)? { didSet {
        if oldValue?.view !== textEditor?.view { oldValue?.view.resignFirstResponder(); oldValue?.view.removeFromSuperview() }
        applyTextEditor()
    } }
    private var keyboardReveal: NSObjectProtocol?
    /// Scroll offset before a keyboard reveal, so finishing the box returns the page.
    private var revealOffset: CGPoint?
    /// The text view sits beside the PDF view in the host container, above it,
    /// so UIKit hit-testing and accessibility reach it directly.
    private func applyTextEditor() {
        if let view = textEditor?.view, let container = pdfView.superview {
            if view.superview !== container {
                view.isHidden = true; container.addSubview(view)
                DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() }
            }
            container.bringSubviewToFront(view)
        }
        for (number, overlay) in overlays { overlay.textEditor = textEditor?.page == number ? textEditor?.view : nil }
    }
    /// One-shot: once the keyboard is up, scroll the box above it.
    func revealTextEditorWhenKeyboardShows() {
        cancelKeyboardReveal()
        keyboardReveal = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelKeyboardReveal()
                guard let view = self.textEditor?.view, view.window != nil, let scroll = self.scrollView else { return }
                let before = scroll.contentOffset
                scroll.scrollRectToVisible(view.convert(view.bounds, to: scroll).insetBy(dx: 0, dy: -24), animated: false)
                if scroll.contentOffset != before, self.revealOffset == nil { self.revealOffset = before }
            }
        }
    }
    func cancelKeyboardReveal() {
        if let keyboardReveal { NotificationCenter.default.removeObserver(keyboardReveal) }
        keyboardReveal = nil
    }
    /// Undo the reveal: finishing a box returns the page to where editing started.
    func restoreScrollAfterTextEditing() {
        defer { revealOffset = nil }
        guard let offset = revealOffset, let scroll = scrollView else { return }
        // Synchronous, so the persistence barrier that follows records the restored position.
        scroll.setContentOffset(offset, animated: false)
    }
    private let drawingSnapshots = NativePDFDrawingSnapshotStore()
    private var objects: [[String: Any]] { drawingSnapshots.orderedRows.map(\.object) }
    private var pendingRows: [String: NativePDFDrawingSnapshotStore.Row] = [:]
    private var highlights: [[String: Any]] = []
    private var objectScenes: [Int: NativePDFEditorScene] = [:]
    private var objectSceneEpoch: Int?
    private var objectSceneRevisions: [Int: Int] = [:]
    private var objectScenePatchPages: Set<Int> = []
    private var tool = NativePDFInkSurface.Tool()
    private var loading = true
    private var workspaceActive = false
    private var observations: [NSObjectProtocol] = []
    private var viewportObservation: NSKeyValueObservation?
    private var navigating = false
    private var fit = 1.0
    private var layoutSize = CGSize.zero
    private var suspended = false
    private var suspendedViewport: [String: Any]?
    private weak var nativePinch: UIPinchGestureRecognizer?
    private weak var nativePan: UIPanGestureRecognizer?
    private struct PinchFallback {
        let generation: UInt64
        let page: PDFPage
        let anchor: CGPoint
        var zoom: NativePDFPinchZoomSession
    }
    private var pinchFallback: PinchFallback?
    private var pinchGeneration: UInt64 = 0
    private let pencilGesture: NativePDFPencilGestureRecognizer
    private var selectedTextRects: [Int: [[String: Double]]] = [:]
    private let pageActions = UIButton(type: .system)
    var usesNativeChrome = false { didSet { pageActions.isHidden = usesNativeChrome || loading } }
    private var pinchEvents = 0, scaleChanges = 0, navigateCommands = 0
    private var lastPinchState = 0, lastPinchScale = 1.0, lastRequestedZoom = 1.0
    #if DEBUG
    private var pinchTrace: [String] = []
    private var pinchTraceChanges = 0
    private var pinchFallbackApplications = 0, pinchAnchorChecks = 0
    private var pinchAnchorErrorMax: CGFloat = 0
    #endif
    private var submissionP95 = 0.0, submissionSamples = 0
    private var presentationStatistics = NativePDFInkFrameStatistics()
    var diagnostics: [String: Any] {
        ["page": state["page"] ?? 1, "zoom": pdfView.scaleFactor/max(fit,0.001), "fit": fit,
         "pinchEvents": pinchEvents, "pinchState": lastPinchState, "pinchScale": lastPinchScale,
         "scaleChanges": scaleChanges, "navigateCommands": navigateCommands, "requestedZoom": lastRequestedZoom,
         "scrollZoom": scrollView?.zoomScale ?? 0, "scrollMinZoom": scrollView?.minimumZoomScale ?? 0, "scrollMaxZoom": scrollView?.maximumZoomScale ?? 0, "autoScales": pdfView.autoScales,
         "receiveToMetalSubmitP95MS": submissionP95, "timingSamples": submissionSamples,
         "retainedPages": overlays.count, "suspended": suspended,
         "tool": tool.name, "loading": loading, "markup": pdfView.isInMarkupMode,
         "inputs": overlays.values.map(\.inputDiagnostics), "journalCounts": journalCounts,
         "hostTiming": latencyStatistics.mapValues(\.diagnostics)]
    }
    private var lastViewport = ""
    private var emission: Task<Void, Never>?
    /// Page geometry is fixed for a document revision; `state` goes out on every scroll emission.
    private lazy var pageSizes: [[String: Any]] = (0..<document.pageCount).compactMap { index -> [String: Any]? in
        guard let page = document.page(at: index) else { return nil }
        let crop = page.bounds(for: .cropBox), rotated = abs(page.rotation) % 180 != 0
        return ["page": index + 1, "width": rotated ? crop.height : crop.width, "height": rotated ? crop.width : crop.height]
    }
    var state: [String: Any] {
        let page = pdfView.currentPage.map { document.index(for: $0) + 1 } ?? 1
        return ["page": page, "numPages": document.pageCount, "zoom": pdfView.scaleFactor / max(fit, 0.001), "revision": revision, "documentRevision": revision,
                "pageSizes": pageSizes]
    }
    /// Captured synchronously for flush/close, independent of throttled UI events.
    var viewportState: [String: Any] {
        if suspended, let suspendedViewport { return suspendedViewport }
        var result: [String: Any] = ["page": 1, "zoom": Double(pdfView.scaleFactor / max(fit, 0.001))]
        let midpoint = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        if let page = pdfView.page(for: midpoint, nearest: true) ?? pdfView.currentPage {
            result["page"] = document.index(for: page) + 1
            let position = NativePDFPageCoordinates(page: page).displayNormalized(pdfView.convert(midpoint, to: page))
            // Direct Swift callers bypass JSON's CGFloat-to-number bridge.
            // Keep the transport scalar types identical to stored view state.
            result["progress"] = Double(min(1, max(0, position.y)))
            result["horizontalProgress"] = Double(min(1, max(0, position.x)))
        }
        return result
    }
    init(id: String, generation: String, courseID: String, relativePath: String, revision: String, document: PDFDocument, testingDirectPencil: Bool = false) {
        self.id = id; self.generation = generation; self.courseID = courseID; self.relativePath = relativePath; self.revision = revision; self.document = document
        operationLedger = NativePDFOperationLedger(documentRevision: revision)
        #if DEBUG
        pencilGesture = NativePDFPencilGestureRecognizer(testTouchType: testingDirectPencil ? .direct : .pencil)
        #else
        pencilGesture = NativePDFPencilGestureRecognizer()
        #endif
        super.init(); images.totalCostLimit = 64 * 1024 * 1024
        pdfView.accessibilityIdentifier = "bandal-native-pdf-body"
        pdfView.accessibilityLabel = "PDF 본문"
        pdfView.onContact = { [weak self] in self?.onEvent("activate", [:]) }
        pdfView.pencilTarget = { [weak self] point in
            guard let self, !self.suspended else { return nil }
            // Native page controls retain normal UIKit button handling.
            if !self.pageActions.isHidden, self.pageActions.frame.contains(point) { return nil }
            for overlay in self.overlays.values where overlay.window != nil {
                var ancestor = overlay.superview, visible = true
                while let view = ancestor, view !== self.pdfView {
                    if view.isHidden || view.alpha <= 0.01 { visible = false; break }
                    ancestor = view.superview
                }
                guard visible, ancestor === self.pdfView else { continue }
                if let target = overlay.pencilInputTarget(at: overlay.convert(point, from: self.pdfView)) { return target }
            }
            return nil
        }
        pdfView.delegate = self; pdfView.pageOverlayViewProvider = self
        pdfView.displayMode = .singlePageContinuous; pdfView.displayDirection = .vertical; pdfView.displayBox = .cropBox
        pdfView.pageShadowsEnabled = false; pdfView.backgroundColor = .secondarySystemBackground
        pdfView.document = document; pdfView.autoScales = true
        pdfView.isFindInteractionEnabled = true
        // Consume measured Pencil events in the recognizer phase. Waiting for
        // UIView.touchesBegan lets PDFKit's ancestors delay or absorb the stream.
        pencilGesture.targetAtLocation = { [weak self] point in
            self?.pdfView.pencilInputTarget(at: point) as? NativePDFInkSurface
        }
        pencilGesture.onDiagnostic = { [weak self] code in self?.onDiagnostic("nativePDF.gesture", code) }
        pdfView.addGestureRecognizer(pencilGesture)
        let annotationTap = UITapGestureRecognizer(target: self, action: #selector(annotationTapped(_:)))
        annotationTap.cancelsTouchesInView = false
        annotationTap.delaysTouchesBegan = false; annotationTap.delaysTouchesEnded = false
        annotationTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pdfView.addGestureRecognizer(annotationTap)
        var buttonStyle = UIButton.Configuration.gray()
        buttonStyle.image = UIImage(systemName: "ellipsis")
        buttonStyle.cornerStyle = .medium
        pageActions.configuration = buttonStyle
        pageActions.accessibilityIdentifier = "bandal-native-pdf-page-actions"
        pageActions.accessibilityLabel = "페이지 작업"
        pageActions.showsMenuAsPrimaryAction = true
        pageActions.menu = UIMenu(children: [
            UIAction(title: "페이지 이미지 복사", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.sendPageAction("imageMenu") },
            UIAction(title: "PDF에서 찾기", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in self?.pdfView.findInteraction.presentFindNavigator(showingReplace: false) }
        ])
        pdfView.addSubview(pageActions)
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    if name == .PDFViewScaleChanged { self?.scaleChanges += 1 }
                    self?.viewportChanged()
                }
            })
        }
        observations.append(NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.selectionChanged() }
        })
    }
    func prepareNavigation() {
        guard !suspended else { return }
        pdfView.layoutIfNeeded()
        if pdfView.bounds.width > 0, pdfView.bounds.height > 0, pdfView.bounds.size != layoutSize {
            cancelPinchFallback()
            let zoom = layoutSize == .zero ? 1 : pdfView.scaleFactor / max(fit, 0.001)
            fit = max(pdfView.scaleFactorForSizeToFit, 0.001)
            // Leaving autoScales enabled lets incidental host layout reset a
            // user's pinch to the fit scale while the workspace is laying out.
            pdfView.autoScales = false
            pdfView.minScaleFactor = fit * 0.4; pdfView.maxScaleFactor = fit * 4
            pdfView.scaleFactor = fit * min(4, max(0.4, zoom))
            layoutSize = pdfView.bounds.size
        }
        func visit(_ view: UIView) {
            if let scroll = view as? UIScrollView {
                // Native finger navigation and raw Pencil ownership must not
                // compete for the same stylus stream.
                scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
                // Keep PDFKit's pan/pinch pair and its simultaneous-recognition
                // policy. A second pinch on PDFView competes with that pair.
                scroll.pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                scroll.pinchGestureRecognizer?.isEnabled = true
                scroll.alwaysBounceVertical = true // pull past the last page to add one
                if nativePinch !== scroll.pinchGestureRecognizer, nativePinch == nil {
                    nativePinch = scroll.pinchGestureRecognizer
                    nativePinch?.addTarget(self, action: #selector(pinchChanged(_:)))
                }
                if nativePan == nil {
                    nativePan = scroll.panGestureRecognizer
                    nativePan?.addTarget(self, action: #selector(panChanged(_:)))
                }
                if viewportObservation == nil {
                    viewportObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor in self?.viewportChanged() }
                    }
                }
            }
            view.subviews.forEach(visit)
        }
        visit(pdfView)
        pageActions.frame = CGRect(x: max(0, pdfView.bounds.width-52), y: 8, width: 44, height: 44)
        pdfView.bringSubviewToFront(pageActions)
        overlays.values.forEach { $0.refreshViewport() }
        updateAccessibilityState()
    }
    private func sendPageAction(_ action: String) {
        do { try flush() } catch { onEvent("error", ["message": error.localizedDescription]); return }
        guard let page = pdfView.page(for: CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), nearest: true) else { return }
        onEvent("pageAction", ["action": action, "page": document.index(for: page) + 1,
            "x": pageActions.frame.midX, "y": pageActions.frame.maxY])
    }
    @objc private func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
        pinchEvents += 1; lastPinchState = pinch.state.rawValue; lastPinchScale = pinch.scale
        if pinch.state == .began {
            do { try prepareForNavigation() } catch { onEvent("error", ["message": error.localizedDescription]) }
            pinchGeneration &+= 1
            pinchFallback = nil
            let center = pinch.location(in: pdfView)
            if let page = pdfView.page(for: center, nearest: true),
               let zoom = NativePDFPinchZoomSession(pdfScale: pdfView.scaleFactor, recognizerScale: pinch.scale) {
                pinchFallback = PinchFallback(generation: pinchGeneration, page: page,
                    anchor: pdfView.convert(center, to: page), zoom: zoom)
            }
        }
        if pinch.state == .cancelled || pinch.state == .failed { cancelPinchFallback() }
        if pinch.state == .changed || pinch.state == .ended {
            // UIScrollView uses an absolute recognizer scale during its pinch,
            // then resets it to one after ending. Capture before that reset.
            let rawScale = pinch.scale, center = pinch.location(in: pdfView)
            let ended = pinch.state == .ended, generation = pinchGeneration
            DispatchQueue.main.async { [weak self] in
                self?.completeNativePinchObservation(rawScale: rawScale, center: center,
                    ended: ended, generation: generation)
            }
        }
        #if DEBUG
        if pinch.state == .began { pinchTrace = []; pinchTraceChanges = 0 }
        if pinch.state == .changed { pinchTraceChanges += 1 }
        if pinch.state != .changed || pinchTraceChanges <= 2 {
            let phase = pinch.state.rawValue
            recordPinchTrace("\(phase)", pinch: pinch)
            DispatchQueue.main.async { [weak self, weak pinch] in
                guard let self, let pinch else { return }
                self.recordPinchTrace("p\(phase)", pinch: pinch)
                self.updateAccessibilityState()
            }
        }
        #endif
        livePinch = pinch.state == .began || pinch.state == .changed
        if !livePinch { overlays.values.forEach { $0.finishLiveZoom() } }
        viewportChanged()
        updateAccessibilityState()
    }
    private var livePinch = false
    private func cancelPinchFallback() { pinchGeneration &+= 1; pinchFallback = nil }
    private func completeNativePinchObservation(rawScale: CGFloat, center: CGPoint, ended: Bool, generation: UInt64) {
        guard !suspended, pinchGeneration == generation,
              var fallback = pinchFallback, fallback.generation == generation else { return }
        defer { if ended, pinchGeneration == generation { pinchFallback = nil } }
        let target = fallback.zoom.targetScale(recognizerScale: rawScale, actualPDFScale: pdfView.scaleFactor,
            minimum: pdfView.minScaleFactor, maximum: pdfView.maxScaleFactor, ended: ended)
        pinchFallback = fallback
        guard let target, let scroll = scrollView else { return }
        // Some physical PDFKit builds report a fully recognized native pinch
        // without applying its scale. Only that session takes this public-API
        // fallback; an observed native zoom always remains owned by PDFKit.
        pdfView.scaleFactor = target; pdfView.layoutIfNeeded()
        let projected = pdfView.convert(fallback.anchor, from: fallback.page)
        let inset = scroll.adjustedContentInset
        let maximumX = max(-inset.left, scroll.contentSize.width-scroll.bounds.width+inset.right)
        let maximumY = max(-inset.top, scroll.contentSize.height-scroll.bounds.height+inset.bottom)
        let desiredOffset = CGPoint(x: scroll.contentOffset.x+projected.x-center.x,
                                    y: scroll.contentOffset.y+projected.y-center.y)
        scroll.contentOffset = CGPoint(
            x: min(maximumX, max(-inset.left, desiredOffset.x)),
            y: min(maximumY, max(-inset.top, desiredOffset.y)))
        #if DEBUG
        pinchFallbackApplications += 1
        if abs(scroll.contentOffset.x-desiredOffset.x) < 0.001,
           abs(scroll.contentOffset.y-desiredOffset.y) < 0.001 {
            let actualAnchor = pdfView.convert(fallback.anchor, from: fallback.page)
            pinchAnchorChecks += 1
            pinchAnchorErrorMax = max(pinchAnchorErrorMax, hypot(actualAnchor.x-center.x, actualAnchor.y-center.y))
        }
        onDiagnostic("nativePDF.pinch", String(format: "fallback.raw%.4f.target%.4f.actual%.4f", rawScale, target, pdfView.scaleFactor))
        #endif
        viewportChanged()
    }
    #if DEBUG
    private func recordPinchTrace(_ phase: String, pinch: UIPinchGestureRecognizer) {
        let scroll = scrollView
        let zoomView = scroll.flatMap { $0.delegate?.viewForZooming?(in: $0) }
        let entry = String(format: "%@r%.3f/f%.3f/s%.3f/z%d/v%d/e%d/m%d/t%d", phase,
            pinch.scale, pdfView.scaleFactor, scroll?.zoomScale ?? 0, scroll?.isZooming == true ? 1 : 0,
            zoomView != nil ? 1 : 0, scroll?.isScrollEnabled == true ? 1 : 0,
            pdfView.isInMarkupMode ? 1 : 0, pinch.numberOfTouches)
        if pinchTrace.count < 12 { pinchTrace.append(entry) }
        onDiagnostic("nativePDF.pinch", entry)
    }
    #endif
    @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began {
            do { try prepareForNavigation() } catch { onEvent("error", ["message": error.localizedDescription]) }
        }
    }
    func setVisible(_ visible: Bool) throws {
        if !visible {
            cancelPinchFallback()
            pdfView.isHidden = true
            if !suspended {
                try flush()
                suspendedViewport = viewportState; suspended = true
                viewportObservation = nil; nativePinch = nil; nativePan = nil
                pdfView.document = nil; overlays.removeAll(); releaseCaches()
            }
            pdfView.isHidden = true
        } else {
            if suspended {
                suspended = false; pdfView.document = document; pdfView.layoutIfNeeded(); prepareNavigation()
                if let viewport = suspendedViewport { try navigate(viewport) }
                suspendedViewport = nil
            }
            pdfView.isHidden = false
        }
    }
    func releaseCaches() {
        do { try flush() } catch { onEvent("error", ["message": error.localizedDescription]); return }
        NativePDFObjectRenderer.releaseInkPaths()
        drawingSnapshots.releasePreparedInk(); pendingRows.values.forEach { $0.releasePreparedInk() }
        objectScenes.values.forEach { $0.releasePreparedInk() }
        imageTasks.values.forEach { $0.cancel() }; imageTasks.removeAll(); images.removeAllObjects()
        if !suspended { refreshOverlays() }
    }
    func snapshot(_ request: [String: Any]) throws -> [String: Any] {
        let started = CACurrentMediaTime(); defer { recordLatency("snapshot", startedAt: started) }
        let nextNativeErase: Bool
        if let raw = request["nativeInkErase"] {
            guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw NativePDFEditorScene.invalid() }
            // Once adopted, the ordered bridge is generation-scoped. A later
            // partial snapshot cannot silently abandon outstanding operations.
            guard !nativeInkEraseEnabled || value.boolValue else { throw NativePDFEditorScene.invalid() }
            nextNativeErase = value.boolValue
        } else { nextNativeErase = nativeInkEraseEnabled }
        var nextTool: NativePDFInkSurface.Tool?
        if let value = request["tool"] as? [String: Any], let name = value["name"] as? String,
           let data = try? JSONSerialization.data(withJSONObject: value["style"] as? [String: Any] ?? [:]),
           let style = try? JSONDecoder().decode(NativePDFInkStyle.self, from: data), style.isValid {
            nextTool = .init(name: name, drawAndHold: value["drawAndHold"] as? Bool ?? true, style: style, lassoBox: value["lassoMode"] as? String == "box")
        }
        let epoch: Int?
        if request["objectSceneEpoch"] != nil {
            guard let value = NativePDFEditorScene.integer(request["objectSceneEpoch"]), let nextTool,
                  ["select", "lasso", "pen", "highlighter", "eraser", "line", "arrow", "rect", "ellipse", "text"].contains(nextTool.name),
                  value >= (objectSceneEpoch ?? 0),
                  value != objectSceneEpoch || nextTool.name == tool.name else { throw NativePDFEditorScene.invalid() }
            epoch = value
        } else {
            guard objectSceneEpoch == nil else { throw NativePDFEditorScene.invalid() }
            epoch = nil
        }
        // Reject an invalid delta before changing either drawings or UI state.
        let changedPages = try drawingSnapshots.apply(request, pageCount: document.pageCount)
        let nextHighlights = request["annotations"] as? [[String: Any]] ?? []
        let nextLoading = request["loading"] as? Bool ?? true
        // Anything that changes every overlay's inputs refreshes all of them;
        // a plain ink delta only touches the pages whose rows changed.
        let refreshAll = request["drawings"] != nil || nativeInkEraseEnabled != nextNativeErase || epoch != objectSceneEpoch
            || (nextTool != nil && nextTool != tool) || loading != nextLoading || !(nextHighlights as NSArray).isEqual(to: highlights)
        nativeInkEraseEnabled = nextNativeErase
        if nativeInkEraseEnabled, request["drawings"] != nil || request["drawingPatch"] != nil {
            operationLedger.observeCanonical(objects)
        }
        if epoch != objectSceneEpoch {
            // Retire delta authority, while preserving the displayed editor
            // state until its replacement arrives. Switching non-ink tools
            // must not flash canonical rows hidden by an active local edit.
            objectSceneRevisions.removeAll(); objectScenePatchPages.removeAll()
            objectSceneEpoch = epoch
        }
        highlights = nextHighlights
        loading = nextLoading
        workspaceActive = request["active"] as? Bool ?? false
        if let nextTool {
            tool = nextTool
            if ["pen", "highlighter"].contains(tool.name) {
                objectScenes.removeAll()
                if nativeInkEraseEnabled { operationLedger.retireEditors() }
            }
        }
        // The Pencil-specific aperture and ancestor recognizer route measured
        // ink directly to our overlay. Keep PDFKit's reading-mode gesture path
        // for fingers while writing; markup redirects all page hit testing to
        // overlays and can prevent PDFKit's own pinch from changing its scale.
        let markup = !["select", "pen", "highlighter"].contains(tool.name)
        if pdfView.isInMarkupMode != markup {
            pdfView.isInMarkupMode = markup
            onDiagnostic("nativePDF.mode", "\(tool.name).markup.\(markup ? "on" : "off")")
        }
        refreshOverlays(pages: refreshAll ? nil : changedPages)
        pageActions.isHidden = usesNativeChrome || loading
        updateAccessibilityState()
        return epoch.map { ["objectSceneEpoch": $0, "tool": tool.name] } ?? [:]
    }
    func objectScene(_ request: [String: Any]) throws -> [String: Any] {
        let started = CACurrentMediaTime(); defer { recordLatency("objectScene", startedAt: started) }
        if request["objectSceneEpoch"] != nil || request["objectSceneRevision"] != nil || request["objectPatch"] != nil {
            guard let epoch = NativePDFEditorScene.integer(request["objectSceneEpoch"]), epoch == objectSceneEpoch,
                  !["pen", "highlighter"].contains(tool.name),
                  let page = NativePDFEditorScene.integer(request["page"]), (1...document.pageCount).contains(page),
                  let revision = NativePDFEditorScene.integer(request["objectSceneRevision"]),
                  revision > (objectSceneRevisions[page] ?? 0) else { throw NativePDFEditorScene.invalid() }
            let next: NativePDFEditorScene
            let isPatch = request["objectPatch"] != nil
            if isPatch {
                guard request["objects"] == nil, let patch = request["objectPatch"] as? [String: Any],
                      let reset = patch["reset"] as? NSNumber, CFGetTypeID(reset) == CFBooleanGetTypeID(),
                      let base = NativePDFEditorScene.integer(patch["baseRevision"]),
                      NativePDFEditorScene.integer(patch["revision"]) == revision,
                      reset.boolValue ? base == 0 : (objectScenePatchPages.contains(page) && base == objectSceneRevisions[page])
                else { throw NativePDFEditorScene.invalid() }
                next = try NativePDFEditorScene(patch: patch, request: request, page: page, pageCount: document.pageCount,
                    store: drawingSnapshots, previous: objectScenes[page])
            } else {
                guard request["objects"] is [[String: Any]] else { throw NativePDFEditorScene.invalid() }
                next = NativePDFEditorScene(request: request, page: page, pageCount: document.pageCount,
                    store: drawingSnapshots, previous: objectScenes[page])
            }
            // Entries, selection, revision and delta eligibility publish only
            // after the complete request validates. This scene never mutates
            // canonical drawings, pending Pencil checkpoints or the journal.
            objectScenes[page] = next; objectSceneRevisions[page] = revision
            if nativeInkEraseEnabled { operationLedger.observeEditor(page: page, objects: next.identityObjects) }
            if isPatch { objectScenePatchPages.insert(page) } else { objectScenePatchPages.remove(page) }
            refreshOverlays(pages: [page])
            return ["page": page, "objectSceneEpoch": epoch, "objectSceneRevision": revision]
        }
        guard objectSceneEpoch == nil else { throw NativePDFEditorScene.invalid() }
        guard !["pen", "highlighter"].contains(tool.name), let page = request["page"] as? Int,
              (1...document.pageCount).contains(page), request["objects"] is [[String: Any]] else { return [:] }
        objectScenes[page] = NativePDFEditorScene(request: request, page: page, pageCount: document.pageCount,
            store: drawingSnapshots, previous: objectScenes[page])
        if nativeInkEraseEnabled, let scene = objectScenes[page] {
            operationLedger.observeEditor(page: page, objects: scene.identityObjects)
        }
        refreshOverlays(pages: [page])
        return [:]
    }
    private func beginErase(page: Int) {
        guard nativeInkEraseEnabled else { return }
        eraseContexts[page] = EraseContext(operationID: UUID().uuidString, epoch: objectSceneEpoch ?? 0)
    }
    private func commitErase(page: Int, targets: [NativePDFEraseTarget]) throws {
        guard nativeInkEraseEnabled, (1...document.pageCount).contains(page),
              let context = eraseContexts[page] else { throw NativePDFError.invalid("PDF 지우기 접촉의 시작 상태를 확인하지 못했습니다.") }
        let normalized = try targets.map { target -> NativePDFEraseTarget in
            guard let mutation = target.mutationID else { return target }
            let saved = operationLedger.drawingID(for: mutation) ?? acknowledgedRows[mutation]
            let isPending = pending[mutation] != nil
            // The scene freezes for the whole eraser contact, so it can still name
            // the placeholder (id == mutation) after the ACK and canonical row
            // retired the pending row mid-contact. A placeholder is never a
            // mismatch; it resolves to whatever the ACK saved.
            let isPlaceholder = target.drawingID?.utf8.elementsEqual(mutation.utf8) == true
            if UUID(uuidString: mutation) != nil, isPending || saved != nil {
                if let supplied = target.drawingID, !isPlaceholder, let saved,
                   !supplied.utf8.elementsEqual(saved.utf8) {
                    throw NativePDFError.invalid("PDF 지우기 대상의 저장 식별자가 일치하지 않습니다.")
                }
                return NativePDFEraseTarget(drawingID: isPlaceholder ? saved : (target.drawingID ?? saved), mutationID: mutation)
            }
            // Persisted rows may carry a prior renderer session's alias. Only
            // a current native journal/ACK association authorizes sending M;
            // otherwise the already-canonical D is sufficient and unambiguous.
            guard let drawing = target.drawingID, !drawing.isEmpty else {
                throw NativePDFError.invalid("PDF 지우기 대상의 저장 식별자를 확인하지 못했습니다.")
            }
            return NativePDFEraseTarget(drawingID: drawing)
        }
        let payload = try operationLedger.recordErase(operationID: context.operationID,
            originToolEpoch: context.epoch, page: page, targets: normalized)
        // Preserve the same operation UUID/epoch when this callback throws.
        // Only a successfully recorded operation transfers gesture ownership.
        eraseContexts.removeValue(forKey: page)
        refreshOverlays(pages: [page])
        onEvent("eraseCommit", payload)
    }
    func acknowledgePreview(mutationID: String, drawingID: String) {
        if let input = pending[mutationID] {
            overlays[input.page]?.rememberNativeMutationAlias(mutationID: mutationID, drawingID: drawingID)
        }
        acknowledgedRows[mutationID] = drawingID
        refreshOverlays(pages: (pending[mutationID]?.page).map { [$0] })
        publishPendingCount()
    }
    private var deferredPendingInputs: [String: NativePDFStrokeInput] = [:]
    private var deferredPendingTask: Task<Void, Never>?
    /// Coalesces the display update of corrected checkpoints; the latest input per mutation wins.
    func deferPendingDisplay(_ input: NativePDFStrokeInput) {
        deferredPendingInputs[input.clientMutationId] = input
        guard deferredPendingTask == nil else { return }
        deferredPendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self else { return }
            self.deferredPendingTask = nil
            let inputs = self.deferredPendingInputs.values.filter { self.pending[$0.clientMutationId] != nil }
            self.deferredPendingInputs = [:]
            for input in inputs { self.addPending(input, notify: false) }
            if !inputs.isEmpty { self.refreshOverlays(pages: Set(inputs.map(\.page))) }
            self.publishPendingCount()
        }
    }
    func addPending(_ input: NativePDFStrokeInput, notify: Bool = true) {
        let started = CACurrentMediaTime(); defer { recordLatency("pendingRow", startedAt: started) }
        // A newer row (final stroke or ACK) must not be overwritten by an older deferred checkpoint.
        deferredPendingInputs.removeValue(forKey: input.clientMutationId)
        if pending[input.clientMutationId] == nil { pendingOrder.append(input.clientMutationId) }
        pending[input.clientMutationId] = input
        // Estimated-property corrections replace only their own immutable row.
        // Existing measured strokes do no JSON/path work during later refreshes.
        if var object = try? NativePDFHost.json(input) {
            object["id"] = input.clientMutationId
            if let shape = input.heldShape {
                let fit = input.kind == "highlighter" ? shape.inkPayload : shape.payload
                object["kind"] = input.kind == "highlighter" ? "highlighter" : fit["kind"]
                object["data"] = fit["data"]
                if input.kind != "highlighter" { object["style"] = shape.shapeStyle(object["style"] as? [String: Any] ?? [:]) }
            }
            pendingRows[input.clientMutationId] = try? drawingSnapshots.makeRow(object, pageCount: document.pageCount,
                previous: pendingRows[input.clientMutationId])
        }
        if notify { publishPendingCount() }
    }
    private func publishPendingCount() {
        onEvent("pending", ["count": pending.keys.filter { acknowledgedRows[$0] == nil }.count])
    }
    /// `pages` limits the row rebuild and retained-scene revalidation to the
    /// overlays whose content changed; nil refreshes every overlay.
    func refreshOverlays(pages only: Set<Int>? = nil) {
        let started = CACurrentMediaTime(); defer { recordLatency("refreshOverlays", startedAt: started) }
        var pages = only
        // Only already-ACKed previews can be retired by the two-stream erase
        // barrier. Their original journal was removed by the normal stroke ACK.
        for target in operationLedger.takeRetiredTargets() {
            if let mutation = target.mutationID, let drawing = target.drawingID,
               acknowledgedRows[mutation]?.utf8.elementsEqual(drawing.utf8) == true {
                if let page = pending[mutation]?.page { pages?.insert(page) }
                pending.removeValue(forKey: mutation); acknowledgedRows.removeValue(forKey: mutation)
            }
        }
        pages?.formUnion(operationLedger.takeRetiredPages())
        for (number, overlay) in overlays {
            if let pages, !pages.contains(number) { continue }
            overlay.retainedInkEnabled = nativeInkEraseEnabled
            overlay.nativeErasingEnabled = nativeInkEraseEnabled
            let excluded = operationLedger.excludedIdentifiers(page: number)
            overlay.erasedIdentifiers = excluded
            overlay.tool = tool; overlay.isLoading = loading
            overlay.textEditor = textEditor?.page == number ? textEditor?.view : nil
            overlay.highlights = highlights.filter { $0["page"] as? Int == number }
            overlay.selectedTextRects = selectedTextRects[number] ?? []
            let scene = objectScenes[number]
            let rows = drawingSnapshots.rows(page: number)
            let coordinates = document.page(at: number - 1).map { NativePDFPageCoordinates(page: $0) }
            let aspect = coordinates.map { $0.height / $0.width } ?? sqrt(2)
            var drawings = scene?.prepared(aspect: aspect) ?? rows.map { $0.prepared(aspect: aspect) }
            var tokens = scene?.visualTokens ?? rows.map(\.visualToken)
            overlay.selectionBox = scene?.selection
            overlay.selectionResizable = scene?.resizable ?? false
            overlay.selectionTextHandles = scene?.textHandles ?? false
            let pendingInputs = pendingOrder.compactMap { pending[$0] }.filter { $0.page == number }
            if !pendingInputs.isEmpty {
                let present = Set(drawings.flatMap { [$0["id"] as? String, $0["clientMutationId"] as? String].compactMap { $0 } })
                for input in pendingInputs {
                    let acknowledged = acknowledgedRows[input.clientMutationId]
                    if present.contains(input.clientMutationId) || acknowledged.map(present.contains) == true {
                        if acknowledged != nil { pending.removeValue(forKey: input.clientMutationId); acknowledgedRows.removeValue(forKey: input.clientMutationId) }
                        continue
                    }
                    guard let row = pendingRows[input.clientMutationId] else { continue }
                    drawings.append(row.prepared(aspect: aspect)); tokens.append(row.visualToken)
                }
            }
            // Tombstones affect presentation only. Keep canonical snapshots,
            // editor revision bases and durable native checkpoints untouched.
            // Filter paired rows/tokens for both retained GPU and CG fallback.
            let excludedKeys = Set(excluded.map { Data($0.utf8) })
            if !excludedKeys.isEmpty {
                let visible = zip(drawings, tokens).filter { object, _ in
                    ![object["id"] as? String, object["clientMutationId"] as? String]
                        .compactMap { $0 }.contains { excludedKeys.contains(Data($0.utf8)) }
                }
                drawings = visible.map(\.0); tokens = visible.map(\.1)
            }
            overlay.applyObjects(objects: drawings, visualTokens: tokens)
            for object in drawings where ["image", "clip"].contains(object["kind"] as? String ?? "") {
                let key = Self.imageKey(object)
                guard images.object(forKey: key as NSString) == nil, imageTasks[key] == nil, !imageFailures.contains(key), let resolveImage else { continue }
                imageTasks[key] = Task { @MainActor [weak self] in
                    do {
                        let image = try await resolveImage(object)
                        guard let self, !Task.isCancelled else { return }
                        self.images.setObject(image, forKey: key as NSString, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
                        self.overlays.values.forEach { $0.invalidateBackdrop(reason: "image") }
                    } catch { if !Task.isCancelled { self?.imageFailures.insert(key); self?.onEvent("error", ["message": error.localizedDescription]) } }
                    self?.imageTasks.removeValue(forKey: key)
                }
            }
        }
        pendingOrder.removeAll { pending[$0] == nil }
        pendingRows = pendingRows.filter { pending[$0.key] != nil }
        publishSelectionFrame()
    }
    private var lastSelectionFrame: [String: Any] = [:]
    /// The selection box in the host container's coordinates, so SwiftUI can
    /// float an action bar above it. Emits only when the rectangle changes.
    private func publishSelectionFrame() {
        var payload: [String: Any] = [:]
        for (number, overlay) in overlays {
            guard overlay.window != nil, let box = overlay.selectionBox, let mapper = overlay.mapper,
                  let x = box["x"], let y = box["y"], let w = box["width"], let h = box["height"], [x, y, w, h].allSatisfy(\.isFinite) else { continue }
            let a = mapper.canvasPoint(InkPoint(x: x, y: y, p: 0.5)), b = mapper.canvasPoint(InkPoint(x: x + w, y: y + h, p: 0.5))
            let local = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            let rect = overlay.convert(local, to: pdfView.superview ?? pdfView)
            payload = ["page": number, "x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
            break
        }
        guard !NSDictionary(dictionary: payload).isEqual(to: lastSelectionFrame) else { return }
        lastSelectionFrame = payload; onEvent("selectionFrame", payload)
    }
    private static func imageKey(_ object: [String: Any]) -> String {
        let value = object["data"] as? [String: Any] ?? [:]
        let source = value["image"] ?? value["clip"] ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: source, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func navigate(_ request: [String: Any]) throws {
        cancelPinchFallback()
        try flush(); navigating = true; defer { navigating = false; viewportChanged() }
        navigateCommands += 1
        if let zoom = request["zoom"] as? Double { lastRequestedZoom = zoom }
        if let zoom = request["zoom"] as? Double, zoom.isFinite, (0.4...4).contains(zoom) { pdfView.scaleFactor = fit * zoom }
        if let number = request["page"] as? Int, let page = document.page(at: number - 1) {
            let ratio = min(1, max(0, request["progress"] as? Double ?? 0))
            let coordinates = NativePDFPageCoordinates(page: page)
            pdfView.go(to: page); pdfView.layoutIfNeeded()
            let horizontal = min(1, max(0, request["horizontalProgress"] as? Double ?? 0.5))
            let center = pdfView.convert(coordinates.pdfPoint(CGPoint(x: horizontal, y: ratio)), from: page)
            if let scroll = scrollView {
                let desired = scroll.contentOffset.y + center.y - pdfView.bounds.midY
                scroll.contentOffset.y = max(-scroll.adjustedContentInset.top, min(scroll.contentSize.height-scroll.bounds.height+scroll.adjustedContentInset.bottom, desired))
                let desiredX = scroll.contentOffset.x + center.x - pdfView.bounds.midX
                scroll.contentOffset.x = max(-scroll.adjustedContentInset.left, min(max(-scroll.adjustedContentInset.left, scroll.contentSize.width-scroll.bounds.width+scroll.adjustedContentInset.right), desiredX))
            }
        }
    }
    func pageGeometry(_ number: Int) throws -> [String: Double] {
        guard let page = document.page(at: number-1), !suspended else { throw NativePDFError.invalid("PDF 편집 페이지가 닫혔습니다.") }
        let rect = pdfView.convert(page.bounds(for: .cropBox), from: page)
        return ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
    private var pullToAddArmed = false
    /// Pulling well past the end while the finger is down, then releasing, adds a page.
    private func checkPullToAddPage() {
        guard let scroll = nativePan?.view as? UIScrollView, !loading else { return }
        let rest = max(scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom, -scroll.adjustedContentInset.top)
        let overscroll = scroll.contentOffset.y - rest
        if scroll.isTracking {
            if overscroll > 120, !pullToAddArmed { pullToAddArmed = true; UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            else if overscroll < 40 { pullToAddArmed = false }
        } else if pullToAddArmed {
            pullToAddArmed = false; onEvent("pullToAddPage", [:])
        }
    }
    private func viewportChanged() {
        overlays.values.forEach { $0.refreshViewport() }
        checkPullToAddPage()
        publishSelectionFrame()
        updateAccessibilityState()
        guard !navigating, !suspended else { return }
        emission?.cancel()
        // Each viewport event re-renders the whole PdfTab in the renderer.
        // Coalesce gesture frames; the final position always goes out.
        let wait = max(0, Self.viewportEmissionInterval - (CACurrentMediaTime() - lastViewportEmissionAt))
        emission = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) } else { await Task.yield() }
            guard !Task.isCancelled, let self, !self.suspended else { return }
            let payload = self.state.merging(self.viewportState) { _, current in current }
            let signature = "\(payload["page"] ?? 0):\(payload["zoom"] ?? 0):\(payload["progress"] ?? 0):\(payload["horizontalProgress"] ?? 0)"
            guard signature != self.lastViewport else { return }
            self.lastViewport = signature; self.lastViewportEmissionAt = CACurrentMediaTime()
            self.onEvent("viewport", payload)
        }
    }
    private static let viewportEmissionInterval: CFTimeInterval = 0.08
    private var lastViewportEmissionAt: CFTimeInterval = 0
    /// Accessibility values exist for XCUITest assertions. Formatting them on
    /// every scroll frame maps all rows twice, so production skips it.
    private static let diagnosticsEnabled = ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.arguments.contains("--native-ui-testing") || NSClassFromString("XCTestCase") != nil
    private func updateAccessibilityState() {
        guard Self.diagnosticsEnabled else { return }
        let number = pdfView.currentPage.map { document.index(for: $0) + 1 } ?? 1
        pdfView.accessibilityValue = String(format: "page=%d zoom=%.4f scale=%.4f width=%.1f height=%.1f pinch=%d pinchScale=%.3f scaleChanges=%d navigation=%d requestedZoom=%.3f submitP95ms=%.2f samples=%d scrollZoom=%.3f scrollMin=%.3f scrollMax=%.3f autoScales=%d active=%d", number,
            pdfView.scaleFactor/max(fit,0.001), pdfView.scaleFactor, pdfView.bounds.width, pdfView.bounds.height,
            pinchEvents, lastPinchScale, scaleChanges, navigateCommands, lastRequestedZoom, submissionP95, submissionSamples,
            scrollView?.zoomScale ?? 0, scrollView?.minimumZoomScale ?? 0, scrollView?.maximumZoomScale ?? 0, pdfView.autoScales ? 1 : 0, workspaceActive ? 1 : 0)
        #if DEBUG
        pdfView.accessibilityValue = (pdfView.accessibilityValue ?? "") + " drawings=\(objects.count) pending=\(pending.count)"
        pdfView.accessibilityValue = (pdfView.accessibilityValue ?? "") + String(format:
            " presentP95ms=%.2f firstPresentP95ms=%.2f liveFrames=%d liveStrokes=%d lateStrokes=%d",
            presentationStatistics.receiveToPresentP95MS, presentationStatistics.firstPresentationP95MS,
            presentationStatistics.framesBeforeLift, presentationStatistics.strokesBeforeLift, presentationStatistics.strokesAfterLift)
        let scenes = overlays.values.map(\.inputDiagnostics)
        pdfView.accessibilityValue = (pdfView.accessibilityValue ?? "") +
            " sceneFull=\(scenes.reduce(0) { $0 + ($1["sceneFullRenders"] as? Int ?? 0) })" +
            " sceneAppend=\(scenes.reduce(0) { $0 + ($1["sceneAppendRenders"] as? Int ?? 0) })"
        let retainedActive = scenes.contains { $0["retainedInkActive"] as? Bool == true } ? 1 : 0
        let retainedMeshes = scenes.reduce(0) { $0 + ($1["retainedInkMeshes"] as? Int ?? 0) }
        let retainedInstalls = scenes.reduce(0) { $0 + ($1["retainedInkInstalls"] as? Int ?? 0) }
        let retainedBuilds = scenes.reduce(0) { $0 + ($1["retainedInkMeshBuilds"] as? Int ?? 0) }
        let retainedObjects = scenes.reduce(0) { $0 + ($1["retainedObjectTextures"] as? Int ?? 0) }
        let nonInkObjects = objects.filter { !["ink", "highlighter"].contains($0["kind"] as? String ?? "") }.count
        let retainedSummary = " retainedActive=\(retainedActive) countMesh=\(retainedMeshes) retainedInstalls=\(retainedInstalls)"
        let operationSummary = " retainedMeshBuilds=\(retainedBuilds) nativeEraseOperations=\(operationLedger.eraseOperationCount) retainedObjects=\(retainedObjects) nonInkObjects=\(nonInkObjects)"
        pdfView.accessibilityValue = (pdfView.accessibilityValue ?? "") + retainedSummary + operationSummary
        pdfView.accessibilityValue = (pdfView.accessibilityValue ?? "") + String(format:
            " navMaxms=%.2f navRefresh=%d navRenders=%d navActive=%d scrollY=%.2f",
            scenes.map { $0["navigationRefreshMaxCPUMS"] as? Double ?? 0 }.max() ?? 0,
            scenes.reduce(0) { $0 + ($1["navigationRefreshCount"] as? Int ?? 0) },
            scenes.reduce(0) { $0 + ($1["navigationAsyncRasterCount"] as? Int ?? 0) },
            scenes.contains { $0["navigationDisplayActive"] as? Bool == true } ? 1 : 0,
            scrollView?.contentOffset.y ?? 0)
        let apertures = pdfView.excludedRects.map { String(format: "%.1f,%.1f,%.1f,%.1f", $0.minX, $0.minY, $0.width, $0.height) }.joined(separator: ";")
        pdfView.accessibilityValue = (pdfView.accessibilityValue ?? "") +
            " \(presentationDiagnostics) nativeHidden=\(pdfView.isHidden ? 1 : 0) nativeInput=\(pdfView.isUserInteractionEnabled ? 1 : 0) apertures=[\(apertures)]"
        pdfView.accessibilityValue = (pdfView.accessibilityValue ?? "") + " pinchTrace=" + pinchTrace.joined(separator: "|")
        pdfView.accessibilityValue = (pdfView.accessibilityValue ?? "") + String(format:
            " pinchFallbacks=%d pinchAnchorChecks=%d pinchAnchorError=%.4f",
            pinchFallbackApplications, pinchAnchorChecks, pinchAnchorErrorMax)
        #endif
    }
    private func selectionChanged() {
        selectedTextRects.removeAll()
        defer { overlays.forEach { $0.value.selectedTextRects = selectedTextRects[$0.key] ?? [] } }
        guard let selection = pdfView.currentSelection, selection.pages.count == 1,
              let quote = selection.string, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = selection.pages.first else { onEvent("selection", [:]); return }
        let coordinates = NativePDFPageCoordinates(page: page)
        let rects = selection.selectionsByLine().filter { $0.pages.contains(page) }.map { line -> [String: Double] in
            coordinates.normalizedRect(line.bounds(for: page))
        }
        let selected = selection.bounds(for: page), viewRect = pdfView.convert(selected, from: page)
        selectedTextRects[document.index(for: page) + 1] = rects
        onEvent("selection", ["page": document.index(for: page) + 1, "quote": quote, "rects": rects, "x": viewRect.midX, "y": viewRect.maxY])
    }
    @objc private func annotationTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let location = gesture.location(in: pdfView)
        // A tap inside the live text box moves the caret; it is not "outside".
        if let view = textEditor?.view, view.window != nil, view.bounds.contains(gesture.location(in: view)) { return }
        onEvent("activate", [:])
        guard let page = pdfView.page(for: location, nearest: false) else { onEvent("bodyTap", [:]); return }
        let number = document.index(for: page) + 1
        let point = NativePDFPageCoordinates(page: page).displayNormalized(pdfView.convert(location, to: page))
        onEvent("bodyTap", ["page": number, "x": Double(point.x), "y": Double(point.y)])
        guard tool.name == "select" else { return }
        func contains(_ value: [String: Double]) -> Bool {
            guard let x = value["x"], let y = value["y"], let w = value["width"], let h = value["height"] else { return false }
            return CGRect(x: x, y: y, width: w, height: h).contains(point)
        }
        if objects.contains(where: { object in
            guard object["page"] as? Int == number, let data = object["data"] as? [String: Any], let box = data["box"] as? [String: Double] else { return false }
            return contains(box)
        }) { return }
        guard let annotation = highlights.last(where: { item in
            item["page"] as? Int == number && (item["rects"] as? [[String: Double]] ?? []).contains(where: contains)
        }), let id = annotation["id"] as? String else { return }
        onEvent("annotation", ["id": id, "x": location.x, "y": location.y])
    }
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) { onEvent("link", ["url": url.absoluteString]) }
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let number = document.index(for: page) + 1
        if let existing = overlays[number] { return existing }
        guard let overlay = NativePDFInkSurface() else { onEvent("error", ["message": "Metal 필기 표면을 만들지 못했습니다."]); return nil }
        overlay.pdfPage = page
        overlay.viewportProvider = { [weak self, weak overlay] in
            guard let self, let overlay else { return nil }
            return overlay.convert(self.pdfView.bounds, from: self.pdfView)
        }
        overlay.navigationInProgress = { [weak self] in
            guard let scroll = self?.scrollView else { return false }
            return scroll.isDragging || scroll.isDecelerating || scroll.isZooming || scroll.isZoomBouncing
        }
        overlay.liveZoom = { [weak self] in self?.livePinch == true }
        overlay.onNavigationStateChanged = { [weak self] in self?.updateAccessibilityState() }
        overlay.onSceneInstalled = { [weak self] in self?.updateAccessibilityState() }
        overlay.onEraseBegin = { [weak self] in self?.beginErase(page: number) }
        overlay.onErase = { [weak self] targets in
            guard let self else { throw NativePDFError.invalid("PDF 지우기 연결이 닫혔습니다.") }
            try self.commitErase(page: number, targets: targets)
        }
        overlay.onStroke = { [weak self] stroke in
            guard let onStroke = self?.onStroke else { throw NativePDFError.invalid("PDF 필기 저장 연결이 닫혔습니다.") }
            try onStroke(number, stroke)
        }
        overlay.onCheckpoint = { [weak self] stroke in
            guard let onCheckpoint = self?.onCheckpoint else { throw NativePDFError.invalid("PDF 필기 보정 저장 연결이 닫혔습니다.") }
            try onCheckpoint(number, stroke)
        }
        overlay.imageForObject = { [weak self] object in self?.images.object(forKey: Self.imageKey(object) as NSString) }
        overlay.onFailure = { [weak self] error in
            self?.recordJournal("ink", phase: "failure")
            self?.onEvent("error", ["message": error.localizedDescription])
        }
        overlay.onDiagnostic = { [weak self] code in self?.onDiagnostic("nativePDF.input", code) }
        overlay.onTiming = { [weak self] p95, samples in self?.submissionP95 = p95; self?.submissionSamples = samples; self?.updateAccessibilityState() }
        overlay.onPresentation = { [weak self] statistics in
            self?.presentationStatistics = statistics; self?.updateAccessibilityState()
        }
        overlay.onInteraction = { [weak self] tool, payload in self?.onEvent("interaction", payload.merging(["page": number, "tool": tool]) { _, new in new }) }
        overlay.onPointer = { [weak self] payload in self?.onEvent("pointer", payload.merging(["page": number]) { _, new in new }) }
        overlay.onInputOwnership = { [weak self] active in
            self?.onEvent(active ? "activate" : "deactivate", [:])
            // Touch-type filtering isolates the stylus. Toggling the finger
            // recognizers here cancels an already active pan or pinch.
        }
        overlay.onLayout = { [weak self, weak overlay, weak page] in
            guard let self, let overlay, let page, overlay.window != nil else { return }
            let coordinates = NativePDFPageCoordinates(page: page)
            let convert: (CGPoint) -> CGPoint = { coordinates.displayPhysical(self.pdfView.convert(overlay.convert($0, to: self.pdfView), to: page)) }
            guard let transform = NativePDFCoordinateMapping.sample(bounds: overlay.bounds, convert: convert) else { return }
            overlay.mapper = InkCoordinateMapper(canvasToPDF: transform, geometry: coordinates.geometry)
            self.publishSelectionFrame()
        }
        overlays[number] = overlay; refreshOverlays(); return overlay
    }
    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) { overlayView.setNeedsLayout() }
    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? NativePDFInkSurface else { return }
        let number = document.index(for: page) + 1
        do { try overlay.flush(); if overlays[number] === overlay { overlays.removeValue(forKey: number) } }
        catch { onEvent("error", ["message": error.localizedDescription]) }
    }
    private func prepareForNavigation() throws {
        for overlay in overlays.values { try overlay.prepareForNavigation() }
    }
    func flush() throws { for overlay in overlays.values { try overlay.flush() } }
    private var scrollView: UIScrollView? {
        func find(_ view: UIView) -> UIScrollView? { if let scroll = view as? UIScrollView { return scroll }; return view.subviews.lazy.compactMap(find).first }
        return find(pdfView)
    }
    func close() throws {
        cancelPinchFallback()
        try flush()
        try onDurabilityBarrier?()
        guard operationLedger.pendingEraseCount == 0 else { throw NativePDFError.invalid("지우기 저장 결과를 확인하지 못해 PDF를 닫지 않았습니다.") }
        emission?.cancel(); viewportObservation = nil
        observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
        imageTasks.values.forEach { $0.cancel() }; imageTasks.removeAll(); images.removeAllObjects()
        cancelKeyboardReveal(); textEditor = nil
        pdfView.removeFromSuperview(); pdfView.pageOverlayViewProvider = nil; pdfView.document = nil; overlays.removeAll()
        objectScenes.removeAll()
    }
}

/// Detects a no-op native zoom without competing with a working UIScrollView.
/// Input scales are captured inside the recognizer callback; evaluation runs
/// after UIKit's own target actions have had an opportunity to update PDFKit.
struct NativePDFPinchZoomSession {
    private let initialPDFScale: CGFloat
    private let initialRecognizerScale: CGFloat
    private var nativeMoved = false
    private var unchangedObservations = 0
    private var previousUnchangedTarget: CGFloat?
    private(set) var usingFallback = false

    init?(pdfScale: CGFloat, recognizerScale: CGFloat) {
        guard pdfScale.isFinite, recognizerScale.isFinite, pdfScale > 0, recognizerScale > 0 else { return nil }
        initialPDFScale = pdfScale; initialRecognizerScale = recognizerScale
    }

    mutating func targetScale(recognizerScale: CGFloat, actualPDFScale: CGFloat,
                              minimum: CGFloat, maximum: CGFloat, ended: Bool) -> CGFloat? {
        guard [recognizerScale, actualPDFScale, minimum, maximum].allSatisfy(\.isFinite),
              recognizerScale > 0, actualPDFScale > 0, minimum > 0, maximum >= minimum else { return nil }
        let requested = initialPDFScale * (recognizerScale / initialRecognizerScale)
        guard requested.isFinite else { return nil }
        let target = min(maximum, max(minimum, requested)), tolerance = initialPDFScale * 0.0001
        if !usingFallback {
            if abs(actualPDFScale-initialPDFScale) > tolerance { nativeMoved = true }
            guard !nativeMoved, abs(target-initialPDFScale) > tolerance else { return nil }
            // UIScrollView can deliver duplicate target callbacks before its
            // native zoom catches up. They are one observation, not evidence
            // that two different requested scales were both ignored.
            if previousUnchangedTarget.map({ abs(target-$0) > tolerance }) ?? true {
                unchangedObservations += 1; previousUnchangedTarget = target
            }
            guard unchangedObservations >= 2 || ended else { return nil }
            usingFallback = true
        }
        return abs(target-actualPDFScale) > tolerance ? target : nil
    }
}

/// Immutable presentation state, independent of canonical drawings and durable
/// Pencil checkpoints. A patch reuses prior entries by exact UTF8 ID; only
/// changed payloads visit the full JSON validator. Native markers never grant
/// reuse. The legacy full-scene path remains available before epoch negotiation.
@MainActor
final class NativePDFEditorScene {
    private struct Entry {
        let object: [String: Any]
        let row: NativePDFDrawingSnapshotStore.Row?
        let token: NativePDFCommittedVisualToken
    }
    private let entries: [Entry]
    let selection: [String: Double]?
    let resizable: Bool
    let textHandles: Bool
    var visualTokens: [NativePDFCommittedVisualToken] { entries.map(\.token) }
    var identityObjects: [[String: Any]] { entries.map(\.object) }

    private init(entries: [Entry], request: [String: Any]) {
        self.entries = entries
        selection = request["selection"] as? [String: Double]
        resizable = request["resizable"] as? Bool ?? false
        textHandles = request["textHandles"] as? Bool ?? false
    }

    convenience init(request: [String: Any], page: Int, pageCount: Int,
                     store: NativePDFDrawingSnapshotStore, previous: NativePDFEditorScene?) {
        let prior = previous?.entriesByID() ?? [:]
        let entries = (request["objects"] as? [[String: Any]] ?? []).map { source in
            Self.makeEntry(source, page: page, pageCount: pageCount, store: store,
                previous: (source["id"] as? String).flatMap { prior[Data($0.utf8)] })
        }
        self.init(entries: entries, request: request)
    }

    convenience init(patch: [String: Any], request: [String: Any], page: Int, pageCount: Int,
                     store: NativePDFDrawingSnapshotStore, previous: NativePDFEditorScene?) throws {
        guard let rawReset = patch["reset"] as? NSNumber, CFGetTypeID(rawReset) == CFBooleanGetTypeID(),
              let order = patch["order"] as? [String], order.count <= 100_000,
              order.allSatisfy({ !$0.isEmpty }), let updates = patch["upserts"] as? [[String: Any]]
        else { throw Self.invalid() }
        let keys = order.map { Data($0.utf8) }, retained = Set(keys)
        guard retained.count == order.count else { throw Self.invalid() }
        let prior = previous?.entriesByID() ?? [:]
        var next = rawReset.boolValue ? [:] : prior
        var seen: Set<Data> = []
        // Validate shape/order references before touching row preparation.
        for source in updates {
            guard let id = source["id"] as? String, !id.isEmpty else { throw Self.invalid() }
            let key = Data(id.utf8)
            guard retained.contains(key), seen.insert(key).inserted else { throw Self.invalid() }
        }
        guard keys.allSatisfy({ seen.contains($0) || next[$0] != nil }) else { throw Self.invalid() }
        for source in updates {
            let key = Data((source["id"] as! String).utf8)
            next[key] = Self.makeEntry(source, page: page, pageCount: pageCount, store: store, previous: prior[key])
        }
        self.init(entries: keys.compactMap { next[$0] }, request: request)
    }

    private func entriesByID() -> [Data: Entry] {
        var result: [Data: Entry] = [:], duplicates: Set<Data> = []
        for entry in entries {
            guard let id = entry.object["id"] as? String, !id.isEmpty else { continue }
            let key = Data(id.utf8)
            if result.updateValue(entry, forKey: key) != nil { duplicates.insert(key) }
        }
        for key in duplicates { result.removeValue(forKey: key) }
        return result
    }

    private static func makeEntry(_ source: [String: Any], page: Int, pageCount: Int,
                                  store: NativePDFDrawingSnapshotStore, previous: Entry?) -> Entry {
        var clean = source
        clean.removeValue(forKey: "_nativeInk"); clean.removeValue(forKey: "_nativeVisualToken")
        var seed = clean
        let suppliedPage = seed["page"] != nil
        if !suppliedPage { seed["page"] = page }
        let old = previous?.row ?? (seed["id"] as? String).flatMap { store.row(id: $0) }
        let row = try? store.makeRow(seed, pageCount: pageCount, previous: old)
        let frozen: [String: Any]
        if let row {
            var display = row.object
            if !suppliedPage { display.removeValue(forKey: "page") }
            frozen = display
        } else {
            // Preserve individually unsupported preview schemas and detach all
            // mutable containers, without rejecting their valid scene peers.
            frozen = (try? DesktopJSON.immutableCopy(clean)) as? [String: Any] ?? [:]
        }
        return Entry(object: frozen, row: row,
            token: row?.visualToken ?? NativePDFCommittedVisualToken(object: frozen))
    }

    func prepared(aspect: Double) -> [[String: Any]] {
        entries.map { entry in
            guard let row = entry.row else { return entry.object }
            var object = entry.object
            object["_nativeInk"] = row.prepared(aspect: aspect)["_nativeInk"]
            return object
        }
    }
    func releasePreparedInk() { entries.forEach { $0.row?.releasePreparedInk() } }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }
    static func invalid() -> NativePDFError {
        .invalid("PDF 개체 화면의 변경 순서를 확인할 수 없습니다. 전체 화면 자료를 다시 보내 주세요.")
    }
}
