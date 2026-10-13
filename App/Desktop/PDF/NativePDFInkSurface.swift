import UIKit
import PDFKit

@MainActor
final class NativePDFInkSurface: UIView {
    struct Tool: Equatable {
        var name = "select"
        var style = NativePDFInkStyle(color: "ink", width: 0.003, opacity: 1)
    }
    var tool = Tool() { didSet { if tool != oldValue { finishMeasuredStroke() } } }
    var mapper: InkCoordinateMapper? { didSet {
        if oldValue?.canvasToPDF != mapper?.canvasToPDF || oldValue?.geometry != mapper?.geometry { invalidateBackdrop(paper: true) }
        decorations.setNeedsDisplay(); schedulePreview()
    } }
    var pdfPage: PDFPage? { didSet { if oldValue !== pdfPage { invalidateBackdrop(paper: true) } } }
    var onStroke: ((NativePDFCompletedStroke) throws -> Void)?
    var onCheckpoint: ((NativePDFCompletedStroke) throws -> Void)?
    var onFailure: ((Error) -> Void)?
    var onInteraction: ((String, [String: Any]) -> Void)?
    var onPointer: (([String: Any]) -> Void)?
    var onInputOwnership: ((Bool) -> Void)?
    var onLayout: (() -> Void)?
    var viewportProvider: (() -> CGRect?)?
    var onTiming: ((Double, Int) -> Void)?
    var objects: [[String: Any]] = [] { didSet { if !(oldValue as NSArray).isEqual(to: objects) { invalidateBackdrop() } } }
    var highlights: [[String: Any]] = [] { didSet { if !(oldValue as NSArray).isEqual(to: highlights) { invalidateBackdrop() } } }
    var selectionBox: [String: Double]? { didSet { decorations.setNeedsDisplay() } }
    var selectedTextRects: [[String: Double]] = [] { didSet { decorations.setNeedsDisplay() } }
    var selectionResizable = false
    var selectionTextHandles = false
    var isLoading = true
    var imageForObject: (([String: Any]) -> UIImage?)?
    private let metal: NativePDFMetalInk
    private let scene = UIImageView()
    private let decorations = NativePDFViewportDecorations()
    private(set) var renderViewport: NativePDFRenderViewport?
    private var active: UITouch?
    private var startTime: TimeInterval = 0
    private var measured: [NativePDFPoint] = []
    private var predicted: [NativePDFPoint] = []
    private var strokeTool = Tool()
    private var displayLink: CADisplayLink?
    private var needsPreview = false
    private var estimated: [NSNumber: Int] = [:]
    private var completion: Task<Void, Never>?
    private var ending = false
    private struct EstimatedCompletion {
        var stroke: NativePDFCompletedStroke
        var indices: [NSNumber: Int]
        var mapper: InkCoordinateMapper
        var windowToCanvas: CGAffineTransform
    }
    private let estimatedCompletions = NativePDFOrderedCompletions<EstimatedCompletion>()
    private let completionBuffer = NativePDFCompletionBuffer()
    private var journalBlocked = false
    private var submissionTimes: [Double] = []
    private var paper: UIImage?
    private var backdrop: UIImage?
    private var sceneDirty = true

