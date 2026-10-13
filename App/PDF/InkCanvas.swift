import SwiftUI
import PencilKit
import CryptoKit

enum InkTool: String, CaseIterable, Identifiable {
    case pen, highlighter, eraser, lasso, read
    var id: String { rawValue }
    var label: String {
        switch self { case .pen: "펜"; case .highlighter: "형광펜"; case .eraser: "획 지우개"
        case .lasso: "선택 이동"; case .read: "텍스트 선택" }
    }
    var symbol: String {
        switch self { case .pen: "pencil.tip"; case .highlighter: "highlighter"; case .eraser: "eraser"
        case .lasso: "lasso"; case .read: "hand.point.up.left" }
    }
}

@MainActor
final class InkToolState: ObservableObject {
    @Published var tool: InkTool = .pen
    @Published var color: InkPalette = .ink
    @Published var width: Double = 2.5
    @Published var fingerDrawing = false
    @Published var leadingPalette = false

    var pencilTool: any PKTool {
        switch tool {
        case .eraser: PKEraserTool(.vector)
        case .lasso, .read: PKLassoTool()
        case .pen: PKInkingTool(.pen, color: color.uiColor, width: width)
        case .highlighter: PKInkingTool(.marker, color: color.uiColor.withAlphaComponent(0.38), width: width * 5)
        }
    }
}

struct InkToolPalette: View {
    @ObservedObject var tools: InkToolState
    var undo: () -> Void
    var redo: () -> Void
    var insertShape: ((String) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(InkTool.allCases) { tool in
                    Button { tools.tool = tool } label: {
                        Image(systemName: tool.symbol).frame(width: 44, height: 44)
                            .background(tools.tool == tool ? Color.accentColor.opacity(0.14) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }.accessibilityLabel(tool.label)
                        .accessibilityAddTraits(tools.tool == tool ? .isSelected : [])
                        .help(tool.label)
                }
                Divider().frame(height: 24)
                Menu {
                    ForEach(InkPalette.allCases) { color in
                        Button { tools.color = color } label: { Label(color.label, systemImage: "circle.fill") }
                    }
                } label: {
                    Circle().fill(Color(tools.color.uiColor)).frame(width: 22, height: 22).frame(width: 44, height: 44)
                }.accessibilityLabel("필기 색: \(tools.color.label)")
                Menu {
                    ForEach([1.0, 2.5, 4.0, 7.0], id: \.self) { width in
                        Button("\(width.formatted()) 포인트") { tools.width = width }
                    }
                } label: {
                    VStack(spacing: 2) {
                        Capsule().frame(width: 22, height: max(2, tools.width))
                        Text(tools.width.formatted()).font(.system(size: 9))
                    }.frame(width: 44, height: 44)
                }.accessibilityLabel("펜 두께: \(tools.width.formatted()) 포인트")
                if let insertShape {
                    Menu {
                        Button("직선", systemImage: "line.diagonal") { insertShape("line") }
                        Button("사각형", systemImage: "rectangle") { insertShape("rect") }
                        Button("타원", systemImage: "circle") { insertShape("ellipse") }
                        Button("화살표", systemImage: "arrow.up.right") { insertShape("arrow") }
                    } label: { Image(systemName: "square.on.circle").frame(width: 44, height: 44) }
                        .accessibilityLabel("도형 추가")
                }
                Button(action: undo) { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }
                    .accessibilityLabel("필기 실행 취소").keyboardShortcut("z", modifiers: .command)
                Button(action: redo) { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }
                    .accessibilityLabel("필기 다시 실행").keyboardShortcut("z", modifiers: [.command, .shift])
                Menu {
                    Toggle("손가락으로 필기", isOn: $tools.fingerDrawing)
                    Toggle("도구막대 왼쪽 정렬", isOn: $tools.leadingPalette)
                } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                    .accessibilityLabel("필기 설정")
            }.padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: tools.leadingPalette ? .leading : .trailing)
        }.background(.regularMaterial)
    }
}

