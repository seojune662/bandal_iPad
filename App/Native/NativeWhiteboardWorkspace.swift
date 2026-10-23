import SwiftUI
import UIKit
import PDFKit
import Combine

struct NativeWhiteboardWorkspace: View {
    @StateObject private var model: NativeWhiteboardModel
    @ObservedObject private var annotation: NativeAnnotationCoordinator
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
                HStack { tools; Spacer(); navigation }
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) { tools }.frame(height: 44)
                    navigation
                }
            }.padding(.horizontal, 8).background(NativeDesktopTheme.surface)
            }
            NativeWhiteboardBody(model: model).accessibilityIdentifier("native-whiteboard-workspace")
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
        }.onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in model.background() }
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
private final class NativeWhiteboardModel: ObservableObject {
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
    weak var controller: NativeWhiteboardController?
    private var writer: NativeWhiteboardPersistence?, opening: Task<Void, Error>?, registration: UUID?
    private var operationTask: Task<Void, Error>?
    private var rows: [[String: Any]] = [], media: [String: UIImage] = [:], board: [String: Any] = [:]
    private var pageGeometries: [String: [String: Any]] = [:]
    private var width = 0.003, retired = false, closing = false, mutating = false, writesSuspended = false
    private var events: AnyCancellable?
    private var undoStack: [[[String: Any]]] = [], redoStack: [[[String: Any]]] = [], completed = Set<String>()
    private var strokePages: [String: Int] = [:]
    init(document: NativeDocumentReference, store: NativeWorkspaceStore) {
        self.document = document; self.store = store
        events = store.events.sink { [weak self] in self?.receive($0) }
    }
    func attach(_ controller: NativeWhiteboardController) {
        self.controller = controller
        guard opening == nil else { return }
        registration = store.registerDocumentFlush(id: document.id,
            freeze: { [weak self] in self?.setMutating(true) },
            suspendWrites: { [weak self] in self?.writesSuspended = true },
            resume: { [weak self] in self?.writesSuspended = false; self?.setMutating(false) },
            retire: { [weak self] in self?.retire() }) { [self] in try await flush() }
        let task = Task { @MainActor in
            await self.store.waitForExternalMutation()
            guard !self.retired, !Task.isCancelled else { return }
            let writer = try NativeWhiteboardPersistence(root: self.store.root, courseID: self.document.courseID, boardID: self.document.relativePath) { [store = self.store] channel, input in try await store.invoke(channel, input) }
            self.writer = writer
            writer.onChange = { [weak self] in try await self?.reload() }
            try await writer.drain(); try await self.reload(); self.loading = false; self.refresh()
        }
        opening = task
        Task { do { try await task.value } catch { fail(error) } }
    }
    private var identity: [String: Any] { ["courseId": document.courseID, "boardId": document.relativePath] }
    private func reload() async throws {
        guard !retired else { return }
        guard let result = try await store.invoke("canvas:open", identity) as? [String: Any], let rows = result["shapes"] as? [[String: Any]], let board = result["board"] as? [String: Any] else { throw NativePDFError.invalid("노트를 읽지 못했습니다.") }
        self.board = board; self.rows = rows; pageCount = board["pageCount"] as? Int ?? 1; page = min(page, pageCount)
        pageGeometries = result["pageGeometries"] as? [String: [String: Any]] ?? [:]
        for row in rows where ["image", "clip"].contains(row["kind"] as? String ?? "") {
            guard let id = row["id"] as? String, media[id] == nil, let data = row["data"] as? [String: Any], let kind = row["kind"] as? String, let source = data[kind] as? [String: Any], let path = source["relPath"] as? String else { continue }
            if let local = try? await store.invokePrivate("nativeMaterial:path", ["courseId": document.courseID, "relPath": path]) as? String {
                if kind == "image" { media[id] = UIImage(contentsOfFile: local) }
                else if let document = PDFDocument(url: URL(fileURLWithPath: local)), let page = document.page(at: (source["page"] as? Int ?? 1) - 1) {
                    var image = page.thumbnail(of: CGSize(width: 1000, height: 1400), for: .cropBox)
                    if let crop = source["crop"] as? [String: Double], let pixels = image.cgImage,
                       let clipped = pixels.cropping(to: CGRect(x: (crop["x"] ?? 0) * Double(pixels.width), y: (crop["y"] ?? 0) * Double(pixels.height), width: (crop["width"] ?? 1) * Double(pixels.width), height: (crop["height"] ?? 1) * Double(pixels.height))) { image = UIImage(cgImage: clipped) }
                    media[id] = image
                }
            }
        }
        refresh()
    }
    private func visibleRows() -> [[String: Any]] {
        var result = rows
        for record in writer?.pendingRecords ?? [] {
            for command in record["commands"] as? [[String: Any]] ?? [] {
                guard let request = command["request"] as? [String: Any] else { continue }
                if command["channel"] as? String == "canvas:removeShapes", let ids = request["ids"] as? [String] { result.removeAll { ids.contains($0["id"] as? String ?? "") } }
                else if let id = request["id"] as? String, var shape = request["shape"] as? [String: Any] { result.removeAll { $0["id"] as? String == id }; shape["id"] = id; shape["page"] = request["page"] ?? 1; result.append(shape) }
            }
        }
        return result
    }
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
            loading: loading || blocked || error != nil || retired || closing, background: board["background"] as? String ?? "grid", dark: board["surface"] as? String == "dark")
    }
    func stroke(_ stroke: NativePDFCompletedStroke, provisional: Bool) throws {
        guard let writer, !retired else { throw NativePDFError.invalid("노트 저장 연결이 닫혔습니다.") }
        let capturedPage = strokePages[stroke.mutationID] ?? page
        strokePages[stroke.mutationID] = capturedPage
        var canonicalStyle = stroke.style
        if canonicalStyle.color == "canvasLightInk" { canonicalStyle.color = "ink" }
        let points = try DesktopJSON.decode(JSONEncoder().encode(stroke.points)), style = try DesktopJSON.decode(JSONEncoder().encode(canonicalStyle))
        let shape: [String: Any] = ["kind": stroke.kind, "data": ["inkVersion": stroke.inkVersion, "points": points], "style": style]
        try writer.enqueue(id: stroke.mutationID, commands: [["channel": "canvas:putShape", "request": ["id": stroke.mutationID, "page": capturedPage, "shape": shape]]])
        if !provisional, completed.insert(stroke.mutationID).inserted { undoStack.append([["channel": "canvas:removeShapes", "request": ["ids": [stroke.mutationID]]]]); redoStack.removeAll() }
        store.markDocumentChanged(); refresh(); drain()
    }
    func erase(_ targets: [NativePDFEraseTarget]) throws {
        guard let writer, !retired else { throw NativePDFError.invalid("노트 저장 연결이 닫혔습니다.") }
        let ids = Set(targets.compactMap { $0.drawingID ?? $0.mutationID }), removed = visibleRows().filter { ids.contains($0["id"] as? String ?? "") }
        guard !ids.isEmpty else { return }
        try writer.enqueue(commands: [["channel": "canvas:removeShapes", "request": ["ids": ids.sorted()]]])
        undoStack.append(removed.map(restore)); redoStack.removeAll(); store.markDocumentChanged(); refresh(); drain()
    }
    private func restore(_ row: [String: Any]) -> [String: Any] { ["channel": "canvas:putShape", "request": ["id": row["id"]!, "page": row["page"] ?? 1, "restore": true, "shape": ["kind": row["kind"]!, "data": row["data"]!, "style": row["style"]!]]] }
    private func drain() { guard error == nil else { return }; Task { do { try await writer?.drain(); refresh() } catch { fail(error) } } }
    func chooseTool(_ name: String) { do { try controller?.surface.flush(); tool = name; if name == "highlighter", color == "ink" { color = "yellow" }; refresh() } catch { fail(error) } }
    func chooseColor(_ name: String) { color = name; refresh() }
    func setWidth(_ value: Double) { width = value; refresh() }
    func undo() { history(undo: true) }; func redo() { history(undo: false) }
    private func history(undo: Bool) {
        guard !blocked, error == nil, let commands = undo ? undoStack.last : redoStack.last else { return }
        perform { [self] in
                var inverse: [[String: Any]] = []
                for command in commands {
                    let request = command["request"] as! [String: Any]
                    if command["channel"] as? String == "canvas:removeShapes", let ids = request["ids"] as? [String] { inverse += visibleRows().filter { ids.contains($0["id"] as? String ?? "") }.map(restore) }
                    else if let id = request["id"] as? String { inverse.append(["channel": "canvas:removeShapes", "request": ["ids": [id]]]) }
                }
                try self.writer?.enqueue(commands: commands); self.store.markDocumentChanged()
                if undo { undoStack.removeLast(); redoStack.append(inverse) } else { redoStack.removeLast(); undoStack.append(inverse) }
                try await self.writer?.drain()
        }
    }
    func go(_ delta: Int) {
        perform { self.page = min(self.pageCount, max(1, self.page + delta)); self.controller?.fit() }
    }
    func addPage() {
        perform { _ = try await self.store.invoke("canvas:setPageCount", self.identity.merging(["pageCount": self.pageCount + 1]) { _, n in n }); try await self.reload(); self.page = self.pageCount; self.controller?.fit() }
    }
    func flush() async throws {
        if let operationTask { try await operationTask.value }
        try await flushInput()
    }
    private func flushInput() async throws {
        if writesSuspended { await store.waitForExternalMutation() }
        guard !retired else { return }
        if let opening { do { try await opening.value } catch { if writer?.pendingCount == 0 || writer == nil { return }; throw error } }
        guard !retired else { return }; try controller?.surface.flush(); try await writer?.drain(); refresh()
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
    func close() {
        guard !closing, !retired else { return }; closing = true; blocked = true; refresh()
        Task { do { try await flush(); retire() } catch { closing = false; fail(error) } }
    }
    func retry() {
        Task { do {
            await store.waitForExternalMutation(); guard !retired else { return }
            try await writer?.drain(); try await reload(); opening = nil; error = nil; loading = false; blocked = mutating || closing; refresh()
        } catch { fail(error) } }
    }
    func background() {
        let token = UIApplication.shared.beginBackgroundTask(withName: "Save whiteboard")
        Task { defer { if token != .invalid { UIApplication.shared.endBackgroundTask(token) } }; do { try await flush() } catch { fail(error) } }
    }
    func fail(_ failure: Error) { error = failure.localizedDescription; loading = false; refresh() }
    private func setMutating(_ value: Bool) { mutating = value; blocked = value || closing || operationTask != nil; refresh() }
    private func retire() { retired = true; writesSuspended = false; blocked = true; refresh(); if let registration { store.unregisterDocumentFlush(registration); self.registration = nil } }
    private func receive(_ event: NativeWorkspaceEvent) {
        guard let value = event.payload as? [String: Any], value["courseId"] as? String == document.courseID, (value["relPath"] ?? value["fromRelPath"]) as? String == document.relativePath else { return }
        switch event.channel {
        case "nativeWorkspace:materialWillMutate": setMutating(true)
        case "nativeWorkspace:materialMutationCancelled": writesSuspended = false; setMutating(false)
        case "nativeWorkspace:materialReplaced", "nativeWorkspace:materialDeleted": retire()
        default: break
        }
    }
}