    init?(nativeFrame: CGRect = .zero) {
        guard let renderer = NativePDFMetalInk() else { return nil }
        metal = renderer
        super.init(frame: nativeFrame)
        backgroundColor = .clear; isOpaque = false; isMultipleTouchEnabled = true
        // This full-page view owns touch coordinates only. Keeping all drawing
        // in cropped children avoids a page-sized UIView backing allocation.
        scene.isUserInteractionEnabled = false; scene.accessibilityElementsHidden = true
        scene.contentMode = .scaleToFill
        addSubview(scene); addSubview(metal); addSubview(decorations)
        decorations.drawCanvas = { [weak self] context in self?.drawDecorations(in: context) }
        metal.onSubmission = { [weak self] milliseconds in
            guard let self else { return }
            self.submissionTimes.append(milliseconds)
            if self.submissionTimes.count > 240 { self.submissionTimes.removeFirst(self.submissionTimes.count-240) }
            let sorted = self.submissionTimes.sorted(), index = min(sorted.count-1, Int(Double(sorted.count)*0.95))
            self.onTiming?(sorted[index], sorted.count)
        }
        accessibilityIdentifier = "bandal-native-pdf-ink"
        accessibilityLabel = "PDF 필기 영역"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); onLayout?(); refreshViewport()
    }
    /// Called by PDFKit's host after scrolling, zooming, and window resizing.
    /// Rendering is coalesced to a display frame; input still uses page coords.
    func refreshViewport() {
        let windowBounds = window.map { convert($0.bounds, from: $0) }
        let visible = viewportProvider?() ?? windowBounds ?? .zero
        let origin = convert(CGPoint.zero, to: window)
        let x = convert(CGPoint(x: 1, y: 0), to: window), y = convert(CGPoint(x: 0, y: 1), to: window)
        let transform = CGAffineTransform(a: x.x-origin.x, b: x.y-origin.y, c: y.x-origin.x, d: y.y-origin.y, tx: origin.x, ty: origin.y)
        let viewport = window == nil ? nil : NativePDFRenderViewport(canvasBounds: bounds,
            visibleRect: visible.intersection(windowBounds ?? visible), canvasToWindow: transform, screenScale: window?.screen.scale ?? 1)
        guard renderViewport != viewport else { return }
        renderViewport = viewport
        scene.image = nil; metal.strokes = []; metal.backdrop = nil
        for child in [scene, metal, decorations] as [UIView] { child.isHidden = viewport == nil }
        guard let viewport else {
            paper = nil; backdrop = nil; sceneDirty = true
            metal.drawableSize = CGSize(width: 1, height: 1)
            return
        }
        for child in [scene, metal, decorations] as [UIView] {
            child.frame = viewport.canvasRect; child.contentScaleFactor = viewport.pixelScale
        }
        decorations.canvasOrigin = viewport.canvasRect.origin
        metal.autoResizeDrawable = false; metal.drawableSize = viewport.pixelSize
        invalidateBackdrop(paper: true)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow(); refreshViewport()
        if window == nil { finishMeasuredStroke(); displayLink?.invalidate(); displayLink = nil }
        else if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(renderPreview))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common); displayLink = link
        }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isLoading, !journalBlocked, mapper != nil, !isHidden, bounds.contains(point),
              ["select", "pen", "highlighter", "eraser", "line", "arrow", "rect", "ellipse", "text"].contains(tool.name) else { return nil }
        if event?.allTouches?.contains(where: { $0.type == .pencil }) == true { return self }
        // Fingers still navigate empty paper. Explicit selection/text objects
        // can be manipulated by touch, including their visible resize handles.
        if ["select", "text"].contains(tool.name), let mapper,
           event?.allTouches?.filter({ $0.type == .direct }).count == 1,
           objects.contains(where: { object in
               !["ink", "highlighter"].contains(object["kind"] as? String ?? "") &&
               (NativePDFObjectRenderer.hitBounds(object, mapper: mapper)?.insetBy(dx: -10, dy: -10).contains(point) ?? false)
           }) { return self }
        return nil
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if ending { finishMeasuredStroke() }
        guard !journalBlocked, active == nil, let touch = touches.first(where: { $0.type == .pencil }) ?? touches.first(where: { $0.type == .direct && ["select", "text"].contains(tool.name) }), mapper != nil else { return }
        if tool.name == "highlighter", prepareBackdrop() == nil {
            onFailure?(NativePDFError.invalid("형광펜 배경을 준비하지 못했습니다. 필기를 보존한 채 PDF를 다시 열어 주세요.")); return
        }
        active = touch; startTime = touch.timestamp; strokeTool = tool
        onInputOwnership?(true)
        measured = []; predicted = []; estimated = [:]; ending = false
        append(event?.coalescedTouches(for: touch) ?? [touch]); schedulePreview()
        publishPointer("down", points: Array(measured.prefix(1)))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = active, touches.contains(touch) else { return }
        let start = measured.count
        append(event?.coalescedTouches(for: touch) ?? [touch])
        predicted = (event?.predictedTouches(for: touch) ?? []).compactMap { sample($0) }
        publishPointer("move", points: Array(measured.dropFirst(start)))
        schedulePreview()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = active, touches.contains(touch) else { return }
        append(event?.coalescedTouches(for: touch) ?? [touch]); predicted = []
        // Persist measured points immediately, then accept delayed UIKit
        // corrections independently of the next stroke. No prediction enters
        // this checkpoint; create/receipt only sees the final immutable data.
        if ["pen", "highlighter"].contains(strokeTool.name), !estimated.isEmpty || !estimatedCompletions.isEmpty {
            checkpointEstimatedStroke()
        } else {
            do { try flushActiveStroke() } catch { onFailure?(error) }
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = active, touches.contains(touch) else { return }
        // Only measured points survive interruptions. Predictions are never
        // persisted, nor can another finger terminate a Pencil-owned stroke.
        finishMeasuredStroke(cancelObjectEdit: true)
    }
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let key = touch.estimationUpdateIndex else { continue }
            if let index = estimated[key], measured.indices.contains(index), var corrected = sample(touch), corrected.isValid {
                corrected.t = measured[index].t; measured[index] = corrected
                if touch.estimatedPropertiesExpectingUpdates.isEmpty { estimated.removeValue(forKey: key) }
            }
            for id in estimatedCompletions.ids {
                guard var entry = estimatedCompletions[id], let index = entry.indices[key], entry.stroke.points.indices.contains(index),
                      var corrected = sample(touch, mapper: entry.mapper,
                        location: touch.preciseLocation(in: window).applying(entry.windowToCanvas)), corrected.isValid else { continue }
                corrected.t = entry.stroke.points[index].t
                entry.stroke.points[index] = corrected
                if touch.estimatedPropertiesExpectingUpdates.isEmpty { entry.indices.removeValue(forKey: key) }
                estimatedCompletions[id] = entry
                do {
                    guard let onCheckpoint else { throw NativePDFError.invalid("필기 보정 저장 연결을 확인해 주세요.") }
                    try onCheckpoint(entry.stroke)
                    try drainCorrectedStrokes()
                } catch { journalBlocked = true; onFailure?(error) }
            }
        }
        schedulePreview()
        if ending && estimated.isEmpty { finishMeasuredStroke() }
    }
    private func sample(_ touch: UITouch, mapper override: InkCoordinateMapper? = nil, location: CGPoint? = nil) -> NativePDFPoint? {
        guard let mapper = override ?? mapper else { return nil }
        let force = touch.maximumPossibleForce > 0 ? Double(touch.force / touch.maximumPossibleForce) : 0.5
        let normalized = mapper.normalized(location ?? touch.preciseLocation(in: self), pressure: min(1, max(0, force)))
        let altitude = max(Double(touch.altitudeAngle), 0.001), azimuth = Double(touch.azimuthAngle(in: self))
        return NativePDFPoint(x: min(1, max(0, normalized.x)), y: min(1, max(0, normalized.y)), p: normalized.p,
                              t: max(0, (touch.timestamp - startTime) * 1000),
                              tiltX: atan(cos(azimuth) / tan(altitude)) * 180 / .pi,
                              tiltY: atan(sin(azimuth) / tan(altitude)) * 180 / .pi)
    }
    private func append(_ touches: [UITouch]) {
        metal.receivedAt = CACurrentMediaTime()
        for touch in touches {
            guard let point = sample(touch), point.isValid else { continue }
            if let key = touch.estimationUpdateIndex, let index = estimated[key], measured.indices.contains(index) {
                measured[index] = point
                if touch.estimatedPropertiesExpectingUpdates.isEmpty { estimated.removeValue(forKey: key) }
                continue
            }
            if let previous = measured.last, previous == point { continue }
            measured.append(point)
            if let key = touch.estimationUpdateIndex, !touch.estimatedPropertiesExpectingUpdates.isEmpty { estimated[key] = measured.count - 1 }
        }
    }
    private func schedulePreview() { needsPreview = true }
    private func checkpointEstimatedStroke() {
        guard let mapper, !measured.isEmpty else { finishMeasuredStroke(); return }
        let id = UUID().uuidString
        let origin = convert(CGPoint.zero, from: window), x = convert(CGPoint(x: 1, y: 0), from: window), y = convert(CGPoint(x: 0, y: 1), from: window)
        let stroke = NativePDFCompletedStroke(mutationID: id, kind: strokeTool.name == "pen" ? "ink" : "highlighter", points: measured, style: strokeTool.style)
        let entry = EstimatedCompletion(stroke: stroke, indices: estimated, mapper: mapper,
            windowToCanvas: CGAffineTransform(a: x.x-origin.x, b: x.y-origin.y, c: y.x-origin.x, d: y.y-origin.y, tx: origin.x, ty: origin.y))
        do { try estimatedCompletions.append(entry, id: id) }
        catch { journalBlocked = true; onFailure?(error); return }
        active = nil; measured = []; predicted = []; estimated = [:]; onInputOwnership?(false)
        do {
            guard let onCheckpoint else { throw NativePDFError.invalid("필기 보정 저장 연결을 확인해 주세요.") }
            try onCheckpoint(stroke)
            try drainCorrectedStrokes()
            metal.strokes = []; metal.backdrop = nil
        } catch { journalBlocked = true; onFailure?(error) }
        schedulePreview()
    }
    private func writeEstimatedStroke(_ entry: EstimatedCompletion) throws {
        guard let onStroke else { throw NativePDFError.invalid("필기 저장 연결을 확인해 주세요.") }
        try onStroke(entry.stroke)
    }
    private func drainCorrectedStrokes() throws {
        // A later stroke cannot enter canonical history before an earlier
        // stroke whose measured properties are still being corrected.
        try estimatedCompletions.drain(ready: { $0.indices.isEmpty }, writer: writeEstimatedStroke)
        if estimatedCompletions.isEmpty && completionBuffer.pending == nil { journalBlocked = false }
        schedulePreview()
    }
    @objc private func renderPreview() {
        // Static paper is also cropped, and refreshed at the actual screen
        // density after every viewport change, even when no Pencil is down.
        if sceneDirty || backdrop == nil || scene.image !== backdrop { scene.image = prepareBackdrop() }
        guard needsPreview, let mapper, let viewport = renderViewport else { return }; needsPreview = false
        let pending = completionBuffer.pending ?? (journalBlocked ? estimatedCompletions.first?.stroke : nil)
        let points = pending?.points ?? measured + predicted
        let style = pending?.style ?? strokeTool.style
        let highlighter = pending?.kind == "highlighter" || (pending == nil && strokeTool.name == "highlighter")
        guard !points.isEmpty, pending != nil || ["pen", "highlighter"].contains(strokeTool.name) else { metal.strokes = []; return }
        let polygons = NativePDFInkGeometry.polygons(points: points, width: style.width,
            aspect: mapper.geometry.height / mapper.geometry.width, highlighter: highlighter)
        metal.backdrop = prepareBackdrop()?.cgImage
        metal.strokes = [.init(polygons: polygons.map { $0.map { viewport.localPoint(mapper.canvasPoint(InkPoint(x: $0.x, y: $0.y, p: 0.5))) } },
                               color: Self.color(style.color), opacity: Float(style.opacity), multiply: highlighter)]
    }
    func finishMeasuredStroke(cancelObjectEdit: Bool = false) {
        do { try flush(cancelObjectEdit: cancelObjectEdit) }
        catch { onFailure?(error) }
    }
    func flush(cancelObjectEdit: Bool = false) throws {
        try estimatedCompletions.flush(writeEstimatedStroke)
        try flushActiveStroke(cancelObjectEdit: cancelObjectEdit)
    }
    private func flushActiveStroke(cancelObjectEdit: Bool = false) throws {
        completion?.cancel(); completion = nil; ending = false; estimated = [:]
        if active != nil {
            if ["pen", "highlighter"].contains(strokeTool.name), !measured.isEmpty {
                try completionBuffer.retain(.init(mutationID: UUID().uuidString,
                    kind: strokeTool.name == "pen" ? "ink" : "highlighter", points: measured, style: strokeTool.style))
            } else if let last = measured.last { publishPointer(cancelObjectEdit ? "cancel" : "up", points: [last]) }
            active = nil; predicted = []; measured = []
            onInputOwnership?(false)
        }
        do {
            try completionBuffer.flush { stroke in
                guard let onStroke else { throw NativePDFError.invalid("필기 저장 연결을 확인해 주세요.") }
                try onStroke(stroke)
            }
            journalBlocked = false; metal.strokes = []; metal.backdrop = nil; needsPreview = false
        } catch {
            // Model snapshots cannot unlock this independent durability gate.
            journalBlocked = true; schedulePreview(); throw error
        }
    }
    private func publishPointer(_ phase: String, points: [NativePDFPoint]) {
        guard !["pen", "highlighter"].contains(strokeTool.name), !points.isEmpty else { return }
        onPointer?(["phase": phase, "points": points.map { ["x": $0.x, "y": $0.y, "p": $0.p] }])
    }
    static func color(_ name: String) -> UIColor {
        switch name {
        case "red": UIColor(red: 214/255, green: 36/255, blue: 46/255, alpha: 1)
        case "orange": UIColor(red: 240/255, green: 99/255, blue: 20/255, alpha: 1)
        case "yellow": UIColor(red: 245/255, green: 184/255, blue: 10/255, alpha: 1)
        case "green": UIColor(red: 26/255, green: 148/255, blue: 77/255, alpha: 1)
        case "blue": UIColor(red: 20/255, green: 97/255, blue: 224/255, alpha: 1)
        case "violet": UIColor(red: 125/255, green: 54/255, blue: 209/255, alpha: 1)
        default: UIColor(red: 20/255, green: 23/255, blue: 31/255, alpha: 1)
        }
    }
    func invalidateBackdrop(paper invalidatePaper: Bool = false) {
        if invalidatePaper { paper = nil }
        backdrop = nil; sceneDirty = true; decorations.setNeedsDisplay(); schedulePreview()
    }
    private func prepareBackdrop() -> UIImage? {
        guard let pdfPage, let mapper, let viewport = renderViewport else { return nil }
        if paper == nil {
            paper = NativePDFBackdropRenderer.render(page: pdfPage, mapper: mapper,
                bounds: viewport.canvasRect, scale: viewport.pixelScale)
            sceneDirty = true
        }
        guard let paper else { return nil }
        if sceneDirty || backdrop == nil {
            let format = UIGraphicsImageRendererFormat(); format.scale = paper.scale; format.opaque = true
            backdrop = UIGraphicsImageRenderer(size: viewport.canvasRect.size, format: format).image { renderer in
                paper.draw(in: CGRect(origin: .zero, size: viewport.canvasRect.size))
                renderer.cgContext.translateBy(x: -viewport.canvasRect.minX, y: -viewport.canvasRect.minY)
                drawCommittedObjects(in: renderer.cgContext, mapper: mapper)
            }
            sceneDirty = false
        }
        return backdrop
    }
    private func drawCommittedObjects(in context: CGContext, mapper: InkCoordinateMapper) {
        func point(_ x: Double, _ y: Double) -> CGPoint { mapper.canvasPoint(InkPoint(x: x, y: y, p: 0.5)) }
        for highlight in highlights {
            context.saveGState(); context.setBlendMode(.multiply)
            let rgba = highlight["nativeColor"] as? [Double]
            let fallback: UIColor = highlight["color"] as? String == "pink" ? UIColor(red: 0.99, green: 0.70, blue: 0.84, alpha: 1) : Self.color(highlight["color"] as? String ?? "yellow")
            let color = rgba?.count == 4 && rgba!.allSatisfy({ $0.isFinite && (0...1).contains($0) })
                ? UIColor(red: rgba![0], green: rgba![1], blue: rgba![2], alpha: rgba![3]) : fallback
            let opacity = min(1, max(0, highlight["nativeOpacity"] as? Double ?? 0.42))
            context.setFillColor(color.withAlphaComponent(opacity).cgColor)
            for box in highlight["rects"] as? [[String: Double]] ?? [] {
                let a = point(box["x"] ?? 0, box["y"] ?? 0), b = point((box["x"] ?? 0) + (box["width"] ?? 0), (box["y"] ?? 0) + (box["height"] ?? 0))
                context.fill(CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y)))
            }
            context.restoreGState()
        }
        for object in objects { NativePDFObjectRenderer.draw(object, in: context, mapper: mapper, image: imageForObject?(object)) }
    }
    private func drawDecorations(in context: CGContext) {
        guard let mapper else { return }
        func point(_ x: Double, _ y: Double) -> CGPoint { mapper.canvasPoint(InkPoint(x: x, y: y, p: 0.5)) }
        // The opaque, multiply-correct backdrop covers PDFKit's selection
        // painting. Repaint its exact line bounds above the same PDF pixels.
        context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.24).cgColor)
        for box in selectedTextRects {
            guard let x = box["x"], let y = box["y"], let w = box["width"], let h = box["height"], [x,y,w,h].allSatisfy(\.isFinite) else { continue }
            let a = point(x,y), b = point(x+w,y+h)
            context.fill(CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y)))
        }
        if let box = selectionBox, let x = box["x"], let y = box["y"], let w = box["width"], let h = box["height"], [x,y,w,h].allSatisfy(\.isFinite) {
            let a = point(x,y), b = point(x+w,y+h)
            let frame = CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
            context.setStrokeColor(UIColor.systemBlue.cgColor); context.setLineWidth(1)
            context.stroke(frame)
            if selectionResizable {
                var centers = [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)]
                if selectionTextHandles { centers += [CGPoint(x: frame.minX, y: frame.midY), CGPoint(x: frame.maxX, y: frame.midY)] }
                for center in centers {
                    let handle = CGRect(x: center.x-5, y: center.y-5, width: 10, height: 10)
                    context.setFillColor(UIColor.white.cgColor); context.fill(handle); context.stroke(handle)
                }
            }
        }
    }
    /// The renderer supplies the original shared strokePath for historical ink,
    /// preserving perfect-freehand curves instead of approximating them with a
    /// center line. The supported grammar is deliberately small and numeric.
    static func path(_ string: String, map: (Double, Double) -> CGPoint) -> CGPath? {
        guard string.count <= 8_000_000 else { return nil }
        let pattern = #"[MLQZ]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = string as NSString
        let tokens = regex.matches(in: string, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
        var offset = 0; let path = CGMutablePath()
        func readPoint() -> CGPoint? {
            guard offset + 1 < tokens.count, let x = Double(tokens[offset]), let y = Double(tokens[offset + 1]), x.isFinite, y.isFinite else { return nil }
            offset += 2; return map(x, y)
        }
        while offset < tokens.count {
            let command = tokens[offset]; offset += 1
            switch command {
            case "M": guard let p = readPoint() else { return nil }; path.move(to: p)
            case "L": guard let p = readPoint() else { return nil }; path.addLine(to: p)
            case "Q": guard let control = readPoint(), let end = readPoint() else { return nil }; path.addQuadCurve(to: end, control: control)
            case "Z": path.closeSubpath()
            default: return nil
            }
        }
        return path
    }
}

/// A small transparent backing for selection only, above live Metal. Its bounds
/// never cover more than the visible page crop, and it cannot intercept input.
@MainActor
private final class NativePDFViewportDecorations: UIView {
    var canvasOrigin = CGPoint.zero { didSet { setNeedsDisplay() } }
    var drawCanvas: ((CGContext) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; backgroundColor = .clear
        isUserInteractionEnabled = false; accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.translateBy(x: -canvasOrigin.x, y: -canvasOrigin.y)
        drawCanvas?(context)
    }
}
