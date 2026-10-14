import UIKit
import WebKit
import PDFKit
import CryptoKit

/// Platform backend for the original React PDF chrome. Native PDF scrolling
/// and ink share one coordinate system; only the outer viewport crosses WK.
/// This experimental body is opt-in until every desktop parity gate passes.
@MainActor
final class NativePDFHost {
    typealias Invoke = (String, [String: Any]) async throws -> Any
    var emit: (String, Any) -> Void = { _, _ in }
    var onDiagnostic: (String, String) -> Void = { _, _ in }
    private let root: URL
    private let invoke: Invoke
    private let journal: NativePDFJournal
    private weak var container: UIView?
    private weak var shell: WKWebView?
    private var documents: [String: NativePDFDocument] = [:]
    private var openGenerations: [String: String] = [:]
    private var rectangles: [String: CGRect] = [:]
    private var holes: [String: [CGRect]] = [:]
    private var memoryObserver: NSObjectProtocol?
    private var isEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "bandal.nativePDF.enabled")
        #else
        false
        #endif
    }

    init(root: URL, invoke: @escaping Invoke) throws {
        self.root = root; self.invoke = invoke; journal = try NativePDFJournal(root: root)
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.documents.values.forEach { $0.releaseCaches() } }
        }
    }
    func attach(to container: UIView, shell: WKWebView) { self.container = container; self.shell = shell }
    func canHandle(_ channel: String) -> Bool { channel.hasPrefix("pdfNative:") }
    func handle(_ channel: String, request: [String: Any]) async throws -> Any {
        if channel == "pdfNative:capabilities" {
            #if DEBUG
            let development = true
            #else
            let development = false
            #endif
            return ["enabled": isEnabled,
                    "development": development, "version": 1, "inkVersion": 3, "renderer": "PDFKit/UIKit/Metal"]
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
            if let current = documents[identifier], current.generation == generation {
                guard current.courseID == course, current.relativePath == path else { throw NativePDFError.invalid("PDF 표면 식별자가 변경되었습니다.") }
                return current.state
            }
            openGenerations[identifier] = generation
            guard let source = try await invoke("nativeMaterial:path", ["courseId": course, "relPath": path]) as? String else { throw NativePDFError.invalid("PDF 자료를 찾지 못했습니다.") }
            let root = root
            let snapshot = try await Task.detached(priority: .userInitiated) { try Self.snapshot(path: source, root: root) }.value
            guard openGenerations[identifier] == generation else { throw CancellationError() }
            // Canonical drawings remain bound to the first verified PDF
            // revision across close/reopen, rename and sync. Never relabel old
            // ink with the hash of a replacement file at the same path.
            guard let binding = try await invoke("nativePDF:binding", ["courseId": course, "relPath": path, "documentRevision": snapshot.revision]) as? [String: Any],
                  binding["documentRevision"] as? String == snapshot.revision,
                  let materialID = binding["materialID"] as? String, !materialID.isEmpty else {
                throw NativePDFError.invalid("PDF 원본과 필기 연결을 확인하지 못했습니다. 자료를 보존한 채 다시 열어 주세요.")
            }
            guard openGenerations[identifier] == generation else { throw CancellationError() }
            guard let pdf = PDFDocument(url: snapshot.url), !pdf.isLocked, pdf.pageCount > 0 else { throw NativePDFError.invalid("PDF를 열지 못했습니다. 잠금 또는 파일 형식을 확인해 주세요.") }
            // Another split can have the same document open. Finish its
            // measured checkpoints before sharing/replaying a receipt payload.
            for existing in documents.values where existing.courseID == course && existing.relativePath == path { try existing.flush() }
            let pending = try journal.pending(courseID: course, relativePath: path)
            guard pending.allSatisfy({ $0.documentRevision == snapshot.revision }) else {
                throw NativePDFError.invalid("PDF 원본이 바뀌어 이전 문서의 미전송 필기를 보존했습니다. 원본 복구 후 다시 열어 주세요.")
            }
            // A process ending during estimated-property correction recovers
            // the last durable measured checkpoint as its final payload.
            for record in pending where record.provisional == true { try journal.append(record.input, documentRevision: record.documentRevision) }
            try documents[identifier]?.close()
            documents.removeValue(forKey: identifier)
            var testingDirectPencil = false
            #if DEBUG
            // Exercise UIKit's real recognizer dispatch with XCTest fingers in
            // a separate fixture library. Never enable it in the user's data.
            testingDirectPencil = root.lastPathComponent == "BandalDesktop-UI-Tests" &&
                ProcessInfo.processInfo.arguments.contains("--ui-testing") &&
                ProcessInfo.processInfo.arguments.contains("--native-pencil-dispatch-fixture")
            #endif
            let item = NativePDFDocument(id: identifier, generation: generation, courseID: course, relativePath: path,
                                         revision: snapshot.revision, document: pdf, testingDirectPencil: testingDirectPencil)
            item.onDiagnostic = { [weak self] event, code in self?.onDiagnostic(event, code) }
            item.onEvent = { [weak self] type, body in
                self?.emit("pdfNative:event", ["surfaceId": identifier, "generation": generation, "type": type, "payload": body])
            }
            item.onStroke = { [weak self, weak item] page, stroke in
                guard let self, let item else { throw CancellationError() }
                let input = NativePDFStrokeInput(courseId: course, relPath: path, page: page, kind: stroke.kind,
                                                data: NativePDFStrokeData(points: stroke.points), style: stroke.style,
                                                clientMutationId: stroke.mutationID, documentRevision: item.revision)
                try self.journal.append(input, documentRevision: item.revision)
                item.recordJournal(stroke.kind, phase: "commit")
                item.addPending(input)
                item.refreshOverlays()
                item.onEvent("stroke", try Self.json(input))
            }
            item.onCheckpoint = { [weak self, weak item] page, stroke in
                guard let self, let item else { throw CancellationError() }
                let input = NativePDFStrokeInput(courseId: course, relPath: path, page: page, kind: stroke.kind,
                    data: NativePDFStrokeData(points: stroke.points), style: stroke.style,
                    clientMutationId: stroke.mutationID, documentRevision: item.revision)
                try self.journal.checkpoint(input, documentRevision: item.revision)
                item.recordJournal(stroke.kind, phase: "checkpoint")
                item.addPending(input); item.refreshOverlays()
            }
            item.resolveImage = { [weak self] object in
                guard let self else { throw CancellationError() }
                return try await self.resolveImage(object: object, courseID: course)
            }
            item.pending = Dictionary(uniqueKeysWithValues: pending.map { ($0.input.clientMutationId, $0.input) })
            item.pendingOrder = pending.map { $0.input.clientMutationId }
            documents[identifier] = item; container?.addSubview(item.pdfView)
            item.pdfView.isHidden = true
            return item.state.merging(["pending": try pending.map { try Self.json($0.input) }]) { _, new in new }
        }
        if channel == "pdfNative:close" {
            if openGenerations[identifier] == generation { openGenerations.removeValue(forKey: identifier) }
            if let item = documents[identifier], item.generation == generation {
                try item.close(); documents.removeValue(forKey: identifier); rectangles.removeValue(forKey: identifier); holes.removeValue(forKey: identifier)
            }
            return [:]
        }
        guard let item = documents[identifier], item.generation == generation else { throw NativePDFError.invalid("PDF 표면이 닫혔거나 변경되었습니다.") }
        switch channel {
        case "pdfNative:layout":
            try item.setVisible(request["visible"] as? Bool ?? false)
            if let value = request["rect"] as? [String: Double], let x = value["x"], let y = value["y"], let w = value["width"], let h = value["height"], [x,y,w,h].allSatisfy(\.isFinite), w > 0, h > 0 {
                rectangles[identifier] = CGRect(x: x, y: y, width: w, height: h)
            } else { rectangles.removeValue(forKey: identifier); item.pdfView.isHidden = true }
            holes[identifier] = (request["holes"] as? [[String: Double]] ?? []).prefix(32).compactMap { value in
                guard let x = value["x"], let y = value["y"], let width = value["width"], let height = value["height"], [x,y,width,height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
                return CGRect(x: x, y: y, width: width, height: height)
            }
            layout(); return [:]
        case "pdfNative:snapshot":
            item.snapshot(request); return [:]
        case "pdfNative:objectScene":
            item.objectScene(request); return [:]
        case "pdfNative:navigate":
            try item.navigate(request); return item.state
        case "pdfNative:ack":
            let mutation = try Self.string(request, "clientMutationId")
            // Renderer acks only after its canonical create/receipt resolves.
            let drawingID = try Self.string(request, "drawingId")
            try journal.acknowledge(mutation, courseID: item.courseID, relativePath: item.relativePath)
            item.acknowledgePreview(mutationID: mutation, drawingID: drawingID); return [:]
        case "pdfNative:mutationStatus":
            guard let input = request["input"] as? [String: Any], input["courseId"] as? String == item.courseID,
                  input["relPath"] as? String == item.relativePath, input["documentRevision"] as? String == item.revision else {
                throw NativePDFError.invalid("다른 문서의 필기 저장 상태를 확인할 수 없습니다.")
            }
            let result = try await invoke("nativePDF:mutationStatus", input)
            if let receipt = result as? [String: Any], receipt["status"] as? String == "deleted", let mutation = input["clientMutationId"] as? String {
                item.pending.removeValue(forKey: mutation); item.refreshOverlays()
            }
            return result
        case "pdfNative:diagnostics": return item.diagnostics
        case "pdfNative:pageGeometry":
            guard let page = request["page"] as? Int else { throw NativePDFError.invalid("편집할 PDF 페이지를 확인해 주세요.") }
            return try item.pageGeometry(page)
        case "pdfNative:flush":
            try item.flush(); return ["pending": try journal.pending(courseID: item.courseID, relativePath: item.relativePath).map { try Self.json($0.input) }]
        default: throw NativePDFError.invalid("알 수 없는 PDF 작업입니다.")
        }
    }
    func layout() {
        guard let container, let shell else { return }
        for (identifier, item) in documents where !item.pdfView.isHidden {
            guard let rect = rectangles[identifier] else { continue }
            let factor = shell.scrollView.zoomScale
            let source = CGRect(x: rect.minX * factor, y: rect.minY * factor, width: rect.width * factor, height: rect.height * factor)
            let unclipped = shell.convert(source, to: container)
            let frame = unclipped.intersection(shell.convert(shell.bounds, to: container)).intersection(container.bounds)
            guard !frame.isNull, !frame.isEmpty else { item.pdfView.isHidden = true; continue }
            let frameChanged = item.pdfView.frame != frame
            if frameChanged { item.pdfView.frame = frame }
            container.bringSubviewToFront(item.pdfView)
            item.pdfView.excludedRects = (holes[identifier] ?? []).map { CGRect(x: $0.minX * factor + unclipped.minX-frame.minX, y: $0.minY * factor + unclipped.minY-frame.minY, width: $0.width * factor, height: $0.height * factor) }
            if frameChanged { item.prepareNavigation() }
        }
    }
    func flush() { for item in documents.values { do { try item.flush() } catch { item.onEvent("error", ["message": error.localizedDescription]) } } }
    func closeAll() {
        for (id, item) in documents {
            do { try item.close(); documents.removeValue(forKey: id); openGenerations.removeValue(forKey: id); rectangles.removeValue(forKey: id); holes.removeValue(forKey: id) }
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
    static func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw NativePDFError.invalid("PDF 입력을 변환하지 못했습니다.") }; return result
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
    let pdfView = NativePDFApertureView()
    var onStroke: ((Int, NativePDFCompletedStroke) throws -> Void)?
    var onCheckpoint: ((Int, NativePDFCompletedStroke) throws -> Void)?
    var onEvent: (String, [String: Any]) -> Void = { _, _ in }
    var onDiagnostic: (String, String) -> Void = { _, _ in }
    private var journalCounts: [String: Int] = [:]
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
    private var objects: [[String: Any]] = [], highlights: [[String: Any]] = []
    private var objectScenes: [Int: [String: Any]] = [:]
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
    private var nativePinch: UIPinchGestureRecognizer!
    private let pencilGesture: NativePDFPencilGestureRecognizer
    private var pinchStartScale = 1.0
    private var pinchAnchor: (page: PDFPage, point: CGPoint)?
    private var selectedTextRects: [Int: [[String: Double]]] = [:]
    private let pageActions = UIButton(type: .system)
    private var pinchEvents = 0, scaleChanges = 0, navigateCommands = 0
    private var lastPinchState = 0, lastPinchScale = 1.0, lastRequestedZoom = 1.0
    private var submissionP95 = 0.0, submissionSamples = 0
    var diagnostics: [String: Any] {
        ["page": state["page"] ?? 1, "zoom": pdfView.scaleFactor/max(fit,0.001), "fit": fit,
         "pinchEvents": pinchEvents, "pinchState": lastPinchState, "pinchScale": lastPinchScale,
         "scaleChanges": scaleChanges, "navigateCommands": navigateCommands, "requestedZoom": lastRequestedZoom,
         "scrollZoom": scrollView?.zoomScale ?? 0, "scrollMinZoom": scrollView?.minimumZoomScale ?? 0, "scrollMaxZoom": scrollView?.maximumZoomScale ?? 0, "autoScales": pdfView.autoScales,
         "receiveToMetalSubmitP95MS": submissionP95, "timingSamples": submissionSamples,
         "retainedPages": overlays.count, "suspended": suspended,
         "tool": tool.name, "loading": loading, "markup": pdfView.isInMarkupMode,
         "inputs": overlays.values.map(\.inputDiagnostics), "journalCounts": journalCounts]
    }
    private var lastViewport = ""
    private var emission: Task<Void, Never>?
    var state: [String: Any] {
        let page = pdfView.currentPage.map { document.index(for: $0) + 1 } ?? 1
        return ["page": page, "numPages": document.pageCount, "zoom": pdfView.scaleFactor / max(fit, 0.001), "revision": revision,
                "pageSizes": (0..<document.pageCount).compactMap { index -> [String: Any]? in
                    guard let page = document.page(at: index) else { return nil }
                    let crop = page.bounds(for: .cropBox), rotated = abs(page.rotation) % 180 != 0
                    return ["page": index + 1, "width": rotated ? crop.height : crop.width, "height": rotated ? crop.width : crop.height]
                }]
    }
    init(id: String, generation: String, courseID: String, relativePath: String, revision: String, document: PDFDocument, testingDirectPencil: Bool = false) {
        self.id = id; self.generation = generation; self.courseID = courseID; self.relativePath = relativePath; self.revision = revision; self.document = document
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
        nativePinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchChanged(_:)))
        nativePinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pdfView.addGestureRecognizer(nativePinch)
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
            UIAction(title: "화이트보드로 보내기", image: UIImage(systemName: "rectangle.on.rectangle")) { [weak self] _ in self?.sendPageAction("whiteboard") },
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
            let zoom = layoutSize == .zero ? 1 : pdfView.scaleFactor / max(fit, 0.001)
            fit = max(pdfView.scaleFactorForSizeToFit, 0.001)
            // Leaving autoScales enabled lets incidental host layout reset a
            // user's pinch to the fit scale while React mirrors the viewport.
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
                // PDFKit's scroll recognizer can snap back at gesture end in
                // a page-overlay host. One public recognizer owns the PDF and
                // its overlays together, including the point under the fingers.
                scroll.pinchGestureRecognizer?.isEnabled = false
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
        let centroid = pinch.location(in: pdfView)
        if pinch.state == .began {
            do { try flush() } catch { onEvent("error", ["message": error.localizedDescription]); pinch.isEnabled = false; pinch.isEnabled = true; return }
            pinchStartScale = pdfView.scaleFactor
            if let page = pdfView.page(for: centroid, nearest: true) { pinchAnchor = (page, pdfView.convert(centroid, to: page)) }
        }
        if [.began, .changed, .ended].contains(pinch.state) {
            pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, pinchStartScale * pinch.scale))
            pdfView.layoutIfNeeded()
            if let anchor = pinchAnchor, let scroll = scrollView {
                let relocated = pdfView.convert(anchor.point, from: anchor.page)
                let proposed = CGPoint(x: scroll.contentOffset.x + relocated.x - centroid.x, y: scroll.contentOffset.y + relocated.y - centroid.y)
                let inset = scroll.adjustedContentInset
                scroll.setContentOffset(CGPoint(
                    x: max(-inset.left, min(max(-inset.left, scroll.contentSize.width-scroll.bounds.width+inset.right), proposed.x)),
                    y: max(-inset.top, min(max(-inset.top, scroll.contentSize.height-scroll.bounds.height+inset.bottom), proposed.y))), animated: false)
            }
            viewportChanged()
        }
        if [.ended, .cancelled, .failed].contains(pinch.state) { pinchAnchor = nil }
        updateAccessibilityState()
    }
    func setVisible(_ visible: Bool) throws {
        if !visible {
            pdfView.isHidden = true
            if !suspended {
                try flush()
                var viewport = state
                if let page = pdfView.currentPage {
                    let center = pdfView.convert(CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), to: page)
                    viewport["progress"] = NativePDFPageCoordinates(page: page).displayNormalized(center).y
                    viewport["horizontalProgress"] = NativePDFPageCoordinates(page: page).displayNormalized(center).x
                }
                suspendedViewport = viewport; suspended = true
                viewportObservation = nil; pinchAnchor = nil
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
        imageTasks.values.forEach { $0.cancel() }; imageTasks.removeAll(); images.removeAllObjects()
        if !suspended { refreshOverlays() }
    }
    func snapshot(_ request: [String: Any]) {
        objects = request["drawings"] as? [[String: Any]] ?? []
        highlights = request["annotations"] as? [[String: Any]] ?? []
        loading = request["loading"] as? Bool ?? true
        workspaceActive = request["active"] as? Bool ?? false
        if let value = request["tool"] as? [String: Any], let name = value["name"] as? String,
           let data = try? JSONSerialization.data(withJSONObject: value["style"] as? [String: Any] ?? [:]),
           let style = try? JSONDecoder().decode(NativePDFInkStyle.self, from: data), style.isValid {
            tool = .init(name: name, style: style)
            if ["pen", "highlighter"].contains(name) { objectScenes.removeAll() }
        }
        // PDFKit read mode may skip page overlay interaction. Markup enables
        // the public drawing path; selection mode retains finger text lookup.
        // Pencil select still routes explicitly through our provider's views.
        let markup = tool.name != "select"
        if pdfView.isInMarkupMode != markup {
            pdfView.isInMarkupMode = markup
            onDiagnostic("nativePDF.mode", "\(tool.name).markup.\(markup ? "on" : "off")")
        }
        refreshOverlays()
        pageActions.isHidden = tool.name != "select" || loading
        updateAccessibilityState()
    }
    func objectScene(_ request: [String: Any]) {
        guard !["pen", "highlighter"].contains(tool.name), let page = request["page"] as? Int,
              (1...document.pageCount).contains(page), request["objects"] is [[String: Any]] else { return }
        objectScenes[page] = request
        refreshOverlays()
    }
    func acknowledgePreview(mutationID: String, drawingID: String) {
        acknowledgedRows[mutationID] = drawingID
        refreshOverlays()
        publishPendingCount()
    }
    func addPending(_ input: NativePDFStrokeInput) {
        if pending[input.clientMutationId] == nil { pendingOrder.append(input.clientMutationId) }
        pending[input.clientMutationId] = input
        publishPendingCount()
    }
    private func publishPendingCount() {
        onEvent("pending", ["count": pending.keys.filter { acknowledgedRows[$0] == nil }.count])
    }
    func refreshOverlays() {
        for (number, overlay) in overlays {
            overlay.tool = tool; overlay.isLoading = loading
            overlay.highlights = highlights.filter { $0["page"] as? Int == number }
            overlay.selectedTextRects = selectedTextRects[number] ?? []
            let scene = objectScenes[number]
            var drawings = scene?["objects"] as? [[String: Any]] ?? objects.filter { $0["page"] as? Int == number }
            overlay.selectionBox = scene?["selection"] as? [String: Double]
            overlay.selectionResizable = scene?["resizable"] as? Bool ?? false
            overlay.selectionTextHandles = scene?["textHandles"] as? Bool ?? false
            for input in pendingOrder.compactMap({ pending[$0] }) where input.page == number {
                let acknowledged = acknowledgedRows[input.clientMutationId]
                if drawings.contains(where: { $0["clientMutationId"] as? String == input.clientMutationId || (acknowledged != nil && $0["id"] as? String == acknowledged) }) {
                    if acknowledgedRows[input.clientMutationId] != nil { pending.removeValue(forKey: input.clientMutationId); acknowledgedRows.removeValue(forKey: input.clientMutationId) }
                    continue
                }
                guard let page = document.page(at: number - 1), var object = try? NativePDFHost.json(input) else { continue }
                let coordinates = NativePDFPageCoordinates(page: page)
                let polygons = input.data.inkVersion == 3
                    ? NativePDFInkGeometryV3.polygons(points: input.data.points, width: input.style.width, aspect: coordinates.height / coordinates.width, highlighter: input.kind == "highlighter")
                    : NativePDFInkGeometry.polygons(points: input.data.points, width: input.style.width, aspect: coordinates.height / coordinates.width, highlighter: input.kind == "highlighter")
                object["nativePath"] = polygons.map { polygon in
                    polygon.enumerated().map { "\($0.offset == 0 ? "M" : "L") \($0.element.x) \($0.element.y)" }.joined(separator: " ") + " Z"
                }.joined(separator: " ")
                drawings.append(object)
            }
            overlay.objects = drawings
            for object in drawings where ["image", "clip"].contains(object["kind"] as? String ?? "") {
                let key = Self.imageKey(object)
                guard images.object(forKey: key as NSString) == nil, imageTasks[key] == nil, !imageFailures.contains(key), let resolveImage else { continue }
                imageTasks[key] = Task { @MainActor [weak self] in
                    do {
                        let image = try await resolveImage(object)
                        guard let self, !Task.isCancelled else { return }
                        self.images.setObject(image, forKey: key as NSString, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
                        self.overlays.values.forEach { $0.invalidateBackdrop() }
                    } catch { if !Task.isCancelled { self?.imageFailures.insert(key); self?.onEvent("error", ["message": error.localizedDescription]) } }
                    self?.imageTasks.removeValue(forKey: key)
                }
            }
        }
        pendingOrder.removeAll { pending[$0] == nil }
    }
    private static func imageKey(_ object: [String: Any]) -> String {
        let value = object["data"] as? [String: Any] ?? [:]
        let source = value["image"] ?? value["clip"] ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: source, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func navigate(_ request: [String: Any]) throws {
        try flush(); navigating = true; defer { navigating = false }
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
        viewportChanged()
    }
    func pageGeometry(_ number: Int) throws -> [String: Double] {
        guard let page = document.page(at: number-1), !suspended else { throw NativePDFError.invalid("PDF 편집 페이지가 닫혔습니다.") }
        let rect = pdfView.convert(page.bounds(for: .cropBox), from: page)
        return ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
    private func viewportChanged() {
        overlays.values.forEach { $0.refreshViewport() }
        updateAccessibilityState()
        guard !navigating, !suspended else { return }
        emission?.cancel()
        emission = Task { @MainActor [weak self] in
            await Task.yield(); guard !Task.isCancelled, let self,
                let page = self.pdfView.page(for: CGPoint(x: self.pdfView.bounds.midX, y: self.pdfView.bounds.midY), nearest: true) else { return }
            var payload = self.state
            payload["page"] = self.document.index(for: page) + 1
            let coordinates = NativePDFPageCoordinates(page: page), center = self.pdfView.convert(CGPoint(x: self.pdfView.bounds.midX, y: self.pdfView.bounds.midY), to: page)
            payload["progress"] = min(1, max(0, coordinates.displayNormalized(center).y))
            payload["horizontalProgress"] = min(1, max(0, coordinates.displayNormalized(center).x))
            let signature = "\(payload["page"] ?? 0):\(payload["zoom"] ?? 0):\(payload["progress"] ?? 0):\(payload["horizontalProgress"] ?? 0)"
            guard signature != self.lastViewport else { return }
            self.lastViewport = signature; self.onEvent("viewport", payload)
        }
    }
    private func updateAccessibilityState() {
        let number = pdfView.currentPage.map { document.index(for: $0) + 1 } ?? 1
        pdfView.accessibilityValue = String(format: "page=%d zoom=%.4f scale=%.4f width=%.1f height=%.1f pinch=%d pinchScale=%.3f scaleChanges=%d navigation=%d requestedZoom=%.3f submitP95ms=%.2f samples=%d scrollZoom=%.3f scrollMin=%.3f scrollMax=%.3f autoScales=%d active=%d", number,
            pdfView.scaleFactor/max(fit,0.001), pdfView.scaleFactor, pdfView.bounds.width, pdfView.bounds.height,
            pinchEvents, lastPinchScale, scaleChanges, navigateCommands, lastRequestedZoom, submissionP95, submissionSamples,
            scrollView?.zoomScale ?? 0, scrollView?.minimumZoomScale ?? 0, scrollView?.maximumZoomScale ?? 0, pdfView.autoScales ? 1 : 0, workspaceActive ? 1 : 0)
        #if DEBUG
        pdfView.accessibilityValue = (pdfView.accessibilityValue ?? "") + " drawings=\(objects.count) pending=\(pending.count)"
        #endif
    }
    private func selectionChanged() {
        selectedTextRects.removeAll()
        defer { overlays.forEach { $0.value.selectedTextRects = selectedTextRects[$0.key] ?? [] } }
        guard let selection = pdfView.currentSelection, selection.pages.count == 1,
              let quote = selection.string, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = selection.pages.first else { return }
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
        onEvent("activate", [:])
        onEvent("bodyTap", [:])
        guard tool.name == "select" else { return }
        let location = gesture.location(in: pdfView)
        guard let page = pdfView.page(for: location, nearest: false) else { return }
        let number = document.index(for: page) + 1
        let point = NativePDFPageCoordinates(page: page).displayNormalized(pdfView.convert(location, to: page))
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
        overlay.onInteraction = { [weak self] tool, payload in self?.onEvent("interaction", payload.merging(["page": number, "tool": tool]) { _, new in new }) }
        overlay.onPointer = { [weak self] payload in self?.onEvent("pointer", payload.merging(["page": number]) { _, new in new }) }
        overlay.onInputOwnership = { [weak self] active in
            if active { self?.onEvent("activate", [:]) }
            self?.scrollView?.panGestureRecognizer.isEnabled = !active
            self?.nativePinch.isEnabled = !active
            self?.scrollView?.pinchGestureRecognizer?.isEnabled = false
        }
        overlay.onLayout = { [weak self, weak overlay, weak page] in
            guard let self, let overlay, let page, overlay.window != nil else { return }
            let coordinates = NativePDFPageCoordinates(page: page)
            let convert: (CGPoint) -> CGPoint = { coordinates.displayPhysical(self.pdfView.convert(overlay.convert($0, to: self.pdfView), to: page)) }
            let origin = convert(.zero), x = convert(CGPoint(x: 1, y: 0)), y = convert(CGPoint(x: 0, y: 1))
            overlay.mapper = InkCoordinateMapper(canvasToPDF: CGAffineTransform(a: x.x-origin.x, b: x.y-origin.y, c: y.x-origin.x, d: y.y-origin.y, tx: origin.x, ty: origin.y), geometry: coordinates.geometry)
        }
        overlays[number] = overlay; refreshOverlays(); return overlay
    }
    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) { overlayView.setNeedsLayout() }
    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? NativePDFInkSurface else { return }
        do { try overlay.flush(); overlays.removeValue(forKey: document.index(for: page) + 1) }
        catch { onEvent("error", ["message": error.localizedDescription]) }
    }
    func flush() throws { for overlay in overlays.values { try overlay.flush() } }
    private var scrollView: UIScrollView? {
        func find(_ view: UIView) -> UIScrollView? { if let scroll = view as? UIScrollView { return scroll }; return view.subviews.lazy.compactMap(find).first }
        return find(pdfView)
    }
    func close() throws {
        try flush(); emission?.cancel(); viewportObservation = nil
        observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
        imageTasks.values.forEach { $0.cancel() }; imageTasks.removeAll(); images.removeAllObjects()
        pdfView.removeFromSuperview(); pdfView.pageOverlayViewProvider = nil; pdfView.document = nil; overlays.removeAll()
    }
}
