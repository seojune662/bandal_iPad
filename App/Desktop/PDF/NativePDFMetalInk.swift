import UIKit
import MetalKit

/// Tracks outstanding presentation callbacks without retaining drawables.
final class NativePDFInkDrawableBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt64 = 0
    private var reservations: Set<UInt64> = []
    let capacity: Int
    init(capacity: Int = 2) { self.capacity = max(1, capacity) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reservations.count }
    func acquire() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard reservations.count < capacity else { return nil }
        next &+= 1; reservations.insert(next); return next
    }
    func release(_ reservation: UInt64) {
        lock.lock(); defer { lock.unlock() }; reservations.remove(reservation)
    }
}

/// CAMetalLayer may wait a full second even after a presented callback. Its
/// actual pool is the authority: acquire only on this serial worker, retain at
/// most one ready drawable, and let UIKit consume it without ever waiting.
final class NativePDFInkDrawableMailbox: @unchecked Sendable {
    enum Result: Sendable { case available, stale, unavailable }
    private let acquire: @Sendable (CAMetalLayer) -> CAMetalDrawable?
    init(acquire: @escaping @Sendable (CAMetalLayer) -> CAMetalDrawable? = { $0.nextDrawable() }) {
        self.acquire = acquire
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.bandal.ink.drawable", qos: .userInteractive)
    private var generation: UInt64 = 0
    private var width = 0, height = 0
    private var requesting = false
    private var ready: CAMetalDrawable?
    private var acquisitionMS = 0.0
    var readyCount: Int { lock.lock(); defer { lock.unlock() }; return ready == nil ? 0 : 1 }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requesting ? 1 : 0 }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1; width = 0; height = 0; ready = nil
        // An old blocking acquisition must finish before another is queued.
    }
    private func update(width: Int, height: Int) {
        if self.width != width || self.height != height {
            generation &+= 1; self.width = width; self.height = height; ready = nil
        }
    }
    func take(width: Int, height: Int) -> (CAMetalDrawable, Double)? {
        lock.lock(); defer { lock.unlock() }
        update(width: width, height: height)
        guard let value = ready else { return nil }
        ready = nil
        return (value, acquisitionMS)
    }
    func request(layer: CAMetalLayer, width: Int, height: Int, completion: @escaping @Sendable (Result) -> Void) {
        lock.lock()
        update(width: width, height: height)
        guard width > 0, height > 0, !requesting, ready == nil else { lock.unlock(); return }
        requesting = true
        let requestedGeneration = generation
        lock.unlock()
        let acquire = self.acquire
        queue.async { [weak self, layer] in
            var result = Result.unavailable
            autoreleasepool {
                let start = CACurrentMediaTime(), drawable = acquire(layer)
                let elapsed = (CACurrentMediaTime() - start) * 1000
                guard let self else { return }
                self.lock.lock()
                self.requesting = false
                if self.generation != requestedGeneration { result = .stale }
                else if let drawable, drawable.texture.width == width, drawable.texture.height == height {
                    self.ready = drawable; self.acquisitionMS = elapsed; result = .available
                }
                self.lock.unlock()
            }
            completion(result)
        }
    }
}