enum PortableInkCodec {
    static func digest(_ objects: [PortableInkObject]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(objects) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func nativeKey(_ stroke: PKStroke) -> String {
        "\(stroke.path.creationDate.timeIntervalSince1970)-\(stroke.randomSeed)"
    }

    static func objects(from drawing: PKDrawing, mapper: InkCoordinateMapper,
                        previous: [PortableInkObject]) -> [PortableInkObject] {
        let prior = Dictionary(previous.compactMap { object in object.nativeKey.map { ($0, object) } },
                               uniquingKeysWith: { a, _ in a })
        let now = ISO8601DateFormatter().string(from: Date())
        let strokes = drawing.strokes.map { stroke -> PortableInkObject in
            let key = nativeKey(stroke)
            let old = prior[key]
            let points = stroke.path.map { point in
                mapper.normalized(point.location.applying(stroke.transform), pressure: min(1, max(0, Double(point.force))))
            }
            let scale = hypot(stroke.transform.a, stroke.transform.b)
            let meanWidth = stroke.path.isEmpty ? 2 : stroke.path.reduce(0) { $0 + $1.size.width } / CGFloat(stroke.path.count)
            let style = InkStyle(color: InkPalette.nearest(stroke.ink.color).rawValue,
                                 width: Double(meanWidth * scale / mapper.canvasUnitsPerPDFPoint) / mapper.geometry.width,
                                 opacity: Double(stroke.ink.color.cgColor.alpha))
            let kind = stroke.ink.inkType == .marker ? "highlighter" : "ink"
            let geometry = InkGeometry(points: points)
            let unchanged = old?.data == geometry && old?.style == style && old?.kind == kind
            return PortableInkObject(id: old?.id ?? UUID().uuidString, kind: kind, data: geometry,
                                     style: style, createdAt: old?.createdAt ?? now,
                                     updatedAt: unchanged ? old!.updatedAt : now, nativeKey: key)
        }
        // Unsupported desktop objects remain in the sidecar when drawing is edited.
        return strokes + previous.filter { $0.kind != "ink" && $0.kind != "highlighter" }
    }

    static func drawing(objects: [PortableInkObject], mapper: InkCoordinateMapper) -> PKDrawing {
        PKDrawing(strokes: objects.compactMap { object in
            guard (object.kind == "ink" || object.kind == "highlighter"),
                  let points = object.data.points, !points.isEmpty else { return nil }
            let color = (InkPalette(rawValue: object.style.color) ?? .ink).uiColor
                .withAlphaComponent(CGFloat(object.style.opacity))
            let size = max(0.2, object.style.width * mapper.geometry.width * mapper.canvasUnitsPerPDFPoint)
            let strokePoints = points.enumerated().map { index, point in
                PKStrokePoint(location: mapper.canvasPoint(point), timeOffset: Double(index) * 0.008,
                              size: CGSize(width: size, height: size), opacity: 1,
                              force: max(0.01, point.p), azimuth: 0, altitude: .pi / 2)
            }
            let date = ISO8601DateFormatter().date(from: object.createdAt) ?? Date(timeIntervalSince1970: 0)
            let path = PKStrokePath(controlPoints: strokePoints, creationDate: date)
            // Stable seed allows object identities to survive a portable-only restoration.
            let seed = SHA256.hash(data: Data(object.id.utf8)).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return PKStroke(ink: PKInk(object.kind == "highlighter" ? .marker : .pen, color: color),
                            path: path, randomSeed: seed)
        })
    }

    static func restoring(_ record: PortableInkPageRecord, mapper: InkCoordinateMapper, size: CGSize) -> PKDrawing {
        if let cache = record.nativeCache, abs(cache.canvasWidth - size.width) < 0.5,
           abs(cache.canvasHeight - size.height) < 0.5, cache.portableDigest == digest(record.objects),
           let drawing = try? PKDrawing(data: cache.drawing) { return drawing }
        return drawing(objects: record.objects, mapper: mapper)
    }
}

/// PencilKit forwards internal canvas events to its delegate. A PKCanvasView
/// must never be its own delegate: device Pencil input can recurse through
/// PencilKit's private forwarding methods until the main-thread stack overflows.
@MainActor
private final class InkCanvasDelegate: NSObject, PKCanvasViewDelegate {
    weak var canvas: PersistentInkCanvas?

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard canvasView === canvas else { return }
        canvas?.didBeginUsingTool()
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard canvasView === canvas else { return }
        canvas?.didEndUsingTool()
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard canvasView === canvas else { return }
        canvas?.drawingDidChange()
    }
}

