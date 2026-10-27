import SwiftUI
import UIKit
import PDFKit
import Combine

struct NativeWhiteboardWorkspace: View {
    @StateObject private var model: NativeWhiteboardModel
    @ObservedObject private var annotation: NativeAnnotationCoordinator
    @Environment(\.nativeWorkspaceChromeMode) private var chromeMode
    @Environment(\.nativeWorkspaceTopInset) private var topInset
    @Environment(\.nativeWorkspaceControlInset) private var controlInset
    @Environment(\.nativeEditorVisible) private var editorVisible
    init(document: NativeDocumentReference, store: NativeWorkspaceStore) { _model = StateObject(wrappedValue: NativeWhiteboardModel(document: document, store: store)); _annotation = ObservedObject(wrappedValue: store.annotation) }
    var body: some View {
        VStack(spacing: 0) {
            if let request = annotation.request, request.documentID == model.document.id {
                HStack {
                    Text(annotation.error ?? "질문할 필기 영역을 드래그하세요").font(.callout)
                    Spacer()
                    Button { annotation.cancel() } label: {
                        Text("취소").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier("native-ai-annotation-cancel")
                }.padding(.horizontal, 12).background(.regularMaterial)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("native-ai-annotation-toolbar")
            } else {
            ViewThatFits(in: .horizontal) {
                HStack { tools; Spacer(); if chromeMode != .toolsHidden { navigation } }
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) { tools }.frame(height: 44)
                    if chromeMode != .toolsHidden { navigation }
                }
            }.padding(.horizontal, 8).padding(.trailing, controlInset).padding(.top, topInset).background(NativeDesktopTheme.surface)
            }
            NativeWhiteboardBody(model: model).accessibilityIdentifier("native-whiteboard-workspace")
                .nativeWorkspacePreviewSurface(id: model.document.id, capture: { try model.controller?.previewImage() })
                .overlay {
                    if let request = annotation.request, request.documentID == model.document.id {
                        NativeAnnotationRegionOverlay { bounds in
                            do {
                                guard let image = try model.controller?.annotationImage(bounds: bounds),
                                      let dataURL = NativeAssistantAttachment.dataURL(image) else { throw DesktopRuntimeError("필기 페이지 안에서 영역을 선택해 주세요.") }
                                annotation.complete(.init(title: model.document.title, imageDataURL: dataURL,
                                    courseID: model.document.courseID, relativePath: model.document.relativePath,
                                    page: model.page, revision: UUID().uuidString), requestID: request.id)
                            } catch { annotation.fail(error.localizedDescription, requestID: request.id) }
                        }
                    }
                }
            if let error = model.error {
                HStack { Text(error).font(.caption); Spacer(); Button("다시 저장") { model.retry() }.frame(minHeight: 44) }.padding(12).background(.bar)
            }
        }.onChange(of: editorVisible, initial: true) { _, visible in model.setVisible(visible) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in model.background() }
    }
    private var tools: some View {
        HStack(spacing: 4) {
            ForEach([("pen", "pencil.tip", "펜"), ("highlighter", "highlighter", "형광펜"), ("eraser", "eraser", "지우개")], id: \.0) { item in
                Button { model.chooseTool(item.0) } label: { Image(systemName: item.1).frame(width: 44, height: 44).foregroundStyle(model.tool == item.0 ? Color.white : .primary).background(model.tool == item.0 ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8)) }.accessibilityLabel(item.2).accessibilityIdentifier("native-whiteboard-tool-" + item.0)
            }
            Menu {
                ForEach(["ink", "blue", "red", "green", "orange", "yellow", "violet"], id: \.self) { value in Button(value) { model.chooseColor(value) } }
                Divider()
                Button("가늘게") { model.setWidth(0.002) }; Button("보통") { model.setWidth(0.004) }; Button("굵게") { model.setWidth(0.008) }
            } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }.accessibilityLabel("필기 스타일").accessibilityIdentifier("native-whiteboard-style").accessibilityValue("drawings=\(model.count) pending=\(model.pending)").accessibilityHint(model.pending > 0 ? "필기 저장 중" : "모든 필기 저장됨")
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.disabled(!model.canUndo).accessibilityLabel("되돌리기").accessibilityIdentifier("native-whiteboard-undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }.disabled(!model.canRedo).accessibilityLabel("다시 실행").accessibilityIdentifier("native-whiteboard-redo")
        }.buttonStyle(.borderless).disabled(model.loading || model.blocked || model.error != nil)
    }
    private var navigation: some View {
        HStack(spacing: 6) {
            Button { model.go(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.disabled(model.page <= 1).accessibilityLabel("이전 페이지")
            Text("\(model.page) / \(model.pageCount)").monospacedDigit()
            Button { model.go(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(model.page >= model.pageCount).accessibilityLabel("다음 페이지")
            Button { model.addPage() } label: { Image(systemName: "doc.badge.plus").frame(width: 44, height: 44) }.accessibilityLabel("보드 페이지 추가")
            Button { model.controller?.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }.accessibilityLabel("보드 맞춤")
        }.buttonStyle(.borderless).disabled(model.loading || model.blocked || model.error != nil)
    }
}

@MainActor
final class NativeWhiteboardModel: ObservableObject {
    @Published var tool = "pen"
    @Published var color = "ink"
    @Published var loading = true
    @Published var blocked = false
    @Published var error: String?
    @Published var page = 1
    @Published var pageCount = 1
    @Published var count = 0
    @Published var pending = 0
    @Published var canUndo = false
    @Published var canRedo = false
    let document: NativeDocumentReference, store: NativeWorkspaceStore
    fileprivate weak var controller: NativeWhiteboardController?
    private(set) var editorVisible = true
    private var session: NativeWhiteboardSession?
    private var writer: NativeWhiteboardPersistence? { session?.writer }
    private var opening: Task<Void, Error>?, registration: UUID?
    private var peerChanges: AnyCancellable?
    private var mediaTask: Task<Void, Never>?
    private var restoredView: NativeWhiteboardPanelState?
    private var operationTask: Task<Void, Error>?
    private var rows: [[String: Any]] = [], media: [String: UIImage] = [:], board: [String: Any] = [:]
    private var pageGeometries: [String: [String: Any]] = [:]
    private var width = 0.003, retired = false, closing = false, mutating = false, writesSuspended = false
    private var events: AnyCancellable?
    private var undoStack: [NativeWhiteboardHistoryEntry] = [], redoStack: [NativeWhiteboardHistoryEntry] = [], completed = Set<String>()
    private var strokePages: [String: Int] = [:]
    init(document: NativeDocumentReference, store: NativeWorkspaceStore) {
        self.document = document; self.store = store
        restoredView = store.panelViewStates.read(NativeWhiteboardPanelState.self, id: document.id, kind: "whiteboard")
        if let restoredView, restoredView.isValid { page = restoredView.page } else { restoredView = nil }
        events = store.events.sink { [weak self] in self?.receive($0) }
    }
    fileprivate func attach(_ controller: NativeWhiteboardController) {
        self.controller = controller
        controller.view.isUserInteractionEnabled = editorVisible
        start()
    }
    func start() {
        guard opening == nil else { return }
        registration = store.registerDocumentFlush(id: document.id, document: document,
            freeze: { [weak self] in self?.setMutating(true) },
            suspendWrites: { [weak self] in self?.writesSuspended = true },
            resume: { [weak self] in self?.writesSuspended = false; self?.setMutating(false) },
            retire: { [weak self] in self?.retire(invalidateShared: true) }) { [self] in try await flush() }
        let task = Task { @MainActor in
            await self.store.waitForExternalMutation()
            guard !self.retired, !Task.isCancelled else { return }
            let session = try self.store.whiteboardSessions.session(root: self.store.root, document: self.document) { [weak store = self.store] channel, input in
                guard let store else { throw NativePDFError.invalid("노트 저장 연결이 닫혔습니다.") }
                return try await store.invoke(channel, input)
            }
            self.session = session
            self.peerChanges = session.changes.sink { [weak self] in self?.applySharedSnapshot() }
            try await session.open(); self.applySharedSnapshot(); self.loading = false; self.refresh()
            if let view = self.restoredView { self.controller?.restoreViewport(view); self.restoredView = nil }
        }
        opening = task
        Task { do { try await task.value } catch { fail(error) } }
    }
    private var identity: [String: Any] { ["courseId": document.courseID, "boardId": document.relativePath] }
    private func reload() async throws { try await session?.reload(); applySharedSnapshot() }
    private func applySharedSnapshot() {
        guard let session, !retired else { return }
        board = session.board; rows = session.rows; pageGeometries = session.pageGeometries
        if !board.isEmpty { pageCount = board["pageCount"] as? Int ?? 1; page = min(page, pageCount) }
        refresh()
        mediaTask?.cancel()
        mediaTask = Task { [weak self] in await self?.loadMedia(); self?.refresh() }
    }
    private func loadMedia() async {
        for row in rows where ["image", "clip"].contains(row["kind"] as? String ?? "") {
            guard !retired, !Task.isCancelled else { return }
            guard let id = row["id"] as? String, media[id] == nil, let data = row["data"] as? [String: Any], let kind = row["kind"] as? String, let source = data[kind] as? [String: Any], let path = source["relPath"] as? String else { continue }
            if let local = try? await store.invokePrivate("nativeMaterial:path", ["courseId": document.courseID, "relPath": path]) as? String {
                guard !retired, !Task.isCancelled else { return }
                if kind == "image" { media[id] = UIImage(contentsOfFile: local) }
                else if let document = PDFDocument(url: URL(fileURLWithPath: local)), let page = document.page(at: (source["page"] as? Int ?? 1) - 1) {
                    var image = page.thumbnail(of: CGSize(width: 1000, height: 1400), for: .cropBox)
                    if let crop = source["crop"] as? [String: Double], let pixels = image.cgImage,
                       let clipped = pixels.cropping(to: CGRect(x: (crop["x"] ?? 0) * Double(pixels.width), y: (crop["y"] ?? 0) * Double(pixels.height), width: (crop["width"] ?? 1) * Double(pixels.width), height: (crop["height"] ?? 1) * Double(pixels.height))) { image = UIImage(cgImage: clipped) }
                    media[id] = image
                }
            }
        }
    }
    private func visibleRows() -> [[String: Any]] { session?.visibleRows ?? rows }
    private func refresh() {
        let geometry = pageGeometries[String(page)] ?? [:]
        let rotated = (geometry["rotation"] as? Int ?? 0) % 180 != 0
        let width = (geometry["width"] as? NSNumber)?.doubleValue ?? 595.28, height = (geometry["height"] as? NSNumber)?.doubleValue ?? 841.89
        let size = CGSize(width: rotated ? height : width, height: rotated ? width : height)
        pending = writer?.pendingCount ?? 0; count = visibleRows().count
        canUndo = !undoStack.isEmpty && pending == 0; canRedo = !redoStack.isEmpty && pending == 0
        var values = visibleRows().filter { ($0["page"] as? NSNumber)?.intValue == page }
        values = values.map { row in
            var row = row
            if ["ink", "highlighter"].contains(row["kind"] as? String ?? ""), (row["data"] as? [String: Any])?["inkVersion"] == nil { row["nativePath"] = try? NativePDFLegacyInk.path(row, aspect: size.height / size.width) }
            return row
        }
        controller?.configure(rows: values, images: media, size: size, tool: tool, color: color, width: tool == "highlighter" ? max(0.014, self.width * 4) : self.width,
            loading: loading || blocked || error != nil || retired || closing || !editorVisible, background: board["background"] as? String ?? "grid", dark: board["surface"] as? String == "dark")
    }
    func setVisible(_ visible: Bool) {
        guard editorVisible != visible else { return }
        if !visible { do { try controller?.surface.flush() } catch { fail(error) } }
        editorVisible = visible
        controller?.view.isUserInteractionEnabled = visible
        refresh()
        if !visible { Task { do { try await flush() } catch { fail(error) } } }
    }
    func stroke(_ stroke: NativePDFCompletedStroke, provisional: Bool) throws {
        guard let session, !retired else { throw NativePDFError.invalid("노트 저장 연결이 닫혔습니다.") }
        let capturedPage = strokePages[stroke.mutationID] ?? page
        strokePages[stroke.mutationID] = capturedPage
        var canonicalStyle = stroke.style
        if canonicalStyle.color == "canvasLightInk" { canonicalStyle.color = "ink" }
        let points = try DesktopJSON.decode(JSONEncoder().encode(stroke.points)), style = try DesktopJSON.decode(JSONEncoder().encode(canonicalStyle))
        let shape: [String: Any] = ["kind": stroke.kind, "data": ["inkVersion": stroke.inkVersion, "points": points], "style": style]
        try session.enqueue(id: stroke.mutationID, commands: [["channel": "canvas:putShape", "request": ["id": stroke.mutationID, "page": capturedPage, "shape": shape]]])
        if !provisional {
            let commands: [[String: Any]] = [["channel": "canvas:removeShapes", "request": ["ids": [stroke.mutationID]]]]
            let entry = NativeWhiteboardHistoryEntry(commands: commands, rows: visibleRows())
            if completed.insert(stroke.mutationID).inserted { undoStack.append(entry); redoStack.removeAll() }
            else if let index = undoStack.lastIndex(where: { $0.expected.keys.contains(stroke.mutationID) }) { undoStack[index] = entry }
        }
        store.markDocumentChanged(); refresh(); drain()
    }
    func erase(_ targets: [NativePDFEraseTarget]) throws {
        guard let session, !retired else { throw NativePDFError.invalid("노트 저장 연결이 닫혔습니다.") }
        let ids = Set(targets.compactMap { $0.drawingID ?? $0.mutationID }), removed = visibleRows().filter { ids.contains($0["id"] as? String ?? "") }
        guard !ids.isEmpty else { return }
        try session.enqueue(commands: [["channel": "canvas:removeShapes", "request": ["ids": ids.sorted()]]])
        undoStack.append(NativeWhiteboardHistoryEntry(commands: removed.map(restore), rows: visibleRows())); redoStack.removeAll(); store.markDocumentChanged(); refresh(); drain()
    }
    private func restore(_ row: [String: Any]) -> [String: Any] { ["channel": "canvas:putShape", "request": ["id": row["id"]!, "page": row["page"] ?? 1, "restore": true, "shape": ["kind": row["kind"]!, "data": row["data"]!, "style": row["style"]!]]] }
    private func drain() { guard error == nil else { return }; Task { do { try await session?.drain(); refresh() } catch { fail(error) } } }
    func chooseTool(_ name: String) { do { try controller?.surface.flush(); tool = name; if name == "highlighter", color == "ink" { color = "yellow" }; refresh() } catch { fail(error) } }
    func chooseColor(_ name: String) { color = name; refresh() }
    func setWidth(_ value: Double) { width = value; refresh() }
    func undo() { history(undo: true) }; func redo() { history(undo: false) }
    private func history(undo: Bool) {
        guard editorVisible, !blocked, error == nil, let entry = undo ? undoStack.last : redoStack.last else { return }
        perform { [self] in
                guard entry.matches(visibleRows()) else {
                    if undo { undoStack.removeLast() } else { redoStack.removeLast() }
                    store.errorMessage = "다른 윈도우에서 변경한 필기는 되돌리지 않았어요."
                    return
                }
                let commands = entry.commands
                var inverse: [[String: Any]] = []
                for command in commands {
                    let request = command["request"] as! [String: Any]
                    if command["channel"] as? String == "canvas:removeShapes", let ids = request["ids"] as? [String] { inverse += visibleRows().filter { ids.contains($0["id"] as? String ?? "") }.map(restore) }
                    else if let id = request["id"] as? String { inverse.append(["channel": "canvas:removeShapes", "request": ["ids": [id]]]) }
                }
                try self.session?.enqueue(commands: commands); self.store.markDocumentChanged()
                let inverseEntry = NativeWhiteboardHistoryEntry(commands: inverse, rows: visibleRows())
                if undo { undoStack.removeLast(); redoStack.append(inverseEntry) } else { redoStack.removeLast(); undoStack.append(inverseEntry) }
                try await self.session?.drain()
        }
    }
    func go(_ delta: Int) {
        perform { self.page = min(self.pageCount, max(1, self.page + delta)); self.controller?.fit() }
    }
    func addPage() {
        perform { try await self.session?.addPage(); self.applySharedSnapshot(); self.page = self.pageCount; self.controller?.fit() }
    }
    func flush() async throws {
        if let operationTask { try await operationTask.value }
        try await flushInput()
    }
    private func flushInput() async throws {
        if writesSuspended { await store.waitForExternalMutation() }
        guard !retired else { return }
        if let opening { do { try await opening.value } catch { if writer?.pendingCount == 0 || writer == nil { return }; throw error } }
        guard !retired else { return }; try controller?.surface.flush(); try await session?.drain(); try saveViewState(); refresh()
    }
    private func perform(_ body: @escaping @MainActor () async throws -> Void) {
        guard !blocked, operationTask == nil, !retired else { return }
        blocked = true; store.markDocumentChanged(); refresh()
        let task = Task { @MainActor in
            defer { self.operationTask = nil }
            try await self.flushInput(); try await body()
        }
        operationTask = task
        Task { do { try await task.value; blocked = mutating || closing; refresh() } catch { blocked = mutating || closing; fail(error) } }
    }
    func close() async {
        guard !closing, !retired else { return }; closing = true; blocked = true; refresh()
        do { try await flush(); retire() } catch { closing = false; fail(error) }
    }
    func retry() {
        Task { do {
            await store.waitForExternalMutation(); guard !retired else { return }
            try await session?.drain(); try await reload(); opening = nil; error = nil; loading = false; blocked = mutating || closing; refresh()
        } catch { fail(error) } }
    }
    func background() {
        let token = UIApplication.shared.beginBackgroundTask(withName: "Save whiteboard")
        Task { defer { if token != .invalid { UIApplication.shared.endBackgroundTask(token) } }; do { try await flush() } catch { fail(error) } }
    }
    func fail(_ failure: Error) { error = failure.localizedDescription; loading = false; refresh() }
    private func setMutating(_ value: Bool) { mutating = value; blocked = value || closing || operationTask != nil; refresh() }
    private func retire(invalidateShared: Bool = false) { if invalidateShared { session?.retire() }; peerChanges = nil; mediaTask?.cancel(); retired = true; writesSuspended = false; blocked = true; refresh(); if let registration { store.unregisterDocumentFlush(registration); self.registration = nil } }
    private func saveViewState() throws {
        guard let state = controller?.viewportState(page: page) else { return }
        try store.panelViewStates.write(state, id: document.id, kind: "whiteboard")
    }
    private func receive(_ event: NativeWorkspaceEvent) {
        if event.channel == "canvas:changed", let value = event.payload as? [String: Any], value["courseId"] as? String == document.courseID, value["boardId"] as? String == document.relativePath {
            Task { do { try await reload() } catch { fail(error) } }; return
        }
        guard let value = event.payload as? [String: Any], value["courseId"] as? String == document.courseID, (value["relPath"] ?? value["fromRelPath"]) as? String == document.relativePath else { return }
        switch event.channel {
        case "nativeWorkspace:materialWillMutate": setMutating(true)
        case "nativeWorkspace:materialMutationCancelled": writesSuspended = false; setMutating(false)
        case "nativeWorkspace:materialReplaced", "nativeWorkspace:materialDeleted": retire(invalidateShared: true)
        default: break
        }
    }
}

private struct NativeWhiteboardBody: UIViewControllerRepresentable {
    let model: NativeWhiteboardModel
    func makeUIViewController(context: Context) -> NativeWhiteboardController { NativeWhiteboardController(model: model) }
    func updateUIViewController(_ uiViewController: NativeWhiteboardController, context: Context) {}
    static func dismantleUIViewController(_ controller: NativeWhiteboardController, coordinator: ()) { Task { await controller.model.close() } }
}
@MainActor
private final class NativeWhiteboardController: UIViewController, UIScrollViewDelegate {
    let model: NativeWhiteboardModel
    let surface: NativePDFInkSurface
    private let scroll = UIScrollView(), paper = UIImageView()
    private var paperKey = "", lastSize = CGSize.zero, fitted = false
    private var pendingViewport: NativeWhiteboardPanelState?
    private let pencil: NativePDFPencilGestureRecognizer
    init(model: NativeWhiteboardModel) {
        self.model = model
        // The app requires Metal for both PDF and whiteboard handwriting.
        surface = NativePDFInkSurface() ?? { fatalError("Metal handwriting is unavailable") }()
        #if DEBUG
        let fixture = model.store.root.lastPathComponent == "BandalDesktop-Native-UI-Tests" && ProcessInfo.processInfo.arguments.contains("--native-ui-testing") && ProcessInfo.processInfo.arguments.contains("--native-pencil-dispatch-fixture")
        pencil = NativePDFPencilGestureRecognizer(testTouchType: fixture ? .direct : .pencil)
        #else
        pencil = NativePDFPencilGestureRecognizer()
        #endif
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .secondarySystemBackground
        scroll.delegate = self; scroll.backgroundColor = .secondarySystemBackground; scroll.delaysContentTouches = false
        scroll.minimumZoomScale = 0.15; scroll.maximumZoomScale = 4
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scroll.pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addSubview(scroll); paper.frame = CGRect(x: 0, y: 0, width: 595.28, height: 841.89); paper.isUserInteractionEnabled = true; scroll.addSubview(paper)
        surface.frame = paper.bounds; paper.addSubview(surface); scroll.contentSize = paper.bounds.size
        surface.retainedInkEnabled = true; surface.nativeErasingEnabled = true; surface.mapper = .whiteboard(size: paper.bounds.size)
        surface.viewportProvider = { [weak self] in guard let self else { return nil }; return self.surface.convert(self.scroll.bounds, from: self.scroll) }
        surface.navigationInProgress = { [weak self] in guard let self else { return false }; return self.scroll.isDragging || self.scroll.isDecelerating || self.scroll.isZooming }
        surface.liveZoom = { [weak self] in self?.scroll.isZooming == true }
        surface.onStroke = { [weak model] in try model?.stroke($0, provisional: false) }
        surface.onCheckpoint = { [weak model] in try model?.stroke($0, provisional: true) }
        surface.onErase = { [weak model] in try model?.erase($0) }
        surface.onFailure = { [weak model] in model?.fail($0) }
        surface.onInputOwnership = { [weak model] active in if active { model?.store.markDocumentChanged() } }
        pencil.targetAtLocation = { [weak self] point in guard let self else { return nil }; return self.surface.pencilInputTarget(at: self.surface.convert(point, from: self.scroll)) as? NativePDFInkSurface }
        scroll.addGestureRecognizer(pencil); surface.accessibilityIdentifier = "native-whiteboard-ink"
        model.attach(self)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); scroll.frame = view.bounds
        if lastSize != view.bounds.size { lastSize = view.bounds.size; if !fitted { fit() } else { center() } }
        applyPendingViewport()
        surface.refreshViewport()
    }
    func configure(rows: [[String: Any]], images: [String: UIImage], size: CGSize, tool: String, color: String, width: Double, loading: Bool, background: String, dark: Bool) {
        if paper.bounds.size != size { scroll.zoomScale = 1; paper.frame = CGRect(origin: .zero, size: size); surface.frame = paper.bounds; surface.mapper = .whiteboard(size: size); scroll.contentSize = size; paperKey = ""; fit() }
        surface.isLoading = loading; surface.tool = .init(name: tool, style: .init(color: dark && color == "ink" ? "canvasLightInk" : color, width: width, opacity: tool == "highlighter" ? 0.32 : 1))
        // Resolve dark-paper ink only for presentation; canonical saved styles
        // retain their original palette names on every device.
        surface.objects = rows.map { source in
            guard dark else { return source }
            var row = source
            if var style = row["style"] as? [String: Any], style["color"] as? String == "ink" { style["color"] = "canvasLightInk"; row["style"] = style }
            if var data = row["data"] as? [String: Any], let runs = data["textRuns"] as? [[String: Any]] {
                data["textRuns"] = runs.map { source in var run = source; if var style = run["style"] as? [String: Any], style["color"] as? String == "ink" { style["color"] = "canvasLightInk"; run["style"] = style }; return run }; row["data"] = data
            }
            return row
        }; surface.imageForObject = { images[$0["id"] as? String ?? ""] }
        let key = background + ":" + String(dark)
        if key != paperKey {
            paperKey = key
            let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
            let image = UIGraphicsImageRenderer(size: paper.bounds.size, format: format).image { value in
                let context = value.cgContext; context.setFillColor((dark ? UIColor(white: 0.12, alpha: 1) : .white).cgColor); context.fill(paper.bounds)
                context.setStrokeColor(UIColor.gray.withAlphaComponent(0.3).cgColor); context.setFillColor(UIColor.gray.withAlphaComponent(0.4).cgColor); context.setLineWidth(0.5)
                if background == "dots" { for x in stride(from: 24.0, to: paper.bounds.width, by: 24) { for y in stride(from: 24.0, to: paper.bounds.height, by: 24) { context.fillEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5)) } } }
                else if background == "grid" || background == "lines" { for y in stride(from: 24.0, to: paper.bounds.height, by: 24) { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: paper.bounds.width, y: y)) }; if background == "grid" { for x in stride(from: 24.0, to: paper.bounds.width, by: 24) { context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: paper.bounds.height)) } }; context.strokePath() }
            }
            paper.image = image; surface.canvasPaperImage = image.cgImage
        }
    }
    func annotationImage(bounds: CGRect) throws -> UIImage? {
        try surface.flush()
        let selected = CGRect(x: bounds.minX * view.bounds.width, y: bounds.minY * view.bounds.height,
            width: bounds.width * view.bounds.width, height: bounds.height * view.bounds.height)
        let crop = paper.convert(selected, from: view).intersection(paper.bounds)
        guard !crop.isNull, crop.width > 1, crop.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.opaque = true
        format.scale = min(2, 2048 / max(crop.width, crop.height), sqrt(4_000_000 / (crop.width * crop.height)))
        return UIGraphicsImageRenderer(size: crop.size, format: format).image { renderer in
            renderer.cgContext.translateBy(x: -crop.minX, y: -crop.minY)
            paper.image?.draw(in: paper.bounds)
            let mapper = InkCoordinateMapper.whiteboard(size: paper.bounds.size)
            for row in surface.objects {
                NativePDFObjectRenderer.draw(row, in: renderer.cgContext, mapper: mapper, image: surface.imageForObject?(row))
            }
        }
    }
    func viewportState(page: Int) -> NativeWhiteboardPanelState {
        if var pendingViewport { pendingViewport.page = page; return pendingViewport }
        return .init(page: page, zoom: Double(scroll.zoomScale), offsetX: Double(scroll.contentOffset.x), offsetY: Double(scroll.contentOffset.y))
    }
    func restoreViewport(_ state: NativeWhiteboardPanelState) { pendingViewport = state; applyPendingViewport() }
    private func applyPendingViewport() {
        guard let state = pendingViewport, scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
        pendingViewport = nil; fitted = true
        scroll.setZoomScale(min(scroll.maximumZoomScale, max(scroll.minimumZoomScale, CGFloat(state.zoom))), animated: false)
        center(); scroll.setContentOffset(CGPoint(x: state.offsetX, y: state.offsetY), animated: false); surface.refreshViewport()
    }
    func previewImage() throws -> UIImage? {
        try surface.flush()
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.opaque = true; format.scale = min(2, 1600 / max(view.bounds.width, view.bounds.height))
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { renderer in
            UIColor.secondarySystemBackground.setFill(); renderer.fill(view.bounds)
            let paperRect = paper.convert(paper.bounds, to: view)
            renderer.cgContext.saveGState(); renderer.cgContext.translateBy(x: paperRect.minX, y: paperRect.minY)
            renderer.cgContext.scaleBy(x: paperRect.width / paper.bounds.width, y: paperRect.height / paper.bounds.height)
            paper.image?.draw(in: paper.bounds)
            let mapper = InkCoordinateMapper.whiteboard(size: paper.bounds.size)
            for row in surface.objects { NativePDFObjectRenderer.draw(row, in: renderer.cgContext, mapper: mapper, image: surface.imageForObject?(row)) }
            renderer.cgContext.restoreGState()
        }
    }
    func fit() {
        guard scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
        let scale = min((scroll.bounds.width - 24) / paper.bounds.width, (scroll.bounds.height - 24) / paper.bounds.height)
        fitted = true; scroll.setZoomScale(max(0.15, scale), animated: false); center(); surface.refreshViewport()
    }
    private func center() { scroll.contentInset = UIEdgeInsets(top: max(0, (scroll.bounds.height - scroll.contentSize.height) / 2), left: max(0, (scroll.bounds.width - scroll.contentSize.width) / 2), bottom: 0, right: 0) }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { paper }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center(); surface.refreshViewport() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { surface.refreshViewport() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { do { try surface.prepareForNavigation() } catch { model.fail(error) } }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { do { try surface.prepareForNavigation() } catch { model.fail(error) } }
}