private struct NativeWhiteboardBody: UIViewControllerRepresentable {
    let model: NativeWhiteboardModel
    func makeUIViewController(context: Context) -> NativeWhiteboardController { NativeWhiteboardController(model: model) }
    func updateUIViewController(_ uiViewController: NativeWhiteboardController, context: Context) {}
    static func dismantleUIViewController(_ controller: NativeWhiteboardController, coordinator: ()) { controller.model.close() }
}
@MainActor
private final class NativeWhiteboardController: UIViewController, UIScrollViewDelegate {
    let model: NativeWhiteboardModel
    let surface: NativePDFInkSurface
    private let scroll = UIScrollView(), paper = UIImageView()
    private var paperKey = "", lastSize = CGSize.zero, fitted = false
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
        if lastSize != view.bounds.size { lastSize = view.bounds.size; fit() }
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
    func fit() {
        guard scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
        let scale = min((scroll.bounds.width - 24) / paper.bounds.width, (scroll.bounds.height - 24) / paper.bounds.height)
        scroll.setZoomScale(max(0.15, scale), animated: false); center(); surface.refreshViewport()
    }
    private func center() { scroll.contentInset = UIEdgeInsets(top: max(0, (scroll.bounds.height - scroll.contentSize.height) / 2), left: max(0, (scroll.bounds.width - scroll.contentSize.width) / 2), bottom: 0, right: 0) }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { paper }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center(); surface.refreshViewport() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { surface.refreshViewport() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { do { try surface.prepareForNavigation() } catch { model.fail(error) } }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { do { try surface.prepareForNavigation() } catch { model.fail(error) } }
}