/// Keeps canvas instances stable across SwiftUI redraws, suppresses programmatic
/// load callbacks, and persists both tool-end and delayed PencilKit final changes.
@MainActor
final class PersistentInkCanvas: PKCanvasView {
    var record: PortableInkPageRecord?
    var mapper: InkCoordinateMapper?
    var save: ((PortableInkPageRecord) -> Void)?
    var onLayout: ((PersistentInkCanvas) -> Void)?
    var onBegin: (() -> Void)?
    var acceptsFingerDrawing = false
    var isReadOnly = false
    private var isRestoring = false
    private var usingTool = false
    private var dirty = false
    private var lastSavedDrawing: Data?
    private var saveTask: Task<Void, Never>?
    private let inkDelegate = InkCanvasDelegate()
    var hasActiveTool: Bool { usingTool }

    override init(frame: CGRect) {
        super.init(frame: frame)
        inkDelegate.canvas = self
        delegate = inkDelegate
        backgroundColor = .clear; isOpaque = false; isScrollEnabled = false
        contentInset = .zero; drawingPolicy = .pencilOnly
        overrideUserInterfaceStyle = .light
        isAccessibilityElement = true
        accessibilityIdentifier = "bandal-ink-canvas"
        accessibilityLabel = "필기 캔버스"
        updateAccessibilitySummary()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0 && bounds.height > 0 { onLayout?(self) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
    }

    func updateMapper(_ replacement: InkCoordinateMapper) {
        guard let original = mapper else { mapper = replacement; return }
        let transform = original.canvasToPDF.concatenating(replacement.pdfToCanvas)
        // Normally PDFKit zooms the complete overlay and this is the identity.
        // If it changes the actual canvas bounds, reproject the paths as well.
        if abs(transform.a - 1) > 0.001 || abs(transform.d - 1) > 0.001 ||
            abs(transform.b) > 0.001 || abs(transform.c) > 0.001 ||
            abs(transform.tx) > 0.01 || abs(transform.ty) > 0.01 {
            flush()
            isRestoring = true
            drawing = drawing.transformed(using: transform)
            lastSavedDrawing = drawing.dataRepresentation()
            isRestoring = false
            undoManager?.removeAllActions()
        }
        mapper = replacement
    }

    func configure(_ state: InkToolState) {
        tool = state.pencilTool
        acceptsFingerDrawing = state.fingerDrawing
        drawingPolicy = state.fingerDrawing ? .anyInput : .pencilOnly
        isUserInteractionEnabled = state.tool != .read && !isReadOnly
        updateAccessibilitySummary()
    }

    func restore(_ record: PortableInkPageRecord, mapper: InkCoordinateMapper) {
        guard self.record == nil, bounds.width > 0, bounds.height > 0 else { return }
        self.record = record; self.mapper = mapper
        isRestoring = true
        drawing = PortableInkCodec.restoring(record, mapper: mapper, size: bounds.size)
        // A portable restore assigns PK-native keys without changing durable object IDs.
        let portable = record.objects.filter { $0.kind == "ink" || $0.kind == "highlighter" }
        for (object, stroke) in zip(portable, drawing.strokes) {
            if let index = self.record?.objects.firstIndex(where: { $0.id == object.id }) {
                self.record?.objects[index].nativeKey = PortableInkCodec.nativeKey(stroke)
            }
        }
        lastSavedDrawing = drawing.dataRepresentation()
        isRestoring = false; dirty = false
        undoManager?.removeAllActions()
        updateAccessibilitySummary()
    }

    func reload(_ record: PortableInkPageRecord) {
        guard !usingTool, let mapper else { return }
        self.record = nil
        restore(record, mapper: mapper)
    }

    fileprivate func didBeginUsingTool() {
        usingTool = true; onBegin?(); saveTask?.cancel()
    }
    fileprivate func didEndUsingTool() {
        usingTool = false; dirty = true; flush()
    }
    fileprivate func drawingDidChange() {
        guard !isRestoring, record != nil, !isReadOnly else { return }
        dirty = true
        guard !usingTool else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        guard !isReadOnly, !isRestoring, dirty, var record, let mapper else { return }
        let data = drawing.dataRepresentation()
        guard data != lastSavedDrawing else { dirty = false; return }
        let oldIDs = Set(record.objects.map(\.id))
        record.objects = PortableInkCodec.objects(from: drawing, mapper: mapper, previous: record.objects)
        let removedIDs = oldIDs.subtracting(record.objects.map(\.id))
        record.deletedObjectIDs = Array(Set(record.deletedObjectIDs).union(removedIDs)).sorted()
        record.nativeCache = NativeInkCache(drawing: data, canvasWidth: bounds.width,
                                           canvasHeight: bounds.height, portableDigest: PortableInkCodec.digest(record.objects))
        self.record = record; lastSavedDrawing = data; dirty = false
        updateAccessibilitySummary()
        save?(record)
    }

    private func updateAccessibilitySummary() {
        accessibilityValue = "\(drawing.strokes.count)개의 획 · \(acceptsFingerDrawing ? "손가락 필기" : "Pencil 필기")"
        accessibilityHint = acceptsFingerDrawing ? "한 손가락으로 쓰고 두 손가락으로 이동합니다." : "Pencil로 쓰고 손가락으로 이동합니다."
    }

    func performUndo() { undoManager?.undo(); dirty = true; flush() }
    func performRedo() { undoManager?.redo(); dirty = true; flush() }

    func insertShape(_ kind: String, state: InkToolState) {
        guard record != nil, !isReadOnly else { return }
        let box = CGRect(x: bounds.width * 0.3, y: bounds.height * 0.3,
                         width: min(180, bounds.width * 0.4), height: min(120, bounds.height * 0.25))
        let points: [CGPoint]
        switch kind {
        case "rect": points = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                               CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX, y: box.minY)]
        case "ellipse": points = (0...64).map { i in
            let angle = Double(i) / 64 * .pi * 2
            return CGPoint(x: box.midX + cos(angle) * box.width / 2, y: box.midY + sin(angle) * box.height / 2)
        }
        case "arrow": points = [CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.minY),
                                CGPoint(x: box.maxX - 22, y: box.minY + 4), CGPoint(x: box.maxX, y: box.minY),
                                CGPoint(x: box.maxX - 4, y: box.minY + 22)]
        default: points = [CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.minY)]
        }
        let control = points.enumerated().map { index, p in
            PKStrokePoint(location: p, timeOffset: Double(index) * 0.02,
                          size: CGSize(width: state.width, height: state.width), opacity: 1,
                          force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: state.color.uiColor), path: PKStrokePath(controlPoints: control, creationDate: Date()))
        replaceWithUndo(PKDrawing(strokes: drawing.strokes + [stroke]))
    }

    private func replaceWithUndo(_ replacement: PKDrawing) {
        let previous = drawing
        undoManager?.registerUndo(withTarget: self) { target in target.replaceWithUndo(previous) }
        drawing = replacement; dirty = true; flush()
    }
}
