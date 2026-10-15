import UIKit

/// Each layer owns one immutable revision. Replacing the layer prevents an old
/// CATiledLayer callback from painting into a newer revision's tile cache.
private final class NativePDFNavigationTileLayer: CATiledLayer {
    let snapshot: NativePDFNavigationSnapshot?
    let beforeDraw: (@Sendable (UInt64) -> Void)?
    init(snapshot: NativePDFNavigationSnapshot, beforeDraw: (@Sendable (UInt64) -> Void)?) {
        self.snapshot = snapshot; self.beforeDraw = beforeDraw; super.init()
        tileSize = CGSize(width: 512, height: 512)
        levelsOfDetail = 6; levelsOfDetailBias = 4
        isOpaque = true
    }
    override init(layer: Any) {
        snapshot = (layer as? NativePDFNavigationTileLayer)?.snapshot
        beforeDraw = (layer as? NativePDFNavigationTileLayer)?.beforeDraw
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override class func fadeDuration() -> CFTimeInterval { 0 }
    override func draw(in context: CGContext) {
        guard let snapshot else { return }
        beforeDraw?(snapshot.revision)
        snapshot.draw(in: context)
    }
}

@MainActor
final class NativePDFNavigationView: UIView {
    private var tiled: NativePDFNavigationTileLayer?
    private let beforeTileDraw: (@Sendable (UInt64) -> Void)?
    private let continuityClip = CALayer()
    private let continuityPixels = CALayer()
    private let continuityVectors = CALayer()
    private struct ContinuityAddition {
        let identifier: String
        let token: NativePDFCommittedVisualToken
        let path: CGPath
        let color: CGColor
        let opacity: CGFloat
        let bounds: CGRect
        let shape: CAShapeLayer
    }
    private struct Continuity {
        let original: UIImage
        let mapper: InkCoordinateMapper
        let viewport: NativePDFRenderViewport
        let identifiers: Set<String>
        var additions: [ContinuityAddition] = []
    }
    private var continuity: Continuity?
    /// The one retained original crop, not a rendered image of vector additions.
    var continuityImage: UIImage? { continuity?.original }
    var continuityAddedObjectCount: Int { continuity?.additions.count ?? 0 }
    var continuityBitmapCount: Int { continuity == nil ? 0 : 1 }
    /// Observation only: tests can render the actual complete subtree outside
    /// product code. No synchronous bitmap/capture method is provided here.
    var continuityLayer: CALayer? { continuity == nil ? nil : continuityClip }
    private(set) var continuityVectorUpdateCount = 0
    private(set) var continuityShapeCreationCount = 0
    private(set) var revision: UInt64?
    override convenience init(frame: CGRect) { self.init(frame: frame, beforeTileDraw: nil) }
    /// The optional observer runs on CATiledLayer's drawing thread. It is used
    /// by tests to hold actual tile painting, never as a pixels-ready signal.
    init(frame: CGRect, beforeTileDraw: (@Sendable (UInt64) -> Void)?) {
        self.beforeTileDraw = beforeTileDraw
        super.init(frame: frame); isOpaque = false; isUserInteractionEnabled = false
        accessibilityElementsHidden = true; clipsToBounds = true
        continuityClip.masksToBounds = true
        continuityPixels.anchorPoint = .zero
        continuityPixels.contentsGravity = .resize
        continuityPixels.isOpaque = true
        // Original pixels and all additions share the original crop footprint.
        // The outer clip separately limits the current viewport after reprojection.
        continuityPixels.masksToBounds = true
        continuityVectors.anchorPoint = .zero
        continuityVectors.position = .zero
        continuityVectors.isOpaque = false
        continuityVectors.masksToBounds = false
        continuityPixels.addSublayer(continuityVectors)
        continuityClip.addSublayer(continuityPixels)
        layer.addSublayer(continuityClip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func install(_ snapshot: NativePDFNavigationSnapshot, mapper: InkCoordinateMapper) {
        // Revisions are local to a builder. Identity also handles replacement
        // builders whose first revision happens to have the same counter.
        if tiled?.snapshot !== snapshot {
            let next = NativePDFNavigationTileLayer(snapshot: snapshot, beforeDraw: beforeTileDraw)
            next.anchorPoint = .zero; next.position = .zero
            next.bounds = CGRect(origin: .zero, size: snapshot.size)
            next.contentsScale = window?.screen.scale ?? 2
            tiled?.removeFromSuperlayer(); layer.addSublayer(next); tiled = next
            revision = snapshot.revision
        }
        let scale = window?.screen.scale ?? 2
        if tiled?.contentsScale != scale { tiled?.contentsScale = scale }
        if let transform = NativePDFObjectRenderer.pageTransform(mapper), tiled?.affineTransform() != transform {
            tiled?.setAffineTransform(transform)
        }
    }
    /// Keep one already-installed opaque crop beneath asynchronous tiles. This
    /// is visual continuity only: it is never an authoritative blend destination
    /// or proof that the replacement tiles contain their final pixels.
    func retainContinuity(_ source: NativePDFRetainedInkBackdrop?, mapper: InkCoordinateMapper,
                          viewport: NativePDFRenderViewport) {
        if continuity == nil, let source {
            continuity = Continuity(original: source.image, mapper: source.mapper,
                viewport: source.viewport, identifiers: source.continuityIdentifiers)
        }
        reprojectContinuity(mapper: mapper, viewport: viewport)
    }

    /// Only ordinary contacts created by this Surface may be added. A backend
    /// undo can assign a new ID to ink already baked into the original crop;
    /// treating every unknown ID as a new pen would blend that ink twice.
    /// Keep one layer per eligible addition in current order. Corrections replace
    /// that layer's immutable path/style, so alpha never accumulates on old pixels.
    func updateContinuity(snapshot: NativePDFNavigationSnapshot, objects: [[String: Any]],
                          tokens: [NativePDFCommittedVisualToken]?, localInkIDs: Set<String>) {
        guard var state = continuity, objects.count == snapshot.objects.count,
              let transform = NativePDFObjectRenderer.pageTransform(state.mapper),
              let metrics = Self.vectorMetrics(transform: transform, imageScale: state.original.scale) else { return }
        let supplied = tokens?.count == objects.count ? tokens : nil
        struct Candidate {
            let identifier: String
            let token: NativePDFCommittedVisualToken
            let path: CGPath
            let color: CGColor
            let opacity: CGFloat
            let bounds: CGRect
        }
        var candidates: [Candidate] = []
        for (index, object) in objects.enumerated() {
            guard object["kind"] as? String == "ink",
                  let id = object["clientMutationId"] as? String ?? object["id"] as? String,
                  localInkIDs.contains(id), !state.identifiers.contains(id),
                  case let .path(path, color, opacity, false) = snapshot.objects[index].content else { continue }
            // Command bounds already come from the immutable prepared path.
            // Add a physical-pixel margin without walking/copying that path.
            let bounds = snapshot.objects[index].bounds.insetBy(dx: -metrics.padding, dy: -metrics.padding)
            guard [bounds.minX, bounds.minY, bounds.width, bounds.height, opacity].allSatisfy(\.isFinite),
                  bounds.width > 0, bounds.height > 0 else { return }
            candidates.append(Candidate(identifier: id,
                token: supplied?[index] ?? NativePDFCommittedVisualToken(object: object),
                path: path, color: color, opacity: opacity, bounds: bounds))
        }
        let unchanged = candidates.count == state.additions.count && zip(candidates, state.additions).allSatisfy { next, old in
            next.identifier == old.identifier && next.token.hasSameAppearance(as: old.token) &&
                next.path === old.path && next.color == old.color && next.opacity == old.opacity && next.bounds == old.bounds
        }
        guard !unchanged else { return }

        // Bucket by ID, retaining duplicate occurrence order exactly as the old
        // bitmap loop did. An unchanged sibling must not be recreated merely
        // because a different contact was corrected, deleted or reordered.
        var previous: [String: [ContinuityAddition]] = [:]
        for addition in state.additions { previous[addition.identifier, default: []].append(addition) }
        var cursors: [String: Int] = [:]
        var additions: [ContinuityAddition] = []
        additions.reserveCapacity(candidates.count)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for next in candidates {
            let cursor = cursors[next.identifier, default: 0]
            let bucket = previous[next.identifier] ?? []
            let old = cursor < bucket.count ? bucket[cursor] : nil
            cursors[next.identifier] = cursor + 1
            let shape: CAShapeLayer
            if let old { shape = old.shape }
            else {
                shape = CAShapeLayer()
                shape.anchorPoint = .zero
                shape.fillRule = .nonZero
                shape.strokeColor = nil
                shape.isOpaque = false
                shape.masksToBounds = false
                shape.allowsGroupOpacity = true
                continuityShapeCreationCount += 1
            }
            if old?.path !== next.path { shape.path = next.path }
            if old?.color != next.color { shape.fillColor = next.color }
            if old?.opacity != next.opacity { shape.opacity = Float(next.opacity) }
            if old?.bounds != next.bounds {
                // Path coordinates remain canonical. position==bounds.origin
                // and anchor zero cancel the tight layer's local origin.
                shape.bounds = next.bounds
                shape.position = next.bounds.origin
            }
            if shape.contentsScale != metrics.scale { shape.contentsScale = metrics.scale }
            additions.append(ContinuityAddition(identifier: next.identifier, token: next.token,
                path: next.path, color: next.color, opacity: next.opacity, bounds: next.bounds, shape: shape))
        }
        let sameOrder = additions.count == state.additions.count &&
            zip(additions, state.additions).allSatisfy { $0.shape === $1.shape }
        if !sameOrder { continuityVectors.sublayers = additions.map(\.shape) }
        state.additions = additions
        continuity = state
        continuityVectorUpdateCount += 1
        CATransaction.commit()
    }

    func reprojectContinuity(mapper: InkCoordinateMapper, viewport: NativePDFRenderViewport) {
        guard let state = continuity else { return }
        // A crop's coordinates are physical PDF coordinates, not normalized
        // display coordinates. Never reinterpret pixels after page geometry changes.
        guard state.mapper.geometry == mapper.geometry else { clearContinuity(); return }
        let transform = state.mapper.canvasToPDF.concatenating(mapper.canvasToPDF.inverted())
        let rect = viewport.canvasRect, sourceRect = state.viewport.canvasRect
        CATransaction.begin(); CATransaction.setDisableActions(true)
        continuityClip.frame = rect
        continuityPixels.bounds = CGRect(origin: .zero, size: sourceRect.size)
        continuityPixels.position = CGPoint(x: sourceRect.origin.applying(transform).x - rect.minX,
                                            y: sourceRect.origin.applying(transform).y - rect.minY)
        continuityPixels.setAffineTransform(CGAffineTransform(a: transform.a, b: transform.b,
            c: transform.c, d: transform.d, tx: 0, ty: 0))
        continuityPixels.contentsScale = state.original.scale
        continuityPixels.contents = state.original.cgImage
        if let canonicalToCanvas = NativePDFObjectRenderer.pageTransform(state.mapper) {
            continuityVectors.bounds = CGRect(x: 0, y: 0, width: state.mapper.geometry.width, height: state.mapper.geometry.height)
            continuityVectors.position = .zero
            // The original CGImage is resized from its ceil-pixel logical
            // extent into the source viewport. Apply the same placement to
            // vector additions. This matches geometry, not the old bitmap's
            // rasterize-then-resample antialiasing; exact pixels remain a gate.
            let imageSize = state.original.size
            let imageToSource = CGAffineTransform(scaleX: sourceRect.width / imageSize.width,
                                                   y: sourceRect.height / imageSize.height)
            continuityVectors.setAffineTransform(canonicalToCanvas.concatenating(
                CGAffineTransform(translationX: -sourceRect.minX, y: -sourceRect.minY))
                .concatenating(imageToSource))
        }
        CATransaction.commit()
    }
    func clearContinuity() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        continuityVectors.sublayers = nil
        continuityVectors.setAffineTransform(.identity)
        continuityVectors.bounds = .zero
        continuityPixels.contents = nil; continuity = nil
        CATransaction.commit()
    }
    func removeSnapshot() {
        tiled?.removeFromSuperlayer(); tiled = nil; revision = nil; clearContinuity()
    }

    /// Source-image density in canonical coordinates. The maximum singular
    /// value avoids undersampling a transformed shape; the minimum gives a
    /// conservative two-physical-pixel AA margin for tight bounds in any axis.
    private static func vectorMetrics(transform: CGAffineTransform, imageScale: CGFloat) -> (scale: CGFloat, padding: CGFloat)? {
        let a = transform.a, b = transform.b, c = transform.c, d = transform.d
        let trace = a*a + b*b + c*c + d*d, determinant = abs(a*d - b*c)
        let maximum = sqrt(max(0, (trace + sqrt(max(0, trace*trace - 4*determinant*determinant))) / 2))
        let minimum = maximum > 0 ? determinant / maximum : 0
        let scale = imageScale * maximum, padding = 2 / (imageScale * minimum)
        guard scale.isFinite, padding.isFinite, scale > 0, padding > 0 else { return nil }
        return (scale, padding)
    }
}

/// At most one immutable crop is being rendered and one latest request waits.
/// A drag cannot enqueue hundreds of obsolete viewport-sized bitmaps.
@MainActor
final class NativePDFNavigationRasterizer {
    struct Request {
        let snapshot: NativePDFNavigationSnapshot
        let bounds: CGRect
        let scale: CGFloat
        let transform: CGAffineTransform
        var stablePrefixCount: Int? = nil
        let completion: (NativePDFNavigationSnapshot.Raster?) -> Void
    }
    private var pending: Request?
    private var running = false
    private var generation: UInt64 = 0
    private(set) var completedCount = 0
    func request(_ request: Request) { pending = request; startNext() }
    func cancel() { generation &+= 1; pending = nil }
    private func startNext() {
        guard !running, let request = pending else { return }
        pending = nil; running = true
        let currentGeneration = generation
        Task { [weak self] in
            let snapshot = request.snapshot, bounds = request.bounds, scale = request.scale, transform = request.transform
            let result = await Task.detached(priority: .userInitiated) {
                autoreleasepool { snapshot.raster(bounds: bounds, scale: scale, canonicalToCanvas: transform, stablePrefixCount: request.stablePrefixCount) }
            }.value
            guard let self else { return }
            self.running = false
            if self.generation == currentGeneration { self.completedCount += 1; request.completion(result) }
            self.startNext()
        }
    }
}