/// A transparent, event-free live-ink surface. Each stroke is first rendered
/// with blending disabled into a private texture, then composited once. This
/// preserves highlighter opacity at crossings within the same stroke.
@MainActor
final class NativePDFMetalInk: MTKView, MTKViewDelegate {
    /// The coordinate basis in which this frame's backdrop and local polygons
    /// were encoded. canvasToPage is mapper.canvasToPDF, not normalized ink.
    /// A retained crop may keep this old basis while the page moves underneath.
    struct FrameGeometry: Equatable {
        let canvasRect: CGRect
        let pixelScale: CGFloat
        let canvasToPage: CGAffineTransform
        var pixelSize: CGSize {
            CGSize(width: ceil(canvasRect.width * pixelScale), height: ceil(canvasRect.height * pixelScale))
        }
        init?(canvasRect: CGRect, pixelScale: CGFloat, canvasToPage: CGAffineTransform) {
            guard [canvasRect.minX, canvasRect.minY, canvasRect.width, canvasRect.height, pixelScale].allSatisfy(\.isFinite),
                  canvasRect.width > 0, canvasRect.height > 0, pixelScale > 0,
                  Float(2 / canvasRect.width).isFinite, Float(2 / canvasRect.height).isFinite,
                  Self.valid(canvasToPage) else { return nil }
            let width = ceil(canvasRect.width * pixelScale), height = ceil(canvasRect.height * pixelScale)
            guard width.isFinite, height.isFinite, width >= 1, height >= 1,
                  width <= NativePDFRenderViewport.maximumDimension, height <= NativePDFRenderViewport.maximumDimension,
                  // The viewport caps continuous area before ceil on each
                  // axis. Match the navigation raster's bounded rounding room.
                  width * height <= NativePDFRenderViewport.maximumPixels + 20_000 else { return nil }
            self.canvasRect = canvasRect; self.pixelScale = pixelScale; self.canvasToPage = canvasToPage
        }
        fileprivate static func valid(_ transform: CGAffineTransform) -> Bool {
            let determinant = transform.a * transform.d - transform.b * transform.c
            guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty, determinant].allSatisfy(\.isFinite),
                  determinant != 0 else { return false }
            let inverse = transform.inverted()
            return [inverse.a, inverse.b, inverse.c, inverse.d, inverse.tx, inverse.ty].allSatisfy(\.isFinite)
        }
    }
    private(set) var pendingFrameGeometry: FrameGeometry?
    /// Last successfully submitted geometry, not a physical-display timestamp.
    private(set) var submittedFrameGeometry: FrameGeometry?
    private var presentationCanvasToPage: CGAffineTransform?

    /// Prepare the next drawable size without stretching the front drawable's
    /// bounds or changing its sampling scale. Explicit presentation coordinates
    /// allow old-crop pixels to continue following their original page points.
    @discardableResult
    func stageFrame(_ geometry: FrameGeometry, presentingIn canvasToPage: CGAffineTransform? = nil) -> Bool {
        let destination = canvasToPage ?? geometry.canvasToPage
        guard framePlacement(geometry, presentingIn: destination) != nil,
              submittedFrameGeometry.map({ framePlacement($0, presentingIn: destination) != nil }) ?? true else { return false }
        let previousPixelSize = pendingFrameGeometry?.pixelSize ?? drawableSize
        pendingFrameGeometry = geometry; presentationCanvasToPage = destination
        autoResizeDrawable = false
        if previousPixelSize != geometry.pixelSize {
            // MTKView.drawableSize's setter also rewrites contentScaleFactor
            // from the *old* view bounds. Bypass it while retaining a front
            // frame; requestDrawableIfPossible sets only CAMetalLayer's size.
            drawableMailbox.invalidate()
            scratch = nil; multisampleScratch = nil
        }
        _ = reprojectRetainedFrame(to: destination)
        isHidden = false
        requestDrawableIfPossible()
        return true
    }

    /// Reposition existing pixels by source-canvas -> page -> current-canvas.
    /// This changes only their placement, never their bounds/pixel resolution.
    /// The destination persists for the next submission in the retained basis.
    @discardableResult
    func reprojectRetainedFrame(to canvasToPage: CGAffineTransform) -> Bool {
        guard FrameGeometry.valid(canvasToPage),
              pendingFrameGeometry.map({ framePlacement($0, presentingIn: canvasToPage) != nil }) ?? true,
              submittedFrameGeometry.map({ framePlacement($0, presentingIn: canvasToPage) != nil }) ?? true else { return false }
        presentationCanvasToPage = canvasToPage
        guard let geometry = submittedFrameGeometry else { return false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        positionFrame(geometry, presentingIn: canvasToPage)
        CATransaction.commit()
        return true
    }

    /// Offscreen work cannot retain an idle drawable. The last source basis is
    /// kept so reattachment to the same page can reproject its retained pixels.
    func suspendFrame() {
        isHidden = true; pendingFrameGeometry = nil
        drawableMailbox.invalidate()
        (layer as? CAMetalLayer)?.drawableSize = CGSize(width: 1, height: 1)
        scratch = nil; multisampleScratch = nil
    }

    private func framePlacement(_ geometry: FrameGeometry, presentingIn destination: CGAffineTransform) -> (CGPoint, CGAffineTransform)? {
        guard FrameGeometry.valid(destination) else { return nil }
        let transform = geometry.canvasToPage.concatenating(destination.inverted())
        let position = geometry.canvasRect.origin.applying(transform)
        guard FrameGeometry.valid(transform), position.x.isFinite, position.y.isFinite else { return nil }
        return (position, CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 0, ty: 0))
    }
    private func positionFrame(_ geometry: FrameGeometry, presentingIn destination: CGAffineTransform) {
        guard let (position, transform) = framePlacement(geometry, presentingIn: destination) else { return }
        layer.anchorPoint = .zero
        layer.position = position
        layer.setAffineTransform(transform)
    }
    private func applyFrame(_ geometry: FrameGeometry, presentingIn destination: CGAffineTransform) {
        bounds = CGRect(origin: .zero, size: geometry.canvasRect.size)
        contentScaleFactor = geometry.pixelScale
        positionFrame(geometry, presentingIn: destination)
        submittedFrameGeometry = geometry
    }

    struct Stroke {
        var polygons: [[CGPoint]]
        var color: UIColor
        var opacity: Float
        var multiply = false
        /// Polygon space -> this cropped Metal view's local points. Native
        /// geometry can stay normalized until the GPU vertex stage.
        var transform: CGAffineTransform = .identity
        var retainedPrefixPolygonCount: Int? = nil
        var geometryRevision: UInt64? = nil
    }
    var strokes: [Stroke] = [] { didSet { setNeedsDisplay() } }
    /// nil selects the legacy raster handoff; an empty array is a valid
    /// retained scene, including erasing the last completed stroke.
    var retainedItems: [NativePDFRetainedInkRenderer.Item]? { didSet { setNeedsDisplay() } }
    var retainedBackdropTransform: CGAffineTransform?
    lazy var retainedRenderer: NativePDFRetainedInkRenderer? = device.flatMap { NativePDFRetainedInkRenderer(device: $0) }
    private let retainedLiveVertices = NativePDFInkVertexCache()
    private lazy var retainedLiveBuffers = device.map { NativePDFInkVertexBufferPool(device: $0) }
    private struct PreservedBackdrop {
        let image: CGImage
        let texture: MTLTexture
        let uploadAttemptCount: Int
    }
    // Exactly one ready full-page fallback, alongside the selected crop.
    // Command buffers may separately retain previously submitted textures.
    private var optionalBackdropFallback: PreservedBackdrop?
    private var installingPreparedBackdrop = false
    /// Transparent Metal cannot multiply UIKit layers below it. This bounded
    /// PDF + committed-object raster is rebuilt only when that scene changes.
    var backdrop: CGImage? {
        didSet {
            guard !installingPreparedBackdrop else { return }
            if oldValue === backdrop, backdrop == nil || backdropTexture != nil { return }
            if let image = backdrop, let fallback = optionalBackdropFallback, fallback.image === image {
                // Navigation left the detail crop. Re-select the already-ready
                // base without another allocation/upload, then release crop.
                optionalBackdropFallback = nil
                installPreparedBackdrop(image, texture: fallback.texture, attempts: fallback.uploadAttemptCount)
                return
            }
            if oldValue !== backdrop { optionalBackdropFallback = nil; backdropTexture = nil }
            if backdrop != nil {
                // A failed upload may recover even when the owner assigns the
                // same immutable image. The deadline/cap also applies here.
                _ = prepareBackdropForFrame(required: true)
            } else if backdropUploadErrorDescription == nil {
                // A successful image need not stay retained through a clear.
                // A failed image keeps its one bounded budget across nil ->
                // same-image assignments; clearing must not grant more tries.
                resetBackdropRecovery()
            }
            setNeedsDisplay()
        }
    }
    /// Optional detail cannot invalidate a ready base dependency. Upload into
    /// a temporary texture first; failure preserves all selected/recovery/input
    /// state. The caller bounds retries for an optional image independently.
    /// At rest only the fixed fallback and selected crop textures are retained.
    @discardableResult
    func selectOptionalBackdrop(_ image: CGImage, preserving fallbackImage: CGImage) -> Bool {
        let fallback: PreservedBackdrop
        if let saved = optionalBackdropFallback, saved.image === fallbackImage { fallback = saved }
        else if backdrop === fallbackImage, let texture = backdropTexture {
            fallback = PreservedBackdrop(image: fallbackImage, texture: texture, uploadAttemptCount: backdropUploadAttemptCount)
        } else { return false }
        if backdrop === image, backdropTexture != nil { return true }
        if image === fallbackImage {
            optionalBackdropFallback = nil
            installPreparedBackdrop(image, texture: fallback.texture, attempts: fallback.uploadAttemptCount)
            return true
        }
        guard let device else { return false }
        do {
            let texture = try textureLoader(device, image)
            optionalBackdropFallback = fallback
            installPreparedBackdrop(image, texture: texture, attempts: 1)
            return true
        } catch { return false }
    }
    private func installPreparedBackdrop(_ image: CGImage, texture: MTLTexture, attempts: Int) {
        installingPreparedBackdrop = true
        backdrop = image
        installingPreparedBackdrop = false
        backdropTexture = texture
        backdropRecoveryGeneration &+= 1
        backdropRecoveryImage = image
        backdropUploadAttemptCount = attempts
        backdropRetryAt = nil; backdropUploadErrorDescription = nil
        setNeedsDisplay()
    }
    enum BackdropAvailability: Equatable {
        case notRequired
        case ready
        case waiting(generation: UInt64, retryAt: CFTimeInterval)
        case exhausted(generation: UInt64)
        case missing
    }
    /// Monotonic seconds in the same domain as waiting.retryAt. This clock is
    /// separate from the real input/presentation telemetry clock.
    var backdropRecoveryTime: CFTimeInterval { textureClock() }
    private(set) var backdropRecoveryGeneration: UInt64 = 0
    private(set) var backdropUploadAttemptCount = 0
    private(set) var backdropUploadErrorDescription: String?
    // At most one failed image is retained, including while backdrop == nil.
    private var backdropRecoveryImage: CGImage?
    private var backdropRetryAt: CFTimeInterval?

    /// A new page or an explicit recovery action grants a new upload budget.
    /// This does not upload, submit, alter the front geometry or reset input.
    /// The currently selected backdrop, if any, is prepared by the next call.
    func resetBackdropRecovery() {
        optionalBackdropFallback = nil
        backdropRecoveryGeneration &+= 1
        backdropRecoveryImage = nil; backdropTexture = nil
        backdropUploadAttemptCount = 0; backdropRetryAt = nil
        backdropUploadErrorDescription = nil
    }

    /// Select the dependency from the *next* frame before computing geometry.
    /// One call makes at most one due upload. Failures wait 50 ms, then 200 ms
    /// after the previous failure: at most three attempts for this image.
    @discardableResult
    func prepareBackdropForFrame(required: Bool) -> BackdropAvailability {
        guard required else { return .notRequired }
        guard let backdrop else { return .missing }
        if backdropRecoveryImage !== backdrop {
            resetBackdropRecovery()
            backdropRecoveryImage = backdrop
        }
        if backdropTexture != nil { return .ready }
        guard backdropUploadAttemptCount < 3 else {
            return .exhausted(generation: backdropRecoveryGeneration)
        }
        if let retryAt = backdropRetryAt, textureClock() < retryAt {
            return .waiting(generation: backdropRecoveryGeneration, retryAt: retryAt)
        }
        guard let device else { return .missing }
        backdropUploadAttemptCount += 1
        do {
            backdropTexture = try textureLoader(device, backdrop)
            backdropRetryAt = nil; backdropUploadErrorDescription = nil
            return .ready
        } catch {
            backdropTexture = nil
            backdropUploadErrorDescription = String(describing: error)
            if backdropUploadAttemptCount < 3 {
                let retryAt = textureClock() + (backdropUploadAttemptCount == 1 ? 0.05 : 0.2)
                backdropRetryAt = retryAt
                return .waiting(generation: backdropRecoveryGeneration, retryAt: retryAt)
            }
            backdropRetryAt = nil
            return .exhausted(generation: backdropRecoveryGeneration)
        }
    }
    private var currentFrameRequiresBackdrop: Bool {
        if let retainedItems {
            return backdrop != nil || retainedItems.contains { $0.multiply } || strokes.contains { $0.multiply }
        }
        return !strokes.isEmpty && (backdrop != nil || strokes.contains { $0.multiply })
    }
    private func prepareCurrentFrameBackdrop() -> Bool {
        switch prepareBackdropForFrame(required: currentFrameRequiresBackdrop) {
        case .notRequired, .ready: return true
        case .waiting, .exhausted, .missing: return false
        }
    }
    struct InputTiming: Sendable {
        let strokeID: UInt64
        let firstInputAt: CFTimeInterval
        var latestInputAt: CFTimeInterval
    }
    struct FrameTiming: Sendable {
        let sequence: UInt64
        let strokeID: UInt64
        let firstInputAt: CFTimeInterval
        let latestInputAt: CFTimeInterval
        let drawStartedAt: CFTimeInterval
        let drawableAcquiredAt: CFTimeInterval
        let submittedAt: CFTimeInterval
        var presentedAt: CFTimeInterval?
        var encodedAt: CFTimeInterval? = nil
        var scheduledAt: CFTimeInterval? = nil
        var receiveToSubmitMS: Double { max(0, (submittedAt - firstInputAt) * 1_000) }
        var receiveToPresentMS: Double? { presentedAt.map { max(0, ($0 - firstInputAt) * 1_000) } }
    }
    private(set) var pendingInputTiming: InputTiming?
    private(set) var lastSubmittedFrame: FrameTiming?
    private(set) var lastPresentedFrame: FrameTiming?
    private(set) var submittedFrameCount: UInt64 = 0
    private var latestInputStrokeID: UInt64?
    private var visibleSequenceForCurrentStroke: UInt64 = 0
    private var retriedSequenceForCurrentStroke: UInt64 = 0
    var onFrameSubmitted: ((FrameTiming) -> Void)?
    /// presentedAt is the drawable's display timestamp, not the MainActor
    /// callback delivery time. nil means Metal reported a dropped frame.
    var onFramePresented: ((FrameTiming) -> Void)?
    var onSubmission: ((Double) -> Void)?
    // Transitional compatibility for existing callers. Unlike the former
    // stored property, repeated inputs cannot reset the oldest pending clock.
    var receivedAt: CFTimeInterval? {
        get { pendingInputTiming?.latestInputAt }
        set {
            if let newValue { noteInputReceived(at: newValue, strokeID: 0) }
            else { pendingInputTiming = nil }
        }
    }
    func noteInputReceived(at timestamp: CFTimeInterval, strokeID: UInt64) {
        guard timestamp.isFinite else { return }
        if latestInputStrokeID != strokeID {
            latestInputStrokeID = strokeID
            visibleSequenceForCurrentStroke = 0; retriedSequenceForCurrentStroke = 0
        }
        if var pending = pendingInputTiming, pending.strokeID == strokeID {
            pending.latestInputAt = max(pending.latestInputAt, timestamp)
            pendingInputTiming = pending
        } else {
            pendingInputTiming = InputTiming(strokeID: strokeID, firstInputAt: timestamp, latestInputAt: timestamp)
        }
    }
    /// A committed drawable may be dropped (presentedTime == 0), especially
    /// during initial layer attachment. The owner retries only while the same
    /// contact is active; a late callback must never resurrect an older stroke
    /// or replace the next contact's latency clock.
    @discardableResult
    func retryUnpresentedFrame(_ frame: FrameTiming, forStrokeID strokeID: UInt64) -> Bool {
        guard frame.presentedAt == nil, frame.strokeID == strokeID,
              latestInputStrokeID == strokeID,
              frame.sequence > visibleSequenceForCurrentStroke,
              frame.sequence > retriedSequenceForCurrentStroke,
              frame.firstInputAt.isFinite, frame.latestInputAt.isFinite else { return false }
        if let pending = pendingInputTiming {
            guard pending.strokeID == strokeID else { return false }
            pendingInputTiming = InputTiming(strokeID: strokeID,
                firstInputAt: min(frame.firstInputAt, pending.firstInputAt),
                latestInputAt: max(frame.latestInputAt, pending.latestInputAt))
        } else {
            pendingInputTiming = InputTiming(strokeID: strokeID,
                firstInputAt: frame.firstInputAt, latestInputAt: frame.latestInputAt)
        }
        retriedSequenceForCurrentStroke = frame.sequence
        return true
    }
    /// The surface already owns the UI update schedule. Draw immediately from that
    /// callback instead of scheduling a second UIView invalidation cycle.
    /// false keeps the caller's frame dirty when no drawable was available.
    @discardableResult
    func submitFrame(synchronizedUpdate: (() -> Void)? = nil, reportsInput: Bool = true) -> Bool {
        guard !submittingFrame, window != nil, !isHidden, let size = validDrawableSize else { return false }
        // Do not borrow/discard a drawable or change handoff ownership while
        // the selected destination is unavailable. The old front stays valid.
        guard prepareCurrentFrameBackdrop() else { return false }
        let geometry = pendingFrameGeometry
        let destination = presentationCanvasToPage ?? geometry?.canvasToPage
        submittingFrame = true; pendingSynchronizedUpdate = synchronizedUpdate
        // Geometry must share the drawable's presentation transaction even if
        // the committed UIImage itself does not need changing in this frame.
        presentsWithTransaction = synchronizedUpdate != nil || geometry != submittedFrameGeometry
        defer {
            pendingSynchronizedUpdate = nil; presentsWithTransaction = false; submittingFrame = false
            requestDrawableIfPossible()
        }
        return autoreleasepool {
            lastDrawableAcquisitionMS = 0; lastEncodingMS = 0; lastSchedulingMS = 0
            let start = CACurrentMediaTime()
            guard let ready = drawableMailbox.take(width: size.width, height: size.height) else {
                deferredFrameCount &+= 1; return false
            }
            lastDrawableAcquisitionMS = (CACurrentMediaTime() - start) * 1000
            lastBackgroundDrawableAcquisitionMS = ready.1
            let before = submittedFrameCount
            render(drawable: ready.0, geometry: geometry, presentingIn: destination, reportsInput: reportsInput)
            return submittedFrameCount != before
        }
    }
    private var submittingFrame = false
    private var pendingSynchronizedUpdate: (() -> Void)?
    private let drawableBudget = NativePDFInkDrawableBudget(capacity: Int.max)
    private let drawableMailbox: NativePDFInkDrawableMailbox
    private(set) var deferredFrameCount: UInt64 = 0
    var inFlightDrawableCount: Int { drawableBudget.count }
    var readyDrawableCount: Int { drawableMailbox.readyCount }
    var pendingDrawableRequestCount: Int { drawableMailbox.requestCount }
    private(set) var lastDrawableAcquisitionMS = 0.0
    private(set) var lastEncodingMS = 0.0
    private(set) var lastSchedulingMS = 0.0
    private(set) var lastBackgroundDrawableAcquisitionMS = 0.0
    #if DEBUG
    /// Fault injection for handoff atomicity: unavailable encoders must leave
    /// both the old live drawable and its underlying UIImage unchanged.
    var testingFailNextEncoding = false
    #endif
    private let commands: MTLCommandQueue
    private let fillPipelines: [Int: MTLRenderPipelineState]
    private let compositePipeline: MTLRenderPipelineState
    private let multiplyPipeline: MTLRenderPipelineState
    private let textureLoader: (MTLDevice, CGImage) throws -> MTLTexture
    private let textureClock: () -> CFTimeInterval
    private var backdropTexture: MTLTexture?
    private var scratch: MTLTexture?
    private var multisampleScratch: MTLTexture?
    private(set) var rasterSampleCount = 1
    private var vertexCaches: [NativePDFInkVertexCache] = []
    private var vertexBuffers: [NativePDFInkVertexBufferPool] = []
    private(set) var rebuiltVertexCount = 0
    private(set) var uploadedVertexCount = 0
    private struct InkProjection {
        var x: SIMD4<Float>
        var y: SIMD4<Float>
    }

    init?(renderer: Void = (),
          drawableAcquirer: @escaping @Sendable (CAMetalLayer) -> CAMetalDrawable? = { $0.nextDrawable() },
          textureLoader: ((MTLDevice, CGImage) throws -> MTLTexture)? = nil,
          clock: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
        drawableMailbox = NativePDFInkDrawableMailbox(acquire: drawableAcquirer)
        self.textureLoader = textureLoader ?? { device, image in
            try MTKTextureLoader(device: device).newTexture(cgImage: image,
                options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue])
        }
        textureClock = clock
        guard let gpu = MTLCreateSystemDefaultDevice(), let commands = gpu.makeCommandQueue() else { return nil }
        self.commands = commands
        let source = #"""
        #include <metal_stdlib>
        using namespace metal;
        struct Out { float4 position [[position]]; float2 uv; };
        struct InkProjection { float4 x; float4 y; };
        vertex Out inkVertex(uint i [[vertex_id]], const device float2* points [[buffer(0)]],
                             constant InkProjection& projection [[buffer(1)]]) {
            const float3 point=float3(points[i],1);
            Out o; o.position=float4(dot(projection.x.xyz,point),dot(projection.y.xyz,point),0,1);
            o.uv=float2(0); return o;
        }
        fragment float4 inkColor(constant float4& color [[buffer(0)]]) { return color; }
        vertex Out quadVertex(uint i [[vertex_id]]) {
            const float2 p[6]={float2(-1,1),float2(-1,-1),float2(1,1),float2(1,1),float2(-1,-1),float2(1,-1)};
            Out o; o.position=float4(p[i],0,1); o.uv=float2((p[i].x+1)*.5,(1-p[i].y)*.5); return o;
        }
        fragment float4 composite(Out in [[stage_in]], texture2d<float> ink [[texture(0)]]) {
            constexpr sampler s(coord::normalized,filter::linear,address::clamp_to_edge);
            return ink.sample(s,in.uv);
        }
        """#
        do {
            let library = try gpu.makeLibrary(source: source, options: nil)
            let fill = MTLRenderPipelineDescriptor()
            fill.vertexFunction = library.makeFunction(name: "inkVertex")
            fill.fragmentFunction = library.makeFunction(name: "inkColor")
            fill.colorAttachments[0].pixelFormat = .bgra8Unorm
            fill.colorAttachments[0].isBlendingEnabled = false
            var pipelines: [Int: MTLRenderPipelineState] = [:]
            for samples in [4, 2, 1] where gpu.supportsTextureSampleCount(samples) {
                fill.rasterSampleCount = samples
                if let pipeline = try? gpu.makeRenderPipelineState(descriptor: fill) { pipelines[samples] = pipeline }
            }
            guard pipelines[1] != nil else { return nil }
            fillPipelines = pipelines
            let composition = MTLRenderPipelineDescriptor()
            composition.vertexFunction = library.makeFunction(name: "quadVertex")
            composition.fragmentFunction = library.makeFunction(name: "composite")
            let attachment = composition.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm; attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one; attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one; attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            compositePipeline = try gpu.makeRenderPipelineState(descriptor: composition)
            // alpha * source * destination + (1-alpha) * destination.
            // The union texture prevents extra darkening at self-crossings.
            attachment.sourceRGBBlendFactor = .destinationColor
            multiplyPipeline = try gpu.makeRenderPipelineState(descriptor: composition)
        } catch { return nil }
        super.init(frame: .zero, device: gpu)
        delegate = self; isPaused = true; enableSetNeedsDisplay = false
        framebufferOnly = true; colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
        layer.isOpaque = false
        (layer as? CAMetalLayer)?.maximumDrawableCount = 3
        accessibilityElementsHidden = true
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { drawableMailbox.invalidate() }
        else { requestDrawableIfPossible() }
    }
    override var isHidden: Bool {
        didSet {
            if isHidden { drawableMailbox.invalidate() }
            else { requestDrawableIfPossible() }
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews(); requestDrawableIfPossible()
    }
    private var validDrawableSize: (width: Int, height: Int)? {
        // During staging the UIView still has its old bounds/scale. MetalKit's
        // size bookkeeping must not veto the separately requested new crop.
        let size = pendingFrameGeometry?.pixelSize ?? drawableSize
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width < CGFloat(Int.max), size.height < CGFloat(Int.max) else { return nil }
        return (Int(size.width), Int(size.height))
    }
    private func requestDrawableIfPossible() {
        guard window != nil, !isHidden, let size = validDrawableSize,
              let metalLayer = layer as? CAMetalLayer else { return }
        // MetalKit normally propagates a manual drawableSize during draw().
        // We bypass draw() to avoid its synchronous drawable acquisition, so
        // explicitly update the backing layer before the worker asks for one.
        let pixelSize = CGSize(width: size.width, height: size.height)
        if metalLayer.drawableSize != pixelSize { metalLayer.drawableSize = pixelSize }
        drawableMailbox.request(layer: metalLayer, width: size.width, height: size.height) { [weak self] result in
            // Only a superseded size needs an immediate replacement. A nil
            // result waits for the next requested UI frame, avoiding an idle
            // retry loop when the layer cannot allocate a drawable.
            guard case .stale = result else { return }
            Task { @MainActor [weak self] in self?.requestDrawableIfPossible() }
        }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        scratch = nil; multisampleScratch = nil
        drawableMailbox.invalidate()
    }
    func draw(in view: MTKView) {
        _ = submitFrame()
    }
    private func render(drawable: CAMetalDrawable, geometry: FrameGeometry?, presentingIn destination: CGAffineTransform?, reportsInput: Bool) {
        guard let reservation = drawableBudget.acquire() else { return }
        let budget = drawableBudget
        var presentationRequested = false
        defer { if !presentationRequested { budget.release(reservation) } }
        let synchronizedUpdate = pendingSynchronizedUpdate
        let synchronizePresentation = presentsWithTransaction
        if synchronizePresentation { CATransaction.begin(); CATransaction.setDisableActions(true) }
        defer { if synchronizePresentation { CATransaction.commit() } }
        let drawStartedAt = CACurrentMediaTime()
        let drawableAcquiredAt = CACurrentMediaTime()
        guard let command = commands.makeCommandBuffer() else { return }
        let logicalSize = geometry?.canvasRect.size ?? CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
        let encoded = encode(into: drawable.texture, command: command, logicalSize: logicalSize)
        let encodedAt = CACurrentMediaTime()
        lastEncodingMS = (encodedAt - drawableAcquiredAt) * 1000
        guard let containsInk = encoded else { return }
        // A failed GPU command need not produce a drawable presentation. A
        // duplicate release from its later skipped callback is harmless.
        command.addCompletedHandler { completed in
            #if targetEnvironment(simulator)
            // Simulator can retire bookkeeping at GPU completion but cannot
            // report a display timestamp. Drawable availability is determined
            // independently by the background mailbox.
            Task { @MainActor in budget.release(reservation) }
            #else
            if completed.status == .error {
                Task { @MainActor in budget.release(reservation) }
            }
            #endif
        }
        var scheduledAt: CFTimeInterval?
        if synchronizePresentation {
            let schedulingStartedAt = CACurrentMediaTime()
            command.commit(); command.waitUntilScheduled()
            scheduledAt = CACurrentMediaTime()
            lastSchedulingMS = (scheduledAt! - schedulingStartedAt) * 1000
            guard command.status != .error else { return }
        }
        // A retained crop may encode only completed ink while the current
        // contact lies outside its coverage. Keep that contact's oldest clock
        // until the owner confirms this frame contains its visible geometry.
        let timing = (containsInk || retainedItems != nil) && reportsInput ? pendingInputTiming.map { input in
            FrameTiming(sequence: submittedFrameCount + 1, strokeID: input.strokeID,
                firstInputAt: input.firstInputAt, latestInputAt: input.latestInputAt,
                drawStartedAt: drawStartedAt, drawableAcquiredAt: drawableAcquiredAt,
                submittedAt: CACurrentMediaTime(), presentedAt: nil,
                encodedAt: encodedAt, scheduledAt: scheduledAt)
        } : nil
        #if !targetEnvironment(simulator)
        // Simulator Metal has no drawable presentation timestamp API. Its
        // command completion is not evidence that pixels reached a display.
        // These callbacks update telemetry only. They cannot predict pool
        // availability; all drawable acquisition stays on the worker.
        drawable.addPresentedHandler { [weak self] displayed in
            let completed = timing.map { timing in
                var presentation = timing
                let displayedAt = displayed.presentedTime
                presentation.presentedAt = displayedAt > 0 ? displayedAt : nil
                return presentation
            }
            Task { @MainActor [weak self] in
                budget.release(reservation)
                guard let self, let completed else { return }
                if completed.presentedAt != nil, completed.strokeID == self.latestInputStrokeID {
                    self.visibleSequenceForCurrentStroke = max(self.visibleSequenceForCurrentStroke, completed.sequence)
                }
                if completed.sequence >= (self.lastPresentedFrame?.sequence ?? 0) {
                    self.lastPresentedFrame = completed
                }
                self.onFramePresented?(completed)
            }
        }
        #endif
        if synchronizePresentation {
            // CAMetalLayer's public transaction mode requires direct drawable
            // presentation AFTER scheduling; command.present() would bypass
            // the transaction shared with the completed-ink UIImage update.
            drawable.present()
            if let geometry, let destination { applyFrame(geometry, presentingIn: destination) }
            synchronizedUpdate?()
        } else {
            command.present(drawable); command.commit()
        }
        presentationRequested = true
        submittedFrameCount += 1
        if let timing {
            pendingInputTiming = nil
            lastSubmittedFrame = timing
            onFrameSubmitted?(timing)
            onSubmission?(timing.receiveToSubmitMS)
        }
    }
    /// nil means encoding failed: never present a partial frame or run the
    /// synchronized image update. false is a successfully encoded clear;
    /// true means nonempty ink reached the complete compositing pipeline.
    @discardableResult
    private func encode(into target: MTLTexture, command: MTLCommandBuffer, logicalSize: CGSize) -> Bool? {
        // Offscreen readback uses this encoder directly, so it must obey the
        // same fail-closed blend contract as displayed-frame submission.
        guard prepareCurrentFrameBackdrop() else { return nil }
        #if DEBUG
        if testingFailNextEncoding { testingFailNextEncoding = false; return nil }
        #endif
        guard let gpu = device else { return nil }
        rebuiltVertexCount = 0; uploadedVertexCount = 0
        if let retainedItems {
            guard let retainedRenderer else { return nil }
            var items = retainedItems
            var liveLease: NativePDFInkVertexBufferPool.Lease?
            defer { if let liveLease { retainedLiveBuffers?.release(liveLease) } }
            // The live stroke shares the completed strokes' stencil/MSAA pass.
            // Only its changed suffix is uploaded into a leased buffer.
            guard strokes.count <= 1 else { return nil }
            if let stroke = strokes.first, !stroke.polygons.isEmpty {
                let first = retainedLiveVertices.update(stroke.polygons,
                    retainedPrefix: stroke.retainedPrefixPolygonCount, revision: stroke.geometryRevision)
                rebuiltVertexCount = retainedLiveVertices.rebuiltVertexCount
                guard let pool = retainedLiveBuffers else { return nil }
                pool.invalidate(from: first)
                guard let lease = pool.acquire(vertices: retainedLiveVertices.vertices) else { return nil }
                liveLease = lease; uploadedVertexCount = pool.uploadedVertexCount
                let bounds = retainedLiveVertices.bounds
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                guard stroke.color.getRed(&r, green: &g, blue: &b, alpha: &a), !bounds.isNull else { return nil }
                let alpha = Float(a) * stroke.opacity
                items.append(.init(mesh: .init(buffer: lease.buffer, vertexCount: retainedLiveVertices.vertices.count, bounds: bounds),
                    color: SIMD4(Float(r)*alpha, Float(g)*alpha, Float(b)*alpha, alpha), transform: stroke.transform, multiply: stroke.multiply))
            }
            guard retainedRenderer.encode(items: items, backdrop: backdropTexture, into: target,
                command: command, logicalSize: logicalSize, backdropTransform: retainedBackdropTransform) else { return nil }
            if let lease = liveLease, let pool = retainedLiveBuffers {
                command.addCompletedHandler { _ in pool.release(lease) }
                liveLease = nil
            }
            return !items.isEmpty
        }
        var leases: [(NativePDFInkVertexBufferPool, NativePDFInkVertexBufferPool.Lease)] = []
        var completedEncoding = false
        defer {
            // An encoder/allocation failure discards the uncommitted command.
            // Release immediately rather than waiting for an impossible GPU
            // completion, so fault recovery cannot exhaust the bounded pool.
            if !completedEncoding { for (pool, lease) in leases { pool.release(lease) } }
        }
        let width = target.width, height = target.height
        if scratch?.width != width || scratch?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .private
            scratch = gpu.makeTexture(descriptor: descriptor)
            multisampleScratch = nil; rasterSampleCount = 1
            // Rasterize the union per sample, then resolve exactly once. A
            // separate AA pass per polygon would repeatedly blend overlaps
            // and make translucent ink darker at joins/self-crossings.
            // Memoryless MSAA stays in the iPad GPU's tile memory; the resolved
            // single-sample texture is the only persistent ink allocation.
            for samples in [4, 2] where fillPipelines[samples] != nil {
                let multisample = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                multisample.textureType = .type2DMultisample; multisample.sampleCount = samples
                multisample.usage = [.renderTarget]; multisample.storageMode = .memoryless
                if let texture = gpu.makeTexture(descriptor: multisample) {
                    multisampleScratch = texture; rasterSampleCount = samples; break
                }
            }
        }
        guard let scratch, let fillPipeline = fillPipelines[rasterSampleCount] else { return nil }
        var first = true, containsInk = false
        if !strokes.isEmpty, let backdropTexture {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = clearColor
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            encoder.setRenderPipelineState(compositePipeline); encoder.setFragmentTexture(backdropTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding(); first = false
        }
        for (index, stroke) in strokes.enumerated() {
            if index == vertexCaches.count {
                vertexCaches.append(NativePDFInkVertexCache())
                vertexBuffers.append(NativePDFInkVertexBufferPool(device: gpu))
            }
            let mesh = vertexCaches[index], pool = vertexBuffers[index]
            let firstChanged = mesh.update(stroke.polygons, retainedPrefix: stroke.retainedPrefixPolygonCount,
                                           revision: stroke.geometryRevision)
            rebuiltVertexCount += mesh.rebuiltVertexCount
            pool.invalidate(from: firstChanged)
            if mesh.vertices.isEmpty { continue }
            guard let lease = pool.acquire(vertices: mesh.vertices) else { return nil }
            leases.append((pool, lease)); uploadedVertexCount += pool.uploadedVertexCount
            let union = MTLRenderPassDescriptor()
            union.colorAttachments[0].texture = multisampleScratch ?? scratch
            union.colorAttachments[0].loadAction = .clear
            union.colorAttachments[0].clearColor = clearColor
            if multisampleScratch != nil {
                union.colorAttachments[0].resolveTexture = scratch
                union.colorAttachments[0].storeAction = .multisampleResolve
            } else {
                union.colorAttachments[0].storeAction = .store
            }
            guard let encoder = command.makeRenderCommandEncoder(descriptor: union) else { return nil }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            stroke.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let alpha = stroke.opacity * Float(a)
            var color = SIMD4(Float(r) * alpha, Float(g) * alpha, Float(b) * alpha, alpha)
            // Compose the affine and viewport projection once per stroke,
            // not for every point of every triangle on the CPU.
            let affine = stroke.transform, sx = 2 / max(logicalSize.width, .leastNonzeroMagnitude), sy = -2 / max(logicalSize.height, .leastNonzeroMagnitude)
            var projection = InkProjection(
                x: SIMD4(Float(affine.a * sx), Float(affine.c * sx), Float(affine.tx * sx - 1), 0),
                y: SIMD4(Float(affine.b * sy), Float(affine.d * sy), Float(affine.ty * sy + 1), 0))
            encoder.setRenderPipelineState(fillPipeline)
            encoder.setVertexBuffer(lease.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&projection, length: MemoryLayout<InkProjection>.stride, index: 1)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertices.count)
            encoder.endEncoding()
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = first ? .clear : .load
            pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor = clearColor
            guard let composite = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            composite.setRenderPipelineState(stroke.multiply ? multiplyPipeline : compositePipeline)
            composite.setFragmentTexture(scratch, index: 0)
            composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            composite.endEncoding(); first = false; containsInk = true
        }
        if first {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor = clearColor
            guard let clear = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            clear.endEncoding()
        }
        // The completion callback only returns storage to the pool; it never
        // blocks the main actor or rewrites a buffer still used by the GPU.
        for (pool, lease) in leases { command.addCompletedHandler { _ in pool.release(lease) } }
        completedEncoding = true
        return containsInk
    }

    /// Same GPU encoders as a displayed frame, with deterministic readback for
    /// checking blend modes and union opacity without screenshot conversions.
    func renderedPixels(width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, width <= 4096, height <= 4096, let device,
              let command = commands.makeCommandBuffer() else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]; descriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: descriptor) else { return nil }
        let logicalSize = pendingFrameGeometry?.canvasRect.size ?? CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
        guard encode(into: output, command: command, logicalSize: logicalSize) != nil else { return nil }
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { output.getBytes(base, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        }
        return bytes
    }
}
