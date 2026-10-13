import SwiftUI
import PencilKit

struct WhiteboardWorkspaceView: View {
    @StateObject private var controller: WhiteboardController
    @StateObject private var tools = InkToolState()
    @Environment(\.scenePhase) private var scenePhase

    init(materialID: String, revision: String = "1", load: @escaping () -> Data?, save: @escaping (Data) -> Void) {
        _controller = StateObject(wrappedValue: WhiteboardController(materialID: materialID, revision: revision, load: load, save: save))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("화이트보드", systemImage: "rectangle.on.rectangle").font(.subheadline.weight(.medium))
                Spacer()
                Button { controller.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }
                    .accessibilityLabel("보드 전체 보기")
            }.padding(.horizontal, 16).background(.bar)
            if let error = controller.warning {
                Text(error).font(.caption).foregroundStyle(.orange).padding(12)
            }
            WhiteboardCanvasHost(controller: controller, tools: tools)
            InkToolPalette(tools: tools, undo: { controller.canvas.performUndo() },
                           redo: { controller.canvas.performRedo() },
                           insertShape: { controller.canvas.insertShape($0, state: tools) })
        }
        .onDisappear { controller.canvas.flush() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { controller.canvas.flush() } }
    }
}

private struct WhiteboardCanvasHost: UIViewRepresentable {
    @ObservedObject var controller: WhiteboardController
    @ObservedObject var tools: InkToolState
    func makeUIView(context: Context) -> UIScrollView { controller.install(); controller.configure(tools); return controller.scrollView }
    func updateUIView(_ view: UIScrollView, context: Context) { controller.configure(tools) }
    static func dismantleUIView(_ uiView: UIScrollView, coordinator: ()) {
        (uiView.delegate as? WhiteboardController)?.canvas.flush()
    }
}

@MainActor
final class WhiteboardController: NSObject, ObservableObject, UIScrollViewDelegate {
    @Published var warning: String?
    let scrollView: UIScrollView = BoardScrollView()
    let canvas = PersistentInkCanvas()
    private let paper = BoardPaperView(frame: CGRect(x: 0, y: 0, width: 1200, height: 1600))
    private let materialID: String
    private let revision: String
    private let load: () -> Data?
    private let save: (Data) -> Void
    private var installed = false
    private var loadedData: Data?
    private var refreshTask: Task<Void, Never>?
    private var incomingPage: (base: PortableInkPageRecord, remote: PortableInkPageRecord)?
    private var followsWindowSize = true
    private var applyingFit = false

    init(materialID: String, revision: String, load: @escaping () -> Data?, save: @escaping (Data) -> Void) {
        self.materialID = materialID; self.revision = revision; self.load = load; self.save = save
        super.init()
    }
    func install() {
        guard !installed else { return }; installed = true
        scrollView.delegate = self
        (scrollView as? BoardScrollView)?.onViewportResize = { [weak self] in
            guard let self else { return }
            if self.followsWindowSize { self.fit() } else { self.centerPaper() }
        }
        scrollView.delaysContentTouches = false
        scrollView.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.minimumZoomScale = 0.15; scrollView.maximumZoomScale = 4
        scrollView.backgroundColor = .secondarySystemBackground
        scrollView.contentSize = paper.bounds.size
        scrollView.addSubview(paper)
        canvas.frame = paper.bounds
        paper.addSubview(canvas)
        let mapper = InkCoordinateMapper.whiteboard(size: paper.bounds.size)
        var record = PortableInkPageRecord.empty(materialID: materialID, revision: revision, page: 1, geometry: mapper.geometry)
        if let data = load() {
            loadedData = data
            do {
                record = try JSONDecoder().decode(PortableInkPageRecord.self, from: data)
                try record.validate(materialID: materialID, revision: revision, page: 1, geometry: mapper.geometry)
            } catch {
                canvas.isReadOnly = true; warning = error.localizedDescription
                record = PortableInkPageRecord.empty(materialID: materialID, revision: revision, page: 1, geometry: mapper.geometry)
            }
        }
        canvas.restore(record, mapper: mapper)
        canvas.save = { [weak self] incomingRecord in
            guard let self else { return }
            do {
                var record = incomingRecord
                if let incoming = self.incomingPage {
                    self.incomingPage = nil
                    let merged = try PortableInkThreeWayMerge.merge(base: incoming.base, local: record, remote: incoming.remote)
                    record = merged.record
                    if self.canvas.hasActiveTool { self.incomingPage = (incomingRecord, record) }
                    else { self.canvas.reload(record) }
                    if merged.preservedConflicts { self.warning = "같은 필기의 동시 수정이 있어 두 버전을 별도 항목으로 보존했습니다." }
                }
                let data = try PortableInkPersistence.encode(record)
                self.loadedData = data; self.save(data)
            } catch { self.warning = "보드를 저장하지 못했습니다: \(error.localizedDescription)" }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(flush), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recordsChanged), name: Notification.Name("app.bandal.records.changed"), object: nil)
        DispatchQueue.main.async { [weak self] in self?.fit() }
    }
    func configure(_ tools: InkToolState) {
        canvas.configure(tools)
        scrollView.panGestureRecognizer.minimumNumberOfTouches = tools.fingerDrawing ? 2 : 1
        scrollView.canCancelContentTouches = !tools.fingerDrawing
    }
    func fit() {
        guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
        followsWindowSize = true; applyingFit = true
        let scale = min(scrollView.bounds.width / paper.bounds.width, scrollView.bounds.height / paper.bounds.height)
        scrollView.setZoomScale(max(scrollView.minimumZoomScale, scale), animated: false)
        applyingFit = false
        centerPaper()
    }
    @objc private func flush() { canvas.flush() }
    @objc private func recordsChanged() {
        if let baseline = canvas.record, load() != loadedData {
            do {
                let remote = try load().map { try JSONDecoder().decode(PortableInkPageRecord.self, from: $0) } ??
                    PortableInkPageRecord.empty(materialID: materialID, revision: revision, page: 1, geometry: baseline.geometry)
                try remote.validate(materialID: materialID, revision: revision, page: 1, geometry: baseline.geometry)
                incomingPage = (incomingPage?.base ?? baseline, remote)
            } catch { warning = error.localizedDescription }
        }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while canvas.hasActiveTool {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            canvas.flush()
            let data = load()
            guard data != loadedData else { return }
            let geometry = InkCoordinateMapper.whiteboard(size: paper.bounds.size).geometry
            do {
                let record = try data.map { try JSONDecoder().decode(PortableInkPageRecord.self, from: $0) } ??
                    PortableInkPageRecord.empty(materialID: materialID, revision: revision, page: 1, geometry: geometry)
                try record.validate(materialID: materialID, revision: revision, page: 1, geometry: geometry)
                canvas.isReadOnly = false; canvas.reload(record); loadedData = data; incomingPage = nil
            } catch { warning = error.localizedDescription; canvas.isReadOnly = true }
        }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { paper }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        if !applyingFit { followsWindowSize = false }
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPaper() }
    private func centerPaper() {
        let horizontal = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let vertical = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}

@MainActor
private final class BoardScrollView: UIScrollView {
    var onViewportResize: (() -> Void)?
    private var lastViewport = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastViewport else { return }
        lastViewport = bounds.size
        onViewportResize?()
    }
}

@MainActor
private final class BoardPaperView: UIView {
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .white; isOpaque = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor(white: 0.86, alpha: 1).cgColor)
        for x in stride(from: 20, to: Int(bounds.width), by: 24) {
            for y in stride(from: 20, to: Int(bounds.height), by: 24) {
                context.fillEllipse(in: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1.6, height: 1.6))
            }
        }
    }
}
