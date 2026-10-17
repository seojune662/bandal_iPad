import UIKit
import PDFKit

struct NativePDFInkFrameStatistics {
    var receiveToPresentP95MS = 0.0
    var firstPresentationP95MS = 0.0
    var framesBeforeLift = 0
    var strokesBeforeLift = 0
    var strokesAfterLift = 0
    var samples = 0
}

/// ObjectIdentifier is only valid while its object is alive. Own each pending
/// token and its immutable path until the current navigation suffix retires it.
@MainActor
struct NativePDFNavigationGeometryCache {
    private struct Entry {
        let token: NativePDFCommittedVisualToken
        let path: CGPath
        let size: CGSize
        let polygons: [[CGPoint]]
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    var count: Int { entries.count }

    mutating func polygons(token: NativePDFCommittedVisualToken?, path: CGPath, size: CGSize) -> [[CGPoint]] {
        if let token, let entry = entries[ObjectIdentifier(token)],
           entry.token === token, entry.path === path, entry.size == size {
            return entry.polygons
        }
        var output: [[CGPoint]] = [], contour: [CGPoint] = []
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint:
                if !contour.isEmpty { output.append(contour) }; contour = []
                fallthrough
            case .addLineToPoint:
                let p = element.pointee.points[0]
                contour.append(CGPoint(x: p.x / size.width, y: p.y / size.height))
            case .closeSubpath:
                if !contour.isEmpty { output.append(contour); contour = [] }
            default: break
            }
        }
        if !contour.isEmpty { output.append(contour) }
        if let token {
            entries[ObjectIdentifier(token)] = Entry(token: token, path: path, size: size, polygons: output)
        }
        return output
    }
    mutating func retainOnly(_ identities: Set<ObjectIdentifier>) {
        if entries.count == identities.count, entries.keys.allSatisfy(identities.contains) { return }
        entries = entries.filter { identities.contains($0.key) }
    }
    mutating func removeAll() { entries.removeAll() }
}

@MainActor
final class NativePDFInkSurface: UIView, UIScribbleInteractionDelegate {
    struct Tool: Equatable {
        var name = "select"
        var drawAndHold = false
        var style = NativePDFInkStyle(color: "ink", width: 0.003, opacity: 1)
        var lassoBox = false
    }
    var tool = Tool() { didSet { if tool != oldValue { finishMeasuredStroke(); reviewBackdropDependency() } } }
    var retainedInkEnabled = false { didSet { if oldValue != retainedInkEnabled { retainedModelDirty = true; schedulePreview() } } }
    var nativeErasingEnabled = false
    var onEraseBegin: (() -> Void)?
    var onErase: (([NativePDFEraseTarget]) throws -> Void)?
    var erasedIdentifiers: [String] = [] { didSet {
        // A raster image captured before this erase would resurrect the strokes.
        if retainedInkActive, erasedIdentifiers != oldValue { scene.image = nil; scene.isHidden = true }
        schedulePreview()
    } }
    private lazy var retainedModel: NativePDFRetainedMixedScene? = {
        guard let renderer = metal.retainedRenderer else { return nil }
        let textures = NativePDFRetainedObjectTextures(renderer: renderer, rasterize: retainedObjectRasterize)
        let model = NativePDFRetainedMixedScene(renderer: renderer, textures: textures)
        model.onResourcesChanged = { [weak self] in
            guard let self else { return }
            self.retainedModelDirty = true; self.sceneDirty = true; self.reviewBackdropDependency()
        }
        return model
    }()
    private let retainedObjectRasterize: NativePDFRetainedObjectTextures.Rasterizer?
    private var retainedObjectScale: CGFloat = 0
    private let retainedPaper = NativePDFRetainedPaper()
    private let retainedPaperCrop: NativePDFRetainedPaperCrop
    private var failedRetainedPaperCropImage: CGImage?
    private var retainedPaperCropActive = false
    private var retainedModelDirty = true
    private var applyingObjects = false
    private var retainedInkActive = false
    private var retainedInstallCount = 0
    private var nativeEraseContact = false
    private var erasingTargets: [NativePDFEraseTarget] = []
    private var erasingKeys = Set<Data>()
    private var eraserPreviousPoint: CGPoint?
    var mapper: InkCoordinateMapper? { didSet {
        if let before = oldValue, let after = mapper,
           NativePDFCoordinateMapping.isPixelEquivalent(before, after, bounds: bounds,
               pixelScale: coordinateComparisonPixelScale) {
            mapper = before
            return
        }
        if oldValue?.canvasToPDF != mapper?.canvasToPDF || oldValue?.geometry != mapper?.geometry {
            if oldValue?.geometry != mapper?.geometry { retainedModelDirty = true }
            cancelBackdropWake(invalidateEpoch: true)
            progressiveErasureActive = false; progressiveErasurePending = nil
            backdropDependencyNeedsReview = true
            mapperInvalidationCount += 1
            if let before = oldValue, let after = mapper,
               mapperInvalidationCount <= 12 || mapperInvalidationCount.isMultiple(of: 50) {
                func values(_ t: CGAffineTransform) -> String {
                    [t.a,t.b,t.c,t.d,t.tx,t.ty].map { String(format: "%.17g",$0) }.joined(separator: ",")
                }
                onDiagnostic?("mapper.changed.\(mapperInvalidationCount).from[\(values(before.canvasToPDF))].to[\(values(after.canvasToPDF))].bounds[\(bounds.width),\(bounds.height)].geometry[\(before.geometry.width),\(before.geometry.height):\(after.geometry.width),\(after.geometry.height)]")
            }
            // A genuine page-coordinate change must follow the same asynchronous
            // handoff as navigation, even if its visible crop stayed unchanged.
            // Otherwise a layout callback can replay the entire scene on main.
            let requiresHandoff = !retainedInkActive && oldValue != nil && mapper != nil && renderViewport != nil && window != nil
            if requiresHandoff {
                navigationDisplayActive = true
                navigationCropTask?.cancel(); navigationCropTask = nil; navigationRasterizer.cancel()
                if let viewport = renderViewport, let mapper {
                    navigationView.retainContinuity(retainedNavigationBackdrop, mapper: mapper, viewport: viewport)
                }
                scene.isHidden = true; navigationView.isHidden = false
                metal.strokes = []; metal.backdrop = nil
                if let mapper { _ = metal.reprojectRetainedFrame(to: mapper.canvasToPDF) }
            }
            invalidateBackdrop(paper: true, reason: "mapper")
            if requiresHandoff, let mapper {
                updateNavigationSnapshot()
                if let base = navigationBaseSnapshot { navigationView.install(base, mapper: mapper) }
                requestNavigationCrop()
            }
        }
        decorations.setNeedsDisplay(); schedulePreview()
    } }
    private var coordinateComparisonPixelScale: CGFloat {
        guard let window, let transform = NativePDFCoordinateMapping.sample(bounds: bounds,
            convert: { self.convert($0, to: window) }) else { return window?.screen.scale ?? 1 }
        // Frobenius norm bounds the largest singular value, including skew.
        // Use the physical screen scale, even when our crop raster is capped.
        return sqrt(transform.a*transform.a + transform.b*transform.b + transform.c*transform.c + transform.d*transform.d)
            * window.screen.scale
    }
    var pdfPage: PDFPage? { didSet { if oldValue !== pdfPage {
        retainedPaper.reset(); retainedPaperCrop.reset(); failedRetainedPaperCropImage = nil
        retainedPaperCropActive = false; retainedModelDirty = true
        retainedModel?.reset(); retainedObjectScale = 0; retainedInkActive = false
        cancelBackdropWake(invalidateEpoch: true)
        metal.resetBackdropRecovery()
        backdropAvailability = .notRequired; reportedBackdropFailure = nil
        backdropDependencyNeedsReview = true
        asynchronousEditDisplayActive = false
        progressiveErasureActive = false; progressiveErasurePending = nil
        retainedNavigationBackdrop = nil
        continuityLocalInkIDs.removeAll(); navigationView.removeSnapshot()
        navigationBuilder.invalidate(); navigationSnapshot = nil; navigationBaseSnapshot = nil
        navigationPendingGeometry.removeAll()
        invalidateBackdrop(paper: true, reason: "page")
    } } }
    /// A native whiteboard supplies its own paper bitmap. No PDF file or page
    /// is created; multiply ink still receives the correct opaque destination.
    var canvasPaperImage: CGImage? { didSet {
        guard oldValue !== canvasPaperImage else { return }
        cancelBackdropWake(invalidateEpoch: true); backdropDependencyNeedsReview = true
        sceneDirty = true; schedulePreview()
    } }
    var onStroke: ((NativePDFCompletedStroke) throws -> Void)?
    /// Fit locally while contact is still down. The bridge is involved only
    /// after durable completion, so a busy web view cannot delay the preview.
    static let holdSnapDelay: TimeInterval = 0.55
    static let holdSnapRadius: Double = 3 // screen points, stable across PDF zoom
    private var holdTimer: Timer?
    private var holdAnchor: NativePDFPoint?
    private(set) var heldShape: NativePDFHeldShape?
    private var holdSnap: Bool { heldShape != nil }
    private func updateHoldSnap(from start: Int) {
        guard strokeTool.drawAndHold, ["pen", "highlighter"].contains(strokeTool.name), let mapper else { return }
        func screenPoint(_ point: NativePDFPoint) -> CGPoint {
            let local = mapper.canvasPoint(InkPoint(x: point.x, y: point.y, p: point.p))
            return window.map { convert(local, to: $0) } ?? local
        }
        var moved = holdAnchor == nil
        for point in measured.dropFirst(start) {
            if let anchor = holdAnchor {
                let a = screenPoint(anchor), b = screenPoint(point)
                if hypot(a.x - b.x, a.y - b.y) <= Self.holdSnapRadius { continue }
            }
            holdAnchor = point; moved = true
        }
        guard moved else { return }
        if heldShape != nil { heldShape = nil; previewGeometry.reset() }
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: Self.holdSnapDelay, repeats: false) { [weak self] _ in
            // This timer is installed exclusively on RunLoop.main below.
            MainActor.assumeIsolated {
                guard let self, self.active != nil, self.strokeTool.drawAndHold,
                      let currentMapper = self.mapper else { return }
                guard let fit = NativePDFShapeRecognition.recognize(self.measured,
                    aspect: currentMapper.geometry.height / currentMapper.geometry.width) else {
                    self.onDiagnostic?("shape.hold.unrecognized.samples.\(self.measured.count)")
                    return
                }
                self.heldShape = fit; self.predicted = []; self.previewGeometry.reset()
                self.schedulePreview(); self.renderPreview()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self.onDiagnostic?("shape.hold.preview.\(fit.kind)")
            }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func resetHoldSnap() {
        holdTimer?.invalidate(); holdTimer = nil; holdAnchor = nil; heldShape = nil
        previewGeometry.reset()
    }
    private func previewPoints(_ pending: NativePDFCompletedStroke?) -> [NativePDFPoint] {
        if let pending { return pending.heldShape?.points ?? pending.points }
        return active != nil ? heldShape?.points ?? measured : measured
    }
    private func previewShape(_ pending: NativePDFCompletedStroke?) -> NativePDFHeldShape? {
        if let pending { return pending.heldShape }
        return active != nil ? heldShape : nil
    }
    private var previewPredictions: [NativePDFPoint] { heldShape == nil ? predicted : [] }
    var onCheckpoint: ((NativePDFCompletedStroke) throws -> Void)?
    var onFailure: ((Error) -> Void)?
    var onInteraction: ((String, [String: Any]) -> Void)?
    var onPointer: (([String: Any]) -> Void)?
    var onInputOwnership: ((Bool) -> Void)?
    var onLayout: (() -> Void)?
    var viewportProvider: (() -> CGRect?)?
    var navigationInProgress: (() -> Bool)?
    /// True while a pinch is live. Every frame then changes the pixel scale;
    /// restaging the drawable per frame only produces deferred submissions, so
    /// the reprojected frame is kept and one render follows `finishLiveZoom`.
    var liveZoom: (() -> Bool)?
    private var zoomDeferred = false
    func finishLiveZoom() {
        guard zoomDeferred else { return }
        zoomDeferred = false; sceneDirty = true; schedulePreview()
    }
    var onNavigationStateChanged: (() -> Void)?
    var onSceneInstalled: (() -> Void)?
    var onTiming: ((Double, Int) -> Void)?
    var onPresentation: ((NativePDFInkFrameStatistics) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var objects: [[String: Any]] = [] { didSet {
        objectVisualTokens = nil
        invalidateObjectScene()
    } }
    private(set) var objectVisualTokens: [NativePDFCommittedVisualToken]?
    /// Called only with rows and tokens maintained together by the native
    /// store. Ordinary dictionary assignments invalidate that trusted link.
    func applyObjects(objects: [[String: Any]], visualTokens: [NativePDFCommittedVisualToken]) {
        applyingObjects = true
        self.objects = objects
        objectVisualTokens = visualTokens.count == objects.count ? visualTokens : nil
        applyingObjects = false
        scheduleNavigationSnapshot()
    }
    var highlights: [[String: Any]] = [] { didSet { invalidateObjectScene() } }
    var selectionBox: [String: Double]? { didSet { decorations.setNeedsDisplay() } }
    /// The live text box being edited on this page. The host owns the view
    /// (a sibling above the PDF view, so it stays reachable by accessibility);
    /// this overlay only maps `pageBox` into its frame on every layout pass.
    var textEditor: NativePDFTextInputView? { didSet {
        guard textEditor !== oldValue else { return }
        setNeedsLayout(); decorations.setNeedsDisplay()
    } }
    private var textEditorLocalFrame: CGRect? {
        guard let editor = textEditor, !editor.isHidden, let host = editor.superview else { return nil }
        return convert(editor.frame, from: host)
    }
    static func textEditorFrame(box: CGRect, mapper: InkCoordinateMapper) -> CGRect {
        let a = mapper.canvasPoint(InkPoint(x: box.minX, y: box.minY, p: 0.5)), b = mapper.canvasPoint(InkPoint(x: box.maxX, y: box.maxY, p: 0.5))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
    private func layoutTextEditor() {
        guard let editor = textEditor, let host = editor.superview else { return }
        guard let mapper, let box = editor.pageBox, renderViewport != nil, window != nil else { editor.isHidden = true; return }
        let frame = convert(Self.textEditorFrame(box: box, mapper: mapper).insetBy(dx: 0, dy: -1), to: host)
        editor.isHidden = false
        if editor.frame != frame { editor.frame = frame; decorations.setNeedsDisplay() }
    }
    var selectedTextRects: [[String: Double]] = [] { didSet { decorations.setNeedsDisplay() } }
    var selectionResizable = false
    var selectionTextHandles = false
    var isLoading = true
    var imageForObject: (([String: Any]) -> UIImage?)?
    private let metal: NativePDFMetalInk
    private let scene = UIImageView()
    private let navigationView: NativePDFNavigationView
    private let navigationBuilder = NativePDFNavigationSnapshotBuilder()
    private let navigationRasterizer = NativePDFNavigationRasterizer()
    private var navigationSnapshot: NativePDFNavigationSnapshot?
    private var navigationBaseSnapshot: NativePDFNavigationSnapshot?
    private var navigationBaseTokens: [NativePDFCommittedVisualToken]?
    private var navigationSnapshotDirty = true
    private var navigationGeneration: UInt64 = 0
    private var navigationDisplayActive = false
    // A settled destructive edit cannot reuse its old opaque prefix. Its new
    // immutable tile revision is installed with a replacing Metal frame; only
    // the expensive exact crop waits for the existing bounded worker.
    private var asynchronousEditDisplayActive = false
    private var asynchronousEditTileInstallCount = 0
    // Stationary erasing advances only through complete opaque crops. A
    // pending worker result is display-only until a successful Metal clear;
    // it must never become the authoritative current cache by implication.
    private var progressiveErasureActive = false
    private var progressiveErasurePending: NativePDFRetainedInkBackdrop?
    private var progressiveErasureInstallCount = 0
    private let suppliedNavigationRasterRequest: ((NativePDFNavigationRasterizer.Request) -> Void)?
    private var navigationCaptureTask: Task<Void, Never>?
    private var navigationCropTask: Task<Void, Never>?
    private var navigationRefreshMaxCPUMS = 0.0
    private var navigationRefreshCount = 0
    private var mapperInvalidationCount = 0
    private var navigationPendingGeometry = NativePDFNavigationGeometryCache()
    private var retainedNavigationBackdrop: NativePDFRetainedInkBackdrop?
    // These identities come only from this Surface's real measured contacts.
    // A server undo/recreated object must not be painted twice over stale pixels.
    private var continuityLocalInkIDs = Set<String>()
    private var navigationCropIsUrgent = false
    private var navigationUrgentRequestedGeneration: UInt64?
    private var navigationRasterFailureCount = 0
    private let decorations = NativePDFViewportDecorations()
    private(set) var renderViewport: NativePDFRenderViewport?
    private var active: UITouch? {
        didSet { updateScheduler?.setPencilActive(active?.type == .pencil) }
    }
    private weak var gestureContact: UITouch?
    private var startTime: TimeInterval = 0
    private var measured: [NativePDFPoint] = []
    private let previewGeometry = NativePDFLiveInkGeometryCache()
    private var predicted: [NativePDFPoint] = []
    private var strokeTool = Tool()
    private var strokeInkVersion = 5
    private var updateScheduler: NativePDFInkUpdateScheduler?
    private var needsPreview = false
    /// Texture backoff pauses only drawing. Input, corrections and durability
    /// continue independently, with their original clocks and measured points.
    private var backdropAvailability: NativePDFMetalInk.BackdropAvailability = .notRequired
    private var backdropDependencyNeedsReview = true
    private var backdropRecoveryEpoch: UInt64 = 0
    private struct BackdropWakeKey: Equatable {
        let epoch: UInt64
        let generation: UInt64
        let deadline: CFTimeInterval
    }
    private struct BackdropFailureKey: Equatable {
        let generation: UInt64?
    }
    private var backdropWakeKey: BackdropWakeKey?
    private var backdropRetryTask: Task<Void, Never>?
    private var backdropWakeSerial: UInt64 = 0
    private var reportedBackdropFailure: BackdropFailureKey?
    private var backdropWakeCount = 0
    /// Only unresolved estimates retain a coordinate basis. Ordinary measured
    /// points remain the compact canonical point array.
    private struct EstimatedSample {
        var index: Int
        var properties: UITouch.Properties
        let mapper: InkCoordinateMapper
        let windowToCanvas: CGAffineTransform?
        weak var referenceWindow: UIWindow?
        let hadWindow: Bool
        var altitude: Double
        var azimuth: Double
    }
    private var estimated: [NSNumber: EstimatedSample] = [:]
    private var completion: Task<Void, Never>?
    private var ending = false
    private struct EstimatedCompletion {
        var stroke: NativePDFCompletedStroke
        var indices: [NSNumber: EstimatedSample]
    }
    private let estimatedCompletions = NativePDFOrderedCompletions<EstimatedCompletion>()
    private let completionBuffer = NativePDFCompletionBuffer()
    private var journalBlocked = false
    private var submissionTimes: [Double] = []
    private var paper: UIImage?
    private var backdrop: UIImage?
    private let committedScene = NativePDFCommittedSceneCache()
    private var sceneDirty = true
    private var inputCounts: [String: Int] = [:]
    private var inputSequence: UInt64 = 0
    private struct ContactTiming {
        var beganAt: CFTimeInterval
        var endedAt: CFTimeInterval?
        var firstSubmittedAt: CFTimeInterval?
        var firstPresentedAt: CFTimeInterval?
    }
    private var contactTimings: [UInt64: ContactTiming] = [:]
    private var presentationTimes: [Double] = []
    private var firstPresentationTimes: [Double] = []
    private var frameStatistics = NativePDFInkFrameStatistics()
    private var lastTimingPublication: CFTimeInterval = 0
    private var lastSubmissionTimingPublication: CFTimeInterval = 0
    private var lastRenderAttemptAt: CFTimeInterval?
    private var renderAttemptCount = 0
    private var deferredRenderCount = 0
    private var maxRenderCPUMS = 0.0
    private var lastRenderCPUMS = 0.0
    private var lastBackdropCPUMS = 0.0
    private var lastGeometryCPUMS = 0.0
    private var lastSubmitCPUMS = 0.0
    private var slowRenderLogCount = 0
    private var inputDeliveryStatistics = NativePDFLatencySamples()
    private var inputEntryWorkStatistics = NativePDFLatencySamples()
    private var invalidInputDeliveryTimestamps = 0

    var inputDiagnostics: [String: Any] {
        ["tool": tool.name, "loading": isLoading, "journalBlocked": journalBlocked,
         "mapped": mapper != nil, "interactive": isUserInteractionEnabled, "inWindow": window != nil,
         "frameRequested": updateScheduler?.isRequestingFrames ?? false,
         "backdropRecoveryState": backdropRecoveryState,
         "backdropRetryScheduled": backdropRetryTask != nil,
         "backdropRetryWakeCount": backdropWakeCount,
         "backdropUploadAttempts": metal.backdropUploadAttemptCount,
         "previewGeometryRevision": previewGeometry.revision,
         "navigationRefreshMaxCPUMS": navigationRefreshMaxCPUMS,
         "navigationRefreshCount": navigationRefreshCount,
         "navigationAsyncRasterCount": navigationRasterizer.completedCount,
         "navigationDisplayActive": navigationDisplayActive,
         "asynchronousEditDisplayActive": asynchronousEditDisplayActive,
         "asynchronousEditTileInstalls": asynchronousEditTileInstallCount,
         "progressiveErasureActive": progressiveErasureActive,
         "progressiveErasurePending": progressiveErasurePending != nil,
         "progressiveErasureInstalls": progressiveErasureInstallCount,
         "continuityLocalInkCount": continuityLocalInkIDs.count,
         "navigationBaseRevision": navigationBaseSnapshot?.revision ?? 0,
         "navigationCurrentRevision": navigationSnapshot?.revision ?? 0,
         "navigationBaseObjects": navigationBaseSnapshot?.objects.count ?? 0,
         "sceneDeferredFullRenders": committedScene.deferredFullReplayCount,
         "mapperInvalidations": mapperInvalidationCount,
         "sceneFullRenders": committedScene.fullRenderCount, "sceneAppendRenders": committedScene.appendRenderCount,
         "sceneLastDrawnObjects": committedScene.lastDrawnObjectCount, "sceneReuses": committedScene.reuseCount,
         "sceneTailRenders": committedScene.tailRenderCount, "sceneRenderMode": committedScene.lastRenderMode,
         "sceneReplayStartIndex": committedScene.lastReplayStartIndex,
         "renderAttempts": renderAttemptCount, "deferredRenderAttempts": deferredRenderCount,
         "renderLastCPUMS": lastRenderCPUMS, "renderMaxCPUMS": maxRenderCPUMS,
         "backdropLastCPUMS": lastBackdropCPUMS, "geometryLastCPUMS": lastGeometryCPUMS,
         "submitLastCPUMS": lastSubmitCPUMS,
         "inputDeliveryTiming": inputDeliveryStatistics.diagnostics,
         "inputEntryWorkTiming": inputEntryWorkStatistics.diagnostics,
         "invalidInputDeliveryTimestamps": invalidInputDeliveryTimestamps,
         "sceneComparedVisualPayloads": committedScene.lastComparedVisualPayloadCount,
         "retainedInkActive": retainedInkActive,
         "retainedInkMeshes": retainedModel?.retainedGeometryCount ?? 0,
         "retainedInkMeshBuilds": retainedModel?.meshBuildCount ?? 0,
         "retainedObjectTextures": retainedModel?.objectCount ?? 0,
         "retainedObjectPreparing": retainedModel?.preparing ?? false,
         "retainedObjectRasters": retainedModel?.textures.rasterCount ?? 0,
         "retainedObjectUploads": retainedModel?.textures.uploadCount ?? 0,
         "retainedInkInstalls": retainedInstallCount,
         "retainedPaperRasters": retainedPaper.rasterCount,
         "retainedPaperCropRasters": retainedPaperCrop.rasterCount,
         "retainedPaperCropActive": retainedPaperCropActive,
         "nativeEraseContact": nativeEraseContact,
         "nativeEraseTargets": erasingTargets.count,
         "counts": inputCounts]
    }
    private func recordInput(_ phase: String, type: UITouch.TouchType = .pencil) {
        let kind = type == .pencil ? "pencil" : type == .direct ? "finger" : "other"
        let tools = ["select", "lasso", "pen", "highlighter", "eraser", "line", "arrow", "rect", "ellipse", "text"]
        let name = tools.contains(tool.name) ? tool.name : "unknown"
        let key = "\(name).\(kind).\(phase)", count = (inputCounts[key] ?? 0) + 1
        inputCounts[key] = count
        // Hit testing may run repeatedly for a single contact. Keep exact
        // begin/end counters separately and bound diagnostic disk traffic.
        if count <= 20 || count.isMultiple(of: 50) { onDiagnostic?("\(key).\(count)") }
    }

    init?(nativeFrame: CGRect = .zero, renderer suppliedRenderer: NativePDFMetalInk? = nil,
          navigationRasterRequest: ((NativePDFNavigationRasterizer.Request) -> Void)? = nil,
          navigationTileDraw: (@Sendable (UInt64) -> Void)? = nil,
          retainedPaperCropRasterize: NativePDFRetainedPaperCrop.Rasterizer? = nil,
          retainedObjectRasterize: NativePDFRetainedObjectTextures.Rasterizer? = nil) {
        guard let renderer = suppliedRenderer ?? NativePDFMetalInk() else { return nil }
        metal = renderer
        self.retainedObjectRasterize = retainedObjectRasterize
        retainedPaperCrop = NativePDFRetainedPaperCrop(rasterize: retainedPaperCropRasterize)
        navigationView = NativePDFNavigationView(frame: .zero, beforeTileDraw: navigationTileDraw)
        suppliedNavigationRasterRequest = navigationRasterRequest
        super.init(frame: nativeFrame)
        retainedPaper.onReady = { [weak self] in self?.reviewBackdropDependency() }
        retainedPaper.onFailure = { [weak self] error in self?.onFailure?(error) }
        retainedPaperCrop.onReady = { [weak self] in self?.reviewBackdropDependency() }
        retainedPaperCrop.onFailure = { [weak self] _ in self?.onDiagnostic?("paper.crop.raster.failed.base-fallback") }
        backgroundColor = .clear; isOpaque = false; isMultipleTouchEnabled = true
        addInteraction(UIScribbleInteraction(delegate: self))
        // This full-page view owns touch coordinates only. Keeping all drawing
        // in cropped children avoids a page-sized UIView backing allocation.
        scene.isUserInteractionEnabled = false; scene.accessibilityElementsHidden = true
        scene.contentMode = .scaleToFill
        addSubview(navigationView); addSubview(scene); addSubview(metal); addSubview(decorations)
        decorations.drawCanvas = { [weak self] context in self?.drawDecorations(in: context) }
        metal.onSubmission = { [weak self] milliseconds in
            guard let self else { return }
            self.submissionTimes.append(milliseconds)
            if self.submissionTimes.count > 240 { self.submissionTimes.removeFirst(self.submissionTimes.count-240) }
            let now = CACurrentMediaTime()
            guard self.submissionTimes.count == 1 || now - self.lastSubmissionTimingPublication >= 0.25 ||
                    self.contactTimings[self.inputSequence]?.endedAt != nil else { return }
            self.lastSubmissionTimingPublication = now
            let sorted = self.submissionTimes.sorted(), index = min(sorted.count-1, Int(Double(sorted.count)*0.95))
            self.onTiming?(sorted[index], sorted.count)
        }
        metal.onFramePresented = { [weak self] frame in self?.recordPresentation(frame) }
        metal.onFrameSubmitted = { [weak self] frame in
            guard let self, var contact = self.contactTimings[frame.strokeID], contact.firstSubmittedAt == nil else { return }
            contact.firstSubmittedAt = frame.submittedAt; self.contactTimings[frame.strokeID] = contact
            if frame.strokeID <= 20 || frame.strokeID.isMultiple(of: 50) {
                self.onDiagnostic?("submit.first.\(Int(max(0, (frame.submittedAt-contact.beganAt)*1000).rounded()))ms")
                // This includes scheduling and any deferred drawable attempts;
                // it is elapsed wall time, not the CPU cost of preparation.
                let preSubmitWall = Int(max(0, (frame.drawStartedAt-contact.beganAt)*1000).rounded())
                let acquire = Int(max(0, (frame.drawableAcquiredAt-frame.drawStartedAt)*1000).rounded())
                let encodeAndSubmit = Int(max(0, (frame.submittedAt-frame.drawableAcquiredAt)*1000).rounded())
                let backgroundAcquire = Int(self.metal.lastBackgroundDrawableAcquisitionMS.rounded())
                self.onDiagnostic?("submit.stages.preSubmitWall.\(preSubmitWall)ms.drawable.\(acquire)ms.encodeSubmit.\(encodeAndSubmit)ms.drawableBG.\(backgroundAcquire)ms")
            }
        }
        accessibilityIdentifier = "bandal-native-pdf-ink"
        accessibilityLabel = "PDF 필기 영역"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        recordInput("scribble.denied"); return false
    }
    override func layoutSubviews() {
        super.layoutSubviews(); onLayout?(); refreshViewport(); layoutTextEditor()
    }
    /// Called by PDFKit's host after scrolling, zooming, and window resizing.
    /// Rendering is coalesced to a display frame; input still uses page coords.
    func refreshViewport() {
        defer { layoutTextEditor() }
        let started = CACurrentMediaTime()
        defer { navigationRefreshMaxCPUMS = max(navigationRefreshMaxCPUMS, (CACurrentMediaTime()-started)*1000) }
        let windowBounds = window.map { convert($0.bounds, from: $0) }
        let visible = viewportProvider?() ?? windowBounds ?? .zero
        let transform = NativePDFCoordinateMapping.sample(bounds: bounds, convert: { self.convert($0, to: window) })
        let viewport = window == nil ? nil : transform.flatMap { NativePDFRenderViewport(canvasBounds: bounds,
            visibleRect: visible.intersection(windowBounds ?? visible), canvasToWindow: $0, screenScale: window?.screen.scale ?? 1, stabilized: true) }
        guard renderViewport != viewport else { return }
        cancelBackdropWake(invalidateEpoch: true)
        backdropDependencyNeedsReview = true
        let hadViewport = renderViewport != nil
        progressiveErasureActive = false; progressiveErasurePending = nil
        navigationRefreshCount += 1
        renderViewport = viewport
        navigationRasterFailureCount = 0
        navigationGeneration &+= 1; navigationCropTask?.cancel(); navigationCropTask = nil; navigationRasterizer.cancel()
        if !retainedInkActive { metal.strokes = []; metal.backdrop = nil }
        // stageFrame supplies the new drawable dimensions before unhiding
        // Metal. Waking it here can start a blocking request at the old size.
        decorations.isHidden = viewport == nil
        // The raster scene image is only a hand-off fallback until Metal has
        // installed a retained frame. After that it may predate erasures, and
        // Metal keeps reprojected pixels through navigation instead.
        scene.isHidden = viewport == nil || scene.image == nil || (retainedInkActive && retainedInstallCount > 0)
        guard let viewport else {
            textEditor?.isHidden = true
            retainedPaperCrop.reset(); failedRetainedPaperCropImage = nil; retainedPaperCropActive = false
            asynchronousEditDisplayActive = false
            navigationView.isHidden = true; navigationDisplayActive = false
            navigationBaseSnapshot = nil
            navigationPendingGeometry.removeAll()
            retainedNavigationBackdrop = nil
            navigationView.clearContinuity()
            navigationCropIsUrgent = false; navigationUrgentRequestedGeneration = nil
            paper = nil; backdrop = nil; sceneDirty = true
            committedScene.invalidate(reason: "offscreen")
            metal.suspendFrame()
            updateScheduler?.setNeedsFrame(false)
            return
        }
        for child in [scene, decorations] as [UIView] {
            child.frame = viewport.canvasRect; child.contentScaleFactor = viewport.pixelScale
        }
        decorations.canvasOrigin = viewport.canvasRect.origin
        if let mapper {
            if hadViewport { _ = metal.reprojectRetainedFrame(to: mapper.canvasToPDF) }
            else { stageMetalFrame(mapper: mapper, viewport: viewport, presentingIn: mapper) }
        }
        if prepareRetainedScene() {
            navigationDisplayActive = false
            sceneDirty = true; decorations.setNeedsDisplay(); schedulePreview()
            return
        }
        navigationView.frame = bounds; navigationView.isHidden = false
        // The image keeps its old coordinates until the new scene is ready.
        // CATiledLayer covers newly exposed page regions in the meantime.
        navigationDisplayActive = hadViewport || navigationSnapshot != nil
        if navigationDisplayActive {
            if let mapper { navigationView.retainContinuity(retainedNavigationBackdrop, mapper: mapper, viewport: viewport) }
            scene.isHidden = true
        }
        paper = nil; backdrop = nil; committedScene.invalidate(reason: "viewport"); sceneDirty = true
        updateNavigationSnapshot()
        if let base = navigationBaseSnapshot, let mapper { navigationView.install(base, mapper: mapper) }
        requestNavigationCrop()
        decorations.setNeedsDisplay(); schedulePreview()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow(); refreshViewport()
        if window == nil {
            finishMeasuredStroke()
            cancelBackdropWake(invalidateEpoch: true)
            backdropDependencyNeedsReview = true
            updateScheduler?.stop(); updateScheduler = nil
        }
        else if updateScheduler == nil {
            let scheduler = NativePDFInkUpdateScheduler(view: self)
            scheduler.render = { [weak self] in self?.renderPreview() }
            scheduler.setPencilActive(active?.type == .pencil)
            scheduler.setNeedsFrame(shouldRequestPreviewFrame)
            updateScheduler = scheduler
        }
    }
    func pencilInputTarget(at point: CGPoint) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled, bounds.contains(point) else { return nil }
        // Pencil inside the live text box places the caret (and Scribble) instead of drawing.
        if let frame = textEditorLocalFrame, frame.contains(point) { return nil }
        guard !isLoading else { recordInput("blocked.loading"); return nil }
        guard !journalBlocked else { recordInput("blocked.journal"); return nil }
        guard mapper != nil else { recordInput("blocked.mapper"); return nil }
        guard ["select", "lasso", "pen", "highlighter", "eraser", "line", "arrow", "rect", "ellipse", "text"].contains(tool.name) else { recordInput("blocked.tool"); return nil }
        recordInput("target"); return self
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.allTouches?.contains(where: { $0.type == .pencil }) == true { return pencilInputTarget(at: point) }
        guard !isLoading, !journalBlocked, mapper != nil, !isHidden, bounds.contains(point) else { return nil }
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
        // Pencil has exactly one owner: the recognizer attached to PDFView.
        // PDFKit may delay/cancel UIResponder delivery, and when UIKit does
        // deliver it this path must not create a duplicate stroke.
        beginInput(Set(touches.filter { $0.type != .pencil && $0 !== gestureContact }), with: event)
    }
    @discardableResult
    func beginPencilGesture(_ touch: UITouch, with event: UIEvent?, directFixture: Bool = false) -> Bool {
        let enteredAt = CACurrentMediaTime()
        var allowDirectInk = false
        #if DEBUG
        allowDirectInk = directFixture && touch.type == .direct
        #endif
        guard touch.type == .pencil || allowDirectInk, !isLoading else { return false }
        gestureContact = touch
        beginInput([touch], with: event, allowDirectInk: allowDirectInk, handlerEnteredAt: enteredAt)
        if active !== touch { gestureContact = nil }
        return active === touch
    }
    func movePencilGesture(_ touch: UITouch, with event: UIEvent?) { moveInput([touch], with: event) }
    func endPencilGesture(_ touch: UITouch, with event: UIEvent?) { endInput([touch], with: event); gestureContact = nil }
    func cancelPencilGesture(_ touch: UITouch, with event: UIEvent?) { cancelInput([touch], with: event); gestureContact = nil }
    func updatePencilGestureProperties(_ touches: Set<UITouch>) { updateEstimatedInput(touches) }
    private func beginInput(_ touches: Set<UITouch>, with event: UIEvent?, allowDirectInk: Bool = false,
                            handlerEnteredAt: CFTimeInterval? = nil) {
        let enteredAt = handlerEnteredAt ?? CACurrentMediaTime()
        if ending { finishMeasuredStroke() }
        if let touch = touches.first { recordInput("begin", type: touch.type) }
        guard !journalBlocked, active == nil, let touch = touches.first(where: { $0.type == .pencil }) ?? touches.first(where: { $0.type == .direct && (allowDirectInk || ["select", "text"].contains(tool.name)) }), mapper != nil else { return }
        if tool.name == "highlighter", !prepareRetainedScene(), !navigationDisplayActive, prepareBackdrop() == nil, !asynchronousEditDisplayActive {
            onFailure?(NativePDFError.invalid("형광펜 배경을 준비하지 못했습니다. 필기를 보존한 채 PDF를 다시 열어 주세요.")); return
        }
        active = touch; startTime = touch.timestamp; strokeTool = tool; strokeInkVersion = 5; previewGeometry.reset()
        inputSequence &+= 1
        let beganAt = CACurrentMediaTime()
        contactTimings[inputSequence] = ContactTiming(beganAt: beganAt)
        // The submit/present clock begins after event delivery. Earlier main
        // actor work can queue a hardware contact before this method runs;
        // measure that gap separately from the Host's async durability work.
        inputEntryWorkStatistics.record(milliseconds: (beganAt - enteredAt) * 1000)
        if let deliveryMS = NativePDFLatencySamples.inputDeliveryMS(timestamp: touch.timestamp, enteredAt: enteredAt) {
            inputDeliveryStatistics.record(milliseconds: deliveryMS)
            if inputSequence <= 20 || inputDeliveryStatistics.shouldLog {
                onDiagnostic?("input.delivery.stroke.\(inputSequence).\(inputDeliveryStatistics.logCode)")
            }
        } else {
            invalidInputDeliveryTimestamps += 1
            if invalidInputDeliveryTimestamps <= 3 { onDiagnostic?("input.delivery.timestamp-unavailable.stroke.\(inputSequence)") }
        }
        if inputSequence <= 20 || inputEntryWorkStatistics.shouldLog {
            onDiagnostic?("input.entryWork.stroke.\(inputSequence).\(inputEntryWorkStatistics.logCode)")
        }
        contactTimings = contactTimings.filter { $0.key >= inputSequence &- min(inputSequence, 32) }
        onInputOwnership?(true)
        measured = []; redrawLassoPreview(); predicted = []; estimated = [:]; ending = false
        resetHoldSnap()
        nativeEraseContact = tool.name == "eraser" && nativeErasingEnabled && prepareRetainedScene()
        if nativeEraseContact {
            erasingTargets = []; erasingKeys = []; eraserPreviousPoint = nil; onEraseBegin?()
        }
        backdropDependencyNeedsReview = true
        append(event?.coalescedTouches(for: touch) ?? [touch]); updateHoldSnap(from: 0); schedulePreview()
        if nativeEraseContact { updateNativeErasure(points: measured) }
        // Put the first dot on the GPU before completion work. Further
        // coalesced samples share UIKit's normal/low-latency update phases.
        renderPreview()
        publishPointer("down", points: Array(measured.prefix(1)))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        moveInput(Set(touches.filter { $0.type != .pencil && $0 !== gestureContact }), with: event)
    }
    private func moveInput(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = active, touches.contains(touch) else { return }
        let start = measured.count
        append(event?.coalescedTouches(for: touch) ?? [touch])
        predicted = (event?.predictedTouches(for: touch) ?? []).compactMap { prediction in
            guard var point = sample(prediction) else { return nil }
            point.p = measured.last?.p ?? point.p
            return point
        }
        publishPointer("move", points: Array(measured.dropFirst(start)))
        updateHoldSnap(from: start)
        redrawLassoPreview()
        schedulePreview()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endInput(Set(touches.filter { $0.type != .pencil && $0 !== gestureContact }), with: event)
    }
    private func endInput(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = active, touches.contains(touch) else { return }
        recordInput("end", type: touch.type)
        let previousCount = measured.count
        append(event?.coalescedTouches(for: touch) ?? [touch]); predicted = []
        updateHoldSnap(from: previousCount)
        if nativeEraseContact { updateNativeErasure(points: Array(measured.dropFirst(previousCount))) }
        markContactEnded()
        schedulePreview(); renderPreview()
        // Transfer immutable measured input to the Host, then accept delayed
        // UIKit corrections independently of the next stroke. Its serial
        // worker establishes durability before publishing completion/ACK;
        // callback return alone is not proof of a disk write. No predictions
        // enter the checkpoint or final create/receipt payload.
        if ["pen", "highlighter"].contains(strokeTool.name), !estimated.isEmpty || !estimatedCompletions.isEmpty {
            checkpointEstimatedStroke()
        } else {
            do { try flushActiveStroke() } catch { onFailure?(error) }
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelInput(Set(touches.filter { $0.type != .pencil && $0 !== gestureContact }), with: event)
    }
    private func cancelInput(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = active, touches.contains(touch) else { return }
        recordInput("cancel", type: touch.type)
        // Only measured points survive interruptions. Predictions are never
        // persisted, nor can another finger terminate a Pencil-owned stroke.
        resetHoldSnap()
        finishMeasuredStroke(cancelObjectEdit: true)
    }
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        updateEstimatedInput(Set(touches.filter { $0.type != .pencil }))
    }
    private func updateEstimatedInput(_ touches: Set<UITouch>) {
        var changedCompletions: Set<String> = []
        for touch in touches {
            guard let key = touch.estimationUpdateIndex else { continue }
            if var estimate = estimated[key], measured.indices.contains(estimate.index),
               let corrected = correctedSample(touch, original: measured[estimate.index], estimate: &estimate) {
                measured[estimate.index] = corrected
                estimated[key] = estimate.properties.isEmpty ? nil : estimate
            }
            for id in estimatedCompletions.ids {
                guard var entry = estimatedCompletions[id], var estimate = entry.indices[key],
                      entry.stroke.points.indices.contains(estimate.index),
                      let corrected = correctedSample(touch, original: entry.stroke.points[estimate.index], estimate: &estimate) else { continue }
                entry.stroke.points[estimate.index] = corrected
                entry.indices[key] = estimate.properties.isEmpty ? nil : estimate
                estimatedCompletions[id] = entry
                changedCompletions.insert(id)
            }
        }
        if !changedCompletions.isEmpty {
            do {
                // Transfer each corrected immutable snapshot before ordered
                // completion. The Host retains admitted work and serializes
                // disk writes/barriers; callback return only transfers that
                // ownership, including when an earlier write later fails.
                for id in estimatedCompletions.ids where changedCompletions.contains(id) {
                    guard let entry = estimatedCompletions[id] else { continue }
                    guard let onCheckpoint else { throw NativePDFError.invalid("필기 보정 저장 연결을 확인해 주세요.") }
                    retainedModel?.rememberLocalMutation(entry.stroke.mutationID)
                    try onCheckpoint(entry.stroke)
                }
                try drainCorrectedStrokes()
            } catch { journalBlocked = true; onFailure?(error) }
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
    private func captureEstimate(_ touch: UITouch, index: Int) -> EstimatedSample? {
        guard let mapper else { return nil }
        let referenceWindow = touch.window ?? window
        let properties = touch.estimatedPropertiesExpectingUpdates
        // Pressure-only estimates are the common path and need no view
        // conversion. Masks only shrink; an unused basis cannot be needed later.
        let needsCoordinateBasis = properties.contains(.location) || properties.contains(.azimuth)
        let transform = needsCoordinateBasis ? NativePDFCoordinateMapping.sample(bounds: referenceWindow?.bounds ?? bounds,
            convert: { self.convert($0, from: referenceWindow) }) : nil
        return EstimatedSample(index: index, properties: properties,
            mapper: mapper, windowToCanvas: transform, referenceWindow: referenceWindow,
            hadWindow: referenceWindow != nil, altitude: Double(touch.altitudeAngle),
            azimuth: Double(touch.azimuthAngle(in: self)))
    }
    /// UIKit may reuse its mutable touch after the page moved. Apply only the
    /// properties that this original sample was still waiting for, using that
    /// sample's saved basis. A pressure-only correction never recomputes x/y/t
    /// or measured tilt, including their original floating-point bits.
    private func correctedSample(_ touch: UITouch, original: NativePDFPoint,
                                 estimate: inout EstimatedSample) -> NativePDFPoint? {
        var point = original
        let properties = estimate.properties
        if properties.contains(.force) {
            let force = touch.maximumPossibleForce > 0 ? Double(touch.force / touch.maximumPossibleForce) : 0.5
            guard force.isFinite else { return nil }
            point.p = min(1, max(0, force))
        }
        if properties.contains(.location) || properties.contains(.azimuth) {
            // Detached/replaced windows are a different lifecycle boundary.
            // Never reinterpret an old location in the new window's basis.
            guard !estimate.hadWindow || (estimate.referenceWindow != nil && touch.window === estimate.referenceWindow),
                  let transform = estimate.windowToCanvas else { return nil }
            if properties.contains(.location) {
                let location = touch.preciseLocation(in: estimate.referenceWindow).applying(transform)
                guard location.x.isFinite, location.y.isFinite else { return nil }
                let normalized = estimate.mapper.normalized(location, pressure: point.p)
                point.x = min(1, max(0, normalized.x)); point.y = min(1, max(0, normalized.y))
            }
            if properties.contains(.azimuth) {
                let direction = touch.azimuthUnitVector(in: estimate.referenceWindow)
                let dx = transform.a * direction.dx + transform.c * direction.dy
                let dy = transform.b * direction.dx + transform.d * direction.dy
                guard dx.isFinite, dy.isFinite, hypot(dx, dy) > 0 else { return nil }
                estimate.azimuth = Double(atan2(dy, dx))
            }
        }
        if properties.contains(.altitude) { estimate.altitude = Double(touch.altitudeAngle) }
        if properties.contains(.altitude) || properties.contains(.azimuth) {
            guard estimate.altitude.isFinite, estimate.azimuth.isFinite else { return nil }
            let altitude = max(estimate.altitude, 0.001)
            point.tiltX = atan(cos(estimate.azimuth) / tan(altitude)) * 180 / .pi
            point.tiltY = atan(sin(estimate.azimuth) / tan(altitude)) * 180 / .pi
        }
        guard point.isValid else { return nil }
        estimate.properties.formIntersection(touch.estimatedPropertiesExpectingUpdates)
        return point
    }
    private func append(_ touches: [UITouch]) {
        metal.noteInputReceived(at: CACurrentMediaTime(), strokeID: inputSequence)
        for touch in touches {
            // Coalesced delivery may carry an update to an existing sample.
            // It has the same correction contract as the delayed callback.
            if let key = touch.estimationUpdateIndex, var estimate = estimated[key], measured.indices.contains(estimate.index) {
                if let corrected = correctedSample(touch, original: measured[estimate.index], estimate: &estimate) {
                    measured[estimate.index] = corrected
                    estimated[key] = estimate.properties.isEmpty ? nil : estimate
                }
                continue
            }
            guard let point = sample(touch), point.isValid else { continue }
            if let previous = measured.last, previous == point { continue }
            measured.append(point)
            if let key = touch.estimationUpdateIndex, !touch.estimatedPropertiesExpectingUpdates.isEmpty {
                estimated[key] = captureEstimate(touch, index: measured.count - 1)
            }
        }
        // A texture wait must not prevent newly exposed input from requesting
        // its exact destination. The crop request is deduplicated per scene
        // generation; it does not rebuild geometry or reattempt the texture.
        if navigationDisplayActive, backdropBlocksPreview, !touches.isEmpty {
            requestNavigationCrop(urgent: true)
        }
    }
    private var canRenderPreview: Bool { window != nil && mapper != nil && renderViewport != nil }
    private var backdropBlocksPreview: Bool {
        switch backdropAvailability {
        case .notRequired, .ready: false
        case .waiting, .exhausted, .missing: true
        }
    }
    private var backdropRecoveryState: String {
        switch backdropAvailability {
        case .notRequired: "notRequired"
        case .ready: "ready"
        case .waiting: "waiting"
        case .exhausted: "exhausted"
        case .missing: "missing"
        }
    }
    private var shouldRequestPreviewFrame: Bool {
        needsPreview && canRenderPreview && (backdropDependencyNeedsReview || !backdropBlocksPreview)
    }
    private func updatePreviewScheduling() { updateScheduler?.setNeedsFrame(shouldRequestPreviewFrame) }
    private func schedulePreview() { needsPreview = true; updatePreviewScheduling() }
    private func reviewBackdropDependency() {
        backdropDependencyNeedsReview = true
        schedulePreview()
    }
    private func cancelBackdropWake(invalidateEpoch: Bool = false) {
        backdropWakeSerial &+= 1
        backdropRetryTask?.cancel(); backdropRetryTask = nil; backdropWakeKey = nil
        if invalidateEpoch { backdropRecoveryEpoch &+= 1 }
    }
    private func scheduleBackdropWake(generation: UInt64, deadline: CFTimeInterval) {
        let key = BackdropWakeKey(epoch: backdropRecoveryEpoch, generation: generation, deadline: deadline)
        guard backdropWakeKey != key || backdropRetryTask == nil else { return }
        cancelBackdropWake()
        guard canRenderPreview, deadline.isFinite else { return }
        backdropWakeKey = key
        let serial = backdropWakeSerial
        let delay = max(0, deadline - metal.backdropRecoveryTime)
        backdropRetryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self,
                  self.backdropWakeSerial == serial, self.backdropWakeKey == key,
                  self.backdropRecoveryEpoch == key.epoch, self.canRenderPreview,
                  case .waiting(let currentGeneration, let currentDeadline) = self.backdropAvailability,
                  currentGeneration == key.generation, currentDeadline == key.deadline else { return }
            self.backdropRetryTask = nil; self.backdropWakeKey = nil
            // Metal owns the monotonic due check. A synthetic test clock or
            // an early wake must not turn the remaining interval into a spin.
            guard self.metal.backdropRecoveryTime >= key.deadline else {
                self.scheduleBackdropWake(generation: key.generation, deadline: key.deadline)
                return
            }
            self.backdropWakeCount += 1
            self.reviewBackdropDependency()
        }
    }
    private func prepareFrameBackdrop(_ image: CGImage?, required: Bool) -> Bool {
        metal.backdrop = image
        let availability = metal.prepareBackdropForFrame(required: required)
        backdropAvailability = availability; backdropDependencyNeedsReview = false
        switch availability {
        case .notRequired, .ready:
            cancelBackdropWake()
            return true
        case .waiting(let generation, let retryAt):
            needsPreview = true
            scheduleBackdropWake(generation: generation, deadline: retryAt)
        case .exhausted(let generation):
            needsPreview = true; cancelBackdropWake()
            reportBackdropFailure(generation: generation)
        case .missing:
            needsPreview = true; cancelBackdropWake()
            reportBackdropFailure(generation: nil)
        }
        updatePreviewScheduling()
        return false
    }
    private func reportBackdropFailure(generation: UInt64?) {
        let key = BackdropFailureKey(generation: generation)
        guard reportedBackdropFailure != key else { return }
        reportedBackdropFailure = key
        onDiagnostic?(generation == nil ? "backdrop.texture.missing" : "backdrop.texture.exhausted")
        onFailure?(NativePDFError.invalid("필기 배경을 표시하지 못했습니다. 측정한 필기는 보존되며 새 배경이 준비되면 다시 표시합니다."))
    }
    private func markContactEnded() {
        if contactTimings[inputSequence]?.endedAt == nil {
            contactTimings[inputSequence]?.endedAt = CACurrentMediaTime()
        }
    }
    private func recordPresentation(_ frame: NativePDFMetalInk.FrameTiming) {
        if frame.presentedAt == nil {
            // A newly visible Metal layer can drop its first drawable during
            // layout. A stationary Pencil provides no move event to retry it.
            if active != nil, metal.retryUnpresentedFrame(frame, forStrokeID: inputSequence) { schedulePreview() }
            return
        }
        guard let presentedAt = frame.presentedAt, let delay = frame.receiveToPresentMS,
              var contact = contactTimings[frame.strokeID] else { return }
        let beforeLift = contact.endedAt.map { presentedAt <= $0 } ?? true
        if beforeLift { frameStatistics.framesBeforeLift += 1 }
        if contact.firstPresentedAt == nil {
            contact.firstPresentedAt = presentedAt; contactTimings[frame.strokeID] = contact
            firstPresentationTimes.append(max(0, (presentedAt - contact.beganAt) * 1000))
            if beforeLift { frameStatistics.strokesBeforeLift += 1 }
            else { frameStatistics.strokesAfterLift += 1 }
            let count = frameStatistics.strokesBeforeLift + frameStatistics.strokesAfterLift
            if count <= 20 || count.isMultiple(of: 50) {
                onDiagnostic?("present.first.\(Int(max(0, (presentedAt - contact.beganAt) * 1000).rounded()))ms.\(beforeLift ? "before" : "after").lift")
            }
        }
        presentationTimes.append(delay)
        if presentationTimes.count > 240 { presentationTimes.removeFirst(presentationTimes.count - 240) }
        if firstPresentationTimes.count > 240 { firstPresentationTimes.removeFirst(firstPresentationTimes.count - 240) }
        func percentile(_ values: [Double]) -> Double {
            let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
        frameStatistics.samples = presentationTimes.count
        // The handler may arrive after lift: compare GPU presentation time
        // with the saved contact time, never with callback-time active state.
        let now = CACurrentMediaTime()
        if frameStatistics.samples == 1 || now - lastTimingPublication >= 0.25 || contact.endedAt != nil {
            frameStatistics.receiveToPresentP95MS = percentile(presentationTimes)
            frameStatistics.firstPresentationP95MS = percentile(firstPresentationTimes)
            lastTimingPublication = now; onPresentation?(frameStatistics)
        }
    }
    private func checkpointEstimatedStroke() {
        guard !measured.isEmpty else { finishMeasuredStroke(); return }
        let id = UUID().uuidString
        holdTimer?.invalidate(); holdTimer = nil
        let stroke = NativePDFCompletedStroke(mutationID: id, kind: strokeTool.name == "pen" ? "ink" : "highlighter", points: measured, style: strokeTool.style, inkVersion: strokeInkVersion, holdSnap: holdSnap, heldShape: heldShape)
        // Move each unresolved sample's original basis unchanged. A contact
        // can contain measured samples on both sides of a page movement.
        let entry = EstimatedCompletion(stroke: stroke, indices: estimated)
        do { try estimatedCompletions.append(entry, id: id) }
        catch { journalBlocked = true; onFailure?(error); return }
        active = nil; measured = []; redrawLassoPreview(); predicted = []; estimated = [:]; onInputOwnership?(false)
        backdropDependencyNeedsReview = true
        do {
            guard let onCheckpoint else { throw NativePDFError.invalid("필기 보정 저장 연결을 확인해 주세요.") }
            retainedModel?.rememberLocalMutation(stroke.mutationID)
            try onCheckpoint(stroke)
            if stroke.kind == "ink" { continuityLocalInkIDs.insert(stroke.mutationID) }
            try drainCorrectedStrokes()
            // Keep the last live drawable until the checkpoint image and
            // clear frame can be presented in one Core Animation transaction.
        } catch { journalBlocked = true; onFailure?(error) }
        schedulePreview()
    }
    private func writeEstimatedStroke(_ entry: EstimatedCompletion) throws {
        guard let onStroke else { throw NativePDFError.invalid("필기 저장 연결을 확인해 주세요.") }
        retainedModel?.rememberLocalMutation(entry.stroke.mutationID)
        try onStroke(entry.stroke)
        if entry.stroke.kind == "ink" { continuityLocalInkIDs.insert(entry.stroke.mutationID) }
    }
    private func drainCorrectedStrokes() throws {
        // A later stroke cannot enter canonical history before an earlier
        // stroke whose measured properties are still being corrected.
        try estimatedCompletions.drain(ready: { $0.indices.isEmpty }, writer: writeEstimatedStroke)
        if estimatedCompletions.isEmpty && completionBuffer.pending == nil { journalBlocked = false }
        schedulePreview()
    }
    @discardableResult
    private func prepareRetainedScene() -> Bool {
        guard retainedInkEnabled, let mapper, let model = retainedModel else {
            retainedInkActive = false; return false
        }
        // The contact owns its accepted geometry until seal/cancel. A remote
        // mixed-object update cannot switch display backends mid-erasure.
        if nativeEraseContact && retainedInkActive { return true }
        // Quantized density upgrades affect object textures only. Scrolling
        // changes the GPU transform and never replays the object recording.
        let origin = mapper.canvasPoint(InkPoint(x: 0, y: 0, p: 0.5))
        let x = mapper.canvasPoint(InkPoint(x: 1, y: 0, p: 0.5))
        let y = mapper.canvasPoint(InkPoint(x: 0, y: 1, p: 0.5))
        let density = max(hypot(x.x-origin.x, x.y-origin.y) / mapper.geometry.width,
            hypot(y.x-origin.x, y.y-origin.y) / mapper.geometry.height) * (renderViewport?.pixelScale ?? 1)
        let scale = density.isFinite && density > 0 ? pow(2, ceil(log2(max(1, density)))) : 1
        if model.requiresObjectTextures && scale != retainedObjectScale { retainedModelDirty = true }
        if retainedModelDirty {
            let result = model.update(objects: objects, visualTokens: objectVisualTokens,
                pageSize: CGSize(width: mapper.geometry.width, height: mapper.geometry.height),
                scale: scale, image: { [weak self] in self?.imageForObject?($0) })
            retainedObjectScale = scale
            retainedInkActive = result == .supported || (result == .preparing && model.hasAcceptedScene)
            retainedModelDirty = false
            if retainedInkActive {
                navigationCaptureTask?.cancel(); navigationCaptureTask = nil
                navigationCropTask?.cancel(); navigationCropTask = nil; navigationRasterizer.cancel()
                navigationGeneration &+= 1
            }
        }
        return retainedInkActive
    }

    func rememberNativeMutationAlias(mutationID: String, drawingID: String) {
        retainedModel?.rememberNativeAlias(mutationID: mutationID, drawingID: drawingID)
    }

    private func updateNativeErasure(points: [NativePDFPoint]) {
        guard nativeEraseContact, let model = retainedModel else { return }
        let path = points.map { CGPoint(x: $0.x, y: $0.y) }
        let alreadyRemoved = Set(erasedIdentifiers.map { Data($0.utf8) })
        for entry in model.hits(points: path, previous: eraserPreviousPoint) {
            guard let drawingID = entry.drawingID else { continue }
            let key = Data(drawingID.utf8)
            guard !erasingKeys.contains(key), !alreadyRemoved.contains(key),
                  entry.mutationID.map({ !alreadyRemoved.contains(Data($0.utf8)) }) ?? true else { continue }
            erasingKeys.insert(key)
            erasingTargets.append(entry)
        }
        if let last = path.last { eraserPreviousPoint = last }
        schedulePreview()
    }

    /// Completed and live geometry share one ordered GPU pass. No completed
    /// ink enters the Core Graphics crop/tile state machine on this path.
    private func renderRetainedPreview() -> Bool {
        guard prepareRetainedScene(), let model = retainedModel,
              let mapper, let viewport = renderViewport else { return false }
        guard needsPreview || sceneDirty else { return true }
        let pending = completionBuffer.pending ?? (journalBlocked ? estimatedCompletions.first?.stroke : nil)
        let points = previewPoints(pending)
        let predictions = pending == nil ? previewPredictions : []
        let style = pending?.style ?? strokeTool.style
        let highlighter = pending?.kind == "highlighter" || (pending == nil && strokeTool.name == "highlighter")
        let hasLiveInk = !points.isEmpty && (pending != nil || ["pen", "highlighter"].contains(strokeTool.name))
        let origin = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 0, y: 0, p: 0.5)))
        let x = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 1, y: 0, p: 0.5)))
        let y = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 0, y: 1, p: 0.5)))
        let transform = CGAffineTransform(a: x.x-origin.x, b: x.y-origin.y,
            c: y.x-origin.x, d: y.y-origin.y, tx: origin.x, ty: origin.y)
        var excluded = erasedIdentifiers + erasingTargets.flatMap { [$0.drawingID, $0.mutationID].compactMap { $0 } }
        if let pending { excluded.append(pending.mutationID) }
        let items = model.items(transform: transform, excludingIDs: excluded)
        let requiresPaper = !highlights.isEmpty || items.contains { $0.multiply } || (hasLiveInk && highlighter)
        if tool.name == "highlighter", let pdfPage { retainedPaper.update(page: pdfPage, highlights: highlights) }
        if requiresPaper {
            if let pdfPage {
                retainedPaper.update(page: pdfPage, highlights: highlights)
                guard retainedPaper.ready else { needsPreview = false; return true }
            } else if canvasPaperImage == nil { needsPreview = false; return true }
        }
        var paperImage = requiresPaper ? (pdfPage == nil ? canvasPaperImage : retainedPaper.image) : nil
        var paperTransform: CGAffineTransform? = requiresPaper ? transform : nil
        var usingPaperCrop = false
        if requiresPaper, let snapshot = retainedPaper.acceptedSnapshot,
           let baseScale = retainedPaper.acceptedScale,
           let query = Self.retainedPaperCropQuery(normalizedToViewport: transform,
               pageSize: snapshot.size, viewportSize: viewport.canvasRect.size, pixelScale: viewport.pixelScale),
           query.scale > baseScale {
            // The base image is already ready. Scheduling or failure of this
            // higher-density paper-only crop never postpones the ink frame.
            retainedPaperCrop.update(snapshot: snapshot, bounds: query.bounds, scale: query.scale)
            if let crop = retainedPaperCrop.presentation(for: snapshot, bounds: query.bounds, scale: query.scale),
               failedRetainedPaperCropImage !== crop.image {
                // Optional upload preserves the ready base GPU texture, even
                // if subsequent allocations fail. Pan fallback reuses it too.
                if let baseImage = paperImage,
                   metal.selectOptionalBackdrop(crop.image, preserving: baseImage) {
                    paperImage = crop.image; usingPaperCrop = true
                    paperTransform = Self.retainedPaperCropTransform(bounds: crop.bounds,
                        pageSize: snapshot.size, normalizedToViewport: transform)
                    failedRetainedPaperCropImage = nil
                } else {
                    failedRetainedPaperCropImage = crop.image
                    onDiagnostic?("paper.crop.texture.failed.base-fallback")
                }
            }
        } else {
            // Invalidate pending high-density work when the base is sufficient
            // or the current frame no longer needs opaque paper.
            retainedPaperCrop.reset(); failedRetainedPaperCropImage = nil
        }
        if !hasLiveInk, liveZoom?() == true, retainedInstallCount > 0 {
            zoomDeferred = true; needsPreview = false; return true
        }
        guard prepareFrameBackdrop(paperImage, required: requiresPaper) else { return true }
        needsPreview = false
        stageMetalFrame(mapper: mapper, viewport: viewport, presentingIn: mapper)
        metal.retainedItems = items
        metal.retainedBackdropTransform = paperTransform
        if hasLiveInk {
            let polygons = previewGeometry.polygons(version: pending?.inkVersion ?? strokeInkVersion, points: points, predictions: predictions, width: style.width,
                aspect: mapper.geometry.height / mapper.geometry.width, highlighter: highlighter, fixedWidth: style.fixedWidth == true, heldShape: previewShape(pending))
            metal.strokes = [.init(polygons: polygons, color: Self.color(style.color), opacity: Float(style.opacity),
                multiply: highlighter, transform: transform, retainedPrefixPolygonCount: previewGeometry.retainedPrefixPolygonCount,
                geometryRevision: previewGeometry.revision)]
        } else { metal.strokes = []; previewGeometry.reset() }
        // Hidden fallbacks may still hold display flags from a raster edit.
        let handoff = !scene.isHidden || !navigationView.isHidden || asynchronousEditDisplayActive || navigationDisplayActive
        let install: (() -> Void)? = handoff ? { [self] in
            scene.isHidden = true; navigationView.isHidden = true
            navigationDisplayActive = false; asynchronousEditDisplayActive = false
            progressiveErasureActive = false; progressiveErasurePending = nil
            retainedNavigationBackdrop = nil; navigationView.clearContinuity()
        } : nil
        if metal.submitFrame(synchronizedUpdate: install) {
            sceneDirty = false; retainedPaperCropActive = usingPaperCrop
            retainedInstallCount += 1; onSceneInstalled?()
        } else { schedulePreview() }
        return true
    }
    /// Canonical paper points use the snapshot's display-oriented page size;
    /// the mesh transform maps normalized page coordinates to this crop's local
    /// viewport. Its inverse encloses the current visible region even at 90°.
    static func retainedPaperCropQuery(normalizedToViewport t: CGAffineTransform, pageSize: CGSize,
                                       viewportSize: CGSize, pixelScale: CGFloat) -> (bounds: CGRect, scale: CGFloat)? {
        guard [pageSize.width,pageSize.height,viewportSize.width,viewportSize.height,pixelScale,
               t.a,t.b,t.c,t.d,t.tx,t.ty].allSatisfy(\.isFinite),
              pageSize.width > 0, pageSize.height > 0, viewportSize.width > 0, viewportSize.height > 0, pixelScale > 0 else { return nil }
        let c = CGAffineTransform(a: t.a/pageSize.width, b: t.b/pageSize.width,
            c: t.c/pageSize.height, d: t.d/pageSize.height, tx: t.tx, ty: t.ty)
        let determinant = c.a*c.d-c.b*c.c
        guard determinant.isFinite, determinant != 0 else { return nil }
        let bounds = CGRect(origin: .zero,size: viewportSize).applying(c.inverted())
            .intersection(CGRect(origin: .zero,size: pageSize))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        // Largest singular value: exact for uniform zoom/rotation, conservative
        // for nonuniform scaling or shear without sqrt(2) oversampling at 1x.
        let aa = c.a*c.a+c.b*c.b, bb = c.c*c.c+c.d*c.d, ab = c.a*c.c+c.b*c.d
        let density = sqrt((aa+bb+sqrt((aa-bb)*(aa-bb)+4*ab*ab))/2)*pixelScale
        guard density.isFinite, density > 0 else { return nil }
        return (bounds,density)
    }
    static func retainedPaperCropTransform(bounds: CGRect, pageSize: CGSize,
                                           normalizedToViewport t: CGAffineTransform) -> CGAffineTransform {
        let x = bounds.minX/pageSize.width, y = bounds.minY/pageSize.height
        return CGAffineTransform(a: t.a*bounds.width/pageSize.width, b: t.b*bounds.width/pageSize.width,
            c: t.c*bounds.height/pageSize.height, d: t.d*bounds.height/pageSize.height,
            tx: t.a*x+t.c*y+t.tx, ty: t.b*x+t.d*y+t.ty)
    }
    @objc private func renderPreview() {
        let attemptStartedAt = CACurrentMediaTime()
        let gapMS = lastRenderAttemptAt.map { (attemptStartedAt - $0) * 1000 } ?? 0
        lastRenderAttemptAt = attemptStartedAt; renderAttemptCount += 1
        var backdropMS = 0.0, geometryMS = 0.0, submitMS = 0.0
        var didRenderScene = false, submitted: Bool?
        defer {
            let elapsed = (CACurrentMediaTime() - attemptStartedAt) * 1000
            lastRenderCPUMS = elapsed; maxRenderCPUMS = max(maxRenderCPUMS, elapsed)
            lastBackdropCPUMS = backdropMS; lastGeometryCPUMS = geometryMS; lastSubmitCPUMS = submitMS
            if submitted == false { deferredRenderCount += 1 }
            if elapsed >= 24 {
                slowRenderLogCount += 1
                if slowRenderLogCount <= 20 || slowRenderLogCount.isMultiple(of: 50) {
                    onDiagnostic?("render.cpu.\(Int(elapsed.rounded()))ms.backdrop.\(Int(backdropMS.rounded()))ms.geometry.\(Int(geometryMS.rounded()))ms.submit.\(Int(submitMS.rounded()))ms")
                    onDiagnostic?("render.scene.\(didRenderScene ? committedScene.lastRenderMode : "unchanged").objects.\(didRenderScene ? committedScene.lastDrawnObjectCount : 0).cause.\(didRenderScene && committedScene.lastRenderMode == "full" ? committedScene.lastFullRenderReason : "none").gap.\(Int(gapMS.rounded()))ms.deferred.\(deferredRenderCount)")
                }
            }
        }
        defer { updatePreviewScheduling() }
        guard canRenderPreview, backdropDependencyNeedsReview || !backdropBlocksPreview else { return }
        if renderRetainedPreview() { return }
        metal.retainedItems = nil; metal.retainedBackdropTransform = nil
        if navigationDisplayActive {
            // A ready crop may be waiting for its atomic clear when a deletion
            // arrives. Use only the opaque image actually visible, never the
            // newer cache that has not yet reached the screen.
            activateProgressiveErasureIfPossible()
            let attempt = asynchronousEditDisplayActive ? renderAsynchronousEditPreview() : renderNavigationPreview()
            geometryMS = attempt.geometryMS; submitMS = attempt.submitMS; submitted = attempt.submitted
            return
        }
        // Static paper is also cropped, and refreshed at the actual screen
        // density after every viewport change, even when no Pencil is down.
        let backdropStartedAt = CACurrentMediaTime()
        didRenderScene = sceneDirty || backdrop == nil
        let nextScene = sceneDirty || backdrop == nil || scene.image !== backdrop ? prepareBackdrop() : scene.image
        backdropMS = (CACurrentMediaTime() - backdropStartedAt) * 1000
        if asynchronousEditDisplayActive {
            let attempt = renderAsynchronousEditPreview()
            geometryMS = attempt.geometryMS; submitMS = attempt.submitMS; submitted = attempt.submitted
            return
        }
        let sceneChanged = scene.isHidden || scene.image !== nextScene
        guard needsPreview || sceneChanged, let mapper, let viewport = renderViewport else { return }
        let pending = completionBuffer.pending ?? (journalBlocked ? estimatedCompletions.first?.stroke : nil)
        let points = previewPoints(pending)
        let predictions = pending == nil ? previewPredictions : []
        let style = pending?.style ?? strokeTool.style
        let highlighter = pending?.kind == "highlighter" || (pending == nil && strokeTool.name == "highlighter")
        let hasLiveInk = !points.isEmpty && (pending != nil || ["pen", "highlighter"].contains(strokeTool.name))
        // Resolve a failed upload before geometry or drawable prefetch. A clear
        // and ordinary pen do not depend on a previous highlighter's texture.
        guard prepareFrameBackdrop(hasLiveInk && highlighter ? nextScene?.cgImage : nil,
            required: hasLiveInk && highlighter) else { return }
        needsPreview = false
        stageMetalFrame(mapper: mapper, viewport: viewport, presentingIn: mapper)
        updateNavigationSnapshot()
        let acceptedBackdrop = (sceneChanged ? nextScene : nil).flatMap { image in
            navigationSnapshot.flatMap { snapshot in
                NativePDFRetainedInkBackdrop(image: image, snapshot: snapshot, mapper: mapper, viewport: viewport,
                    objects: objects, tokens: objectVisualTokens, highlights: highlights,
                    imageForObject: { self.imageForObject?($0) })
            }
        }
        // A transparent pen preview must disappear in the exact transaction
        // that installs its committed image. Otherwise one displayed frame
        // can blend the same translucent stroke twice (or show a gap).
        let updateScene: (() -> Void)? = sceneChanged ? { [self] in
            scene.image = nextScene; scene.isHidden = false
            progressiveErasureActive = false; progressiveErasurePending = nil
            retainedNavigationBackdrop = acceptedBackdrop
            // Retirement is part of the successful image/Metal transaction,
            // not the earlier asynchronous raster completion/adoption.
            navigationView.clearContinuity()
            if let acceptedBackdrop {
                // Deleted completed contacts need no future fallback entry.
                // Keep unresolved or not-yet-published contacts until their
                // own authoritative row appears; never alter either queue.
                var stillRelevant = Set(objects.compactMap { $0["clientMutationId"] as? String ?? $0["id"] as? String })
                stillRelevant.formUnion(estimatedCompletions.ids)
                if let pending = completionBuffer.pending { stillRelevant.insert(pending.mutationID) }
                continuityLocalInkIDs.formIntersection(stillRelevant)
                continuityLocalInkIDs.subtract(acceptedBackdrop.continuityIdentifiers)
            }
            // The opaque crop now owns every completed stroke that was held
            // above the frozen tile revision. Live ink clears in this transaction.
            if let snapshot = navigationSnapshot {
                navigationBaseSnapshot = snapshot; navigationBaseTokens = objectVisualTokens
                navigationView.install(snapshot, mapper: mapper)
            }
            // A clear contains no live-ink timing callback. Publish the actual
            // installed scene after successful submission, including when the
            // last storage ACK arrived before this image/clear transaction.
            onSceneInstalled?()
        } : nil
        // Predictions extend the measured endpoint but never participate in
        // fitting its curve. Replacing a prediction cannot reshape real ink.
        guard hasLiveInk else {
            metal.strokes = []; metal.backdrop = nil; previewGeometry.reset()
            let submitStartedAt = CACurrentMediaTime()
            submitted = metal.submitFrame(synchronizedUpdate: updateScene)
            submitMS = (CACurrentMediaTime() - submitStartedAt) * 1000
            if submitted == false { schedulePreview() }
            return
        }
        let geometryStartedAt = CACurrentMediaTime()
        let polygons = previewGeometry.polygons(version: pending?.inkVersion ?? strokeInkVersion, points: points, predictions: predictions, width: style.width,
            aspect: mapper.geometry.height / mapper.geometry.width, highlighter: highlighter, fixedWidth: style.fixedWidth == true, heldShape: previewShape(pending))
        geometryMS = (CACurrentMediaTime() - geometryStartedAt) * 1000
        // Ordinary ink composites over the existing scene image. Uploading
        // that whole PDF raster for every pen stroke adds work before its
        // first point; only multiply-blended highlighter needs the texture.
        // One affine uniform replaces thousands of per-frame CPU point maps.
        let origin = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 0, y: 0, p: 0.5)))
        let xAxis = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 1, y: 0, p: 0.5)))
        let yAxis = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 0, y: 1, p: 0.5)))
        let transform = CGAffineTransform(a: xAxis.x-origin.x, b: xAxis.y-origin.y,
                                         c: yAxis.x-origin.x, d: yAxis.y-origin.y, tx: origin.x, ty: origin.y)
        metal.strokes = [.init(polygons: polygons, color: Self.color(style.color),
                               opacity: Float(style.opacity), multiply: highlighter, transform: transform,
                               retainedPrefixPolygonCount: previewGeometry.retainedPrefixPolygonCount,
                               geometryRevision: previewGeometry.revision)]
        #if targetEnvironment(simulator)
        // Simulator cannot report presentation timestamps. Retry a missing
        // submission, but never invent a physical-display measurement.
        let awaitingFirstPresentation = active != nil && contactTimings[inputSequence]?.firstSubmittedAt == nil
        #else
        let awaitingFirstPresentation = active != nil && contactTimings[inputSequence]?.firstPresentedAt == nil
        #endif
        if awaitingFirstPresentation, let contact = contactTimings[inputSequence] {
            metal.noteInputReceived(at: contact.beganAt, strokeID: inputSequence)
        }
        // A just-attached layer can drop its first drawable and notify us
        // several refreshes later. Keep offering the stationary first dot on
        // each frame until presentation is confirmed; do not wait for movement
        // or that delayed callback to reveal the start of the stroke.
        let submitStartedAt = CACurrentMediaTime()
        submitted = metal.submitFrame(synchronizedUpdate: updateScene)
        submitMS = (CACurrentMediaTime() - submitStartedAt) * 1000
        if submitted == false || awaitingFirstPresentation { schedulePreview() }
    }
    /// A finger gesture on this same page does not end a Pencil contact or
    /// finalize a provisional stroke. Explicit close/tool/offscreen flushes
    /// keep their existing, separate lifecycle policy.
    func prepareForNavigation() throws {
        guard active != nil, !["pen", "highlighter"].contains(strokeTool.name) else { return }
        if nativeEraseContact { try flushActiveStroke(); return }
        // Object edits retain their previous up-on-navigation behavior, but
        // must not drain the ink queues or clear a failed durability gate.
        let last = measured.last
        markContactEnded()
        completion?.cancel(); completion = nil; ending = false
        active = nil; measured = []; redrawLassoPreview(); predicted = []; estimated = [:]
        onInputOwnership?(false)
        if let last { publishPointer("up", points: [last]) }
        previewGeometry.reset(); schedulePreview()
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
        backdropDependencyNeedsReview = true
        holdTimer?.invalidate(); holdTimer = nil
        completion?.cancel(); completion = nil; ending = false; estimated = [:]
        if active != nil {
            markContactEnded()
            if ["pen", "highlighter"].contains(strokeTool.name), !measured.isEmpty {
                try completionBuffer.retain(.init(mutationID: UUID().uuidString,
                    kind: strokeTool.name == "pen" ? "ink" : "highlighter", points: measured, style: strokeTool.style, inkVersion: strokeInkVersion, holdSnap: holdSnap, heldShape: heldShape))
            } else if nativeEraseContact {
                if !cancelObjectEdit, !erasingTargets.isEmpty {
                    guard let onErase else { throw NativePDFError.invalid("지우개 저장 연결을 확인해 주세요.") }
                    do { try onErase(erasingTargets) }
                    catch {
                        // Keep this contact's exact targets for explicit flush
                        // retry; another contact cannot overwrite its preview.
                        journalBlocked = true; schedulePreview(); throw error
                    }
                }
                nativeEraseContact = false; erasingTargets = []; erasingKeys = []; eraserPreviousPoint = nil
            } else if let last = measured.last { publishPointer(cancelObjectEdit ? "cancel" : "up", points: [last]) }
            active = nil; predicted = []; measured = []; redrawLassoPreview()
            onInputOwnership?(false)
        }
        do {
            try completionBuffer.flush { stroke in
                guard let onStroke else { throw NativePDFError.invalid("필기 저장 연결을 확인해 주세요.") }
                retainedModel?.rememberLocalMutation(stroke.mutationID)
                try onStroke(stroke)
                if stroke.kind == "ink" { continuityLocalInkIDs.insert(stroke.mutationID) }
            }
            // Keep the last drawable until the next frame installs the
            // committed backdrop and clears live ink in the same frame tick.
            journalBlocked = false; previewGeometry.reset(); schedulePreview()
        } catch {
            // Model snapshots cannot unlock this independent durability gate.
            journalBlocked = true; schedulePreview(); throw error
        }
    }
    private func publishPointer(_ phase: String, points: [NativePDFPoint]) {
        if nativeEraseContact {
            if phase == "move" { updateNativeErasure(points: points) }
            return
        }
        guard !["pen", "highlighter"].contains(strokeTool.name), !points.isEmpty else { return }
        onPointer?(["phase": phase, "points": points.map { ["x": $0.x, "y": $0.y, "p": $0.p] }])
    }
    static func color(_ name: String) -> UIColor {
        switch name {
        case "canvasLightInk": UIColor(white: 0.94, alpha: 1)
        case "red": UIColor(red: 214/255, green: 36/255, blue: 46/255, alpha: 1)
        case "orange": UIColor(red: 240/255, green: 99/255, blue: 20/255, alpha: 1)
        case "yellow": UIColor(red: 245/255, green: 184/255, blue: 10/255, alpha: 1)
        case "green": UIColor(red: 26/255, green: 148/255, blue: 77/255, alpha: 1)
        case "blue": UIColor(red: 20/255, green: 97/255, blue: 224/255, alpha: 1)
        case "violet": UIColor(red: 125/255, green: 54/255, blue: 209/255, alpha: 1)
        default: UIColor(red: 20/255, green: 23/255, blue: 31/255, alpha: 1)
        }
    }
    func invalidateBackdrop(paper invalidatePaper: Bool = false, reason: String = "explicit") {
        if reason == "image" { retainedModelDirty = true }
        backdropDependencyNeedsReview = true
        if invalidatePaper { paper = nil }
        committedScene.invalidate(reason: reason)
        backdrop = nil; sceneDirty = true; decorations.setNeedsDisplay(); schedulePreview()
        scheduleNavigationSnapshot()
    }
    private func invalidateObjectScene() {
        retainedModelDirty = true
        backdropDependencyNeedsReview = true
        // Keep the rendered prefix. A new stroke or receipt must not force
        // every older stroke to be rasterized before the next Pencil dot.
        sceneDirty = true; decorations.setNeedsDisplay(); schedulePreview()
        scheduleNavigationSnapshot()
    }
    private func scheduleNavigationSnapshot() {
        if applyingObjects { return }
        if prepareRetainedScene() { return }
        navigationSnapshotDirty = true; navigationGeneration &+= 1
        guard navigationCaptureTask == nil else { return }
        navigationCaptureTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.navigationCaptureTask = nil
            self.updateNavigationSnapshot()
            if self.navigationDisplayActive { self.requestNavigationCrop() }
        }
    }
    private func updateNavigationSnapshot() {
        guard navigationSnapshotDirty, window != nil, let pdfPage, let mapper else { return }
        guard let snapshot = navigationBuilder.make(page: pdfPage, objects: objects, tokens: objectVisualTokens,
            highlights: highlights, image: { self.imageForObject?($0) }) else { return }
        navigationSnapshot = snapshot; navigationSnapshotDirty = false
        // Preparing a newer revision must not advance the visible tile base.
        // Its corresponding clear may still be waiting for a drawable; only
        // the successful scene-install transaction can retire the old preview.
        if navigationBaseSnapshot == nil {
            navigationBaseSnapshot = snapshot; navigationBaseTokens = objectVisualTokens
            navigationView.frame = bounds; navigationView.install(snapshot, mapper: mapper)
        }
    }
    private func requestNavigationCrop(urgent: Bool = false) {
        // Only viewport motion restarts the quiet interval. New strokes and
        // pressure corrections update the captured revision without starving
        // an already scheduled handoff during continuous writing.
        guard navigationDisplayActive else { return }
        if urgent {
            if navigationCropIsUrgent, navigationUrgentRequestedGeneration == navigationGeneration { return }
            navigationCropIsUrgent = true
            navigationCropTask?.cancel(); navigationCropTask = nil
        }
        let urgent = navigationCropIsUrgent
        if urgent {
            guard navigationUrgentRequestedGeneration != navigationGeneration else { return }
            navigationUrgentRequestedGeneration = navigationGeneration
        }
        guard navigationCropTask == nil else { return }
        navigationCropTask = Task { @MainActor [weak self] in
            // During a drag, let small visible tiles run ahead of a full crop.
            // Deceleration still moves the viewport after the finger lifts.
            do {
                if !urgent {
                    try await Task.sleep(for: .milliseconds(100))
                    while self?.navigationInProgress?() == true { try await Task.sleep(for: .milliseconds(50)) }
                }
            } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.navigationCropTask = nil
            guard self.navigationDisplayActive,
                  let mapper = self.mapper, let viewport = self.renderViewport else { return }
            self.updateNavigationSnapshot()
            guard let snapshot = self.navigationSnapshot,
                  let transform = NativePDFObjectRenderer.pageTransform(mapper) else { return }
            let generation = self.navigationGeneration
            let capturedObjects = self.objects, capturedTokens = self.objectVisualTokens, capturedHighlights = self.highlights
            guard let capturedContent = NativePDFRetainedInkBackdrop.Content(snapshot: snapshot, mapper: mapper,
                objects: capturedObjects, tokens: capturedTokens, highlights: capturedHighlights,
                imageForObject: { self.imageForObject?($0) }) else { return }
            let stableCount = self.mutableObjectStartIndex
            let request = NativePDFNavigationRasterizer.Request(snapshot: snapshot, bounds: viewport.canvasRect,
                scale: viewport.pixelScale, transform: transform, stablePrefixCount: stableCount) { [weak self] result in
                    guard let self else { return }
                    guard let result else {
                        self.navigationUrgentRequestedGeneration = nil
                        self.navigationRasterFailureCount += 1
                        if self.navigationRasterFailureCount <= 2, self.navigationGeneration == generation,
                           self.navigationDisplayActive, self.navigationCropTask == nil {
                            self.navigationCropTask = Task { @MainActor [weak self] in
                                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                                guard let self, !Task.isCancelled else { return }
                                self.navigationCropTask = nil
                                self.requestNavigationCrop()
                            }
                        } else if self.navigationRasterFailureCount == 3 {
                            self.onDiagnostic?("navigation.raster.failed")
                            self.onFailure?(NativePDFError.invalid("PDF 배경을 그리지 못했습니다. 페이지를 다시 열어 주세요."))
                        }
                        return
                    }
                    guard self.window != nil, self.renderViewport == viewport,
                          self.mapper?.canvasToPDF == mapper.canvasToPDF, self.mapper?.geometry == mapper.geometry,
                          self.navigationDisplayActive else { return }
                    if self.asynchronousEditDisplayActive, self.journalBlocked {
                        // A failed completion can already have a checkpoint
                        // row in the captured scene. Preserve the last front
                        // rather than install that row and draw it again as
                        // pending ink. A successful explicit flush schedules
                        // a fresh request for the still-retained raw input.
                        self.navigationUrgentRequestedGeneration = nil
                        return
                    }
                    self.updateNavigationSnapshot()
                    // A corrected provisional tail can replay from the captured
                    // stable checkpoint. Requiring every tail to stay unchanged
                    // would starve this handoff during continuous handwriting.
                    // Frozen-prefix, resource, highlight and paper changes still
                    // reject this raster, including mutable-container changes.
                    if self.queueProgressiveErasureCrop(result, content: capturedContent, mapper: mapper, viewport: viewport) {
                        return
                    }
                    guard let currentSnapshot = self.navigationSnapshot,
                          capturedContent.canReuse(snapshot: currentSnapshot, mapper: mapper,
                            objects: self.objects, tokens: self.objectVisualTokens, highlights: self.highlights,
                            imageForObject: { self.imageForObject?($0) }, stablePrefixCount: stableCount,
                            currentMutableStartIndex: self.mutableObjectStartIndex) else {
                        self.navigationUrgentRequestedGeneration = nil
                        self.navigationSnapshotDirty = true
                        self.requestNavigationCrop(); return
                    }
                    let paper = UIImage(cgImage: result.paper, scale: result.scale, orientation: .up)
                    let image = UIImage(cgImage: result.image, scale: result.scale, orientation: .up)
                    let prefix = result.prefix.map { UIImage(cgImage: $0, scale: result.scale, orientation: .up) }
                    guard self.committedScene.adopt(paper: paper, image: image, stablePrefixImage: prefix,
                        stablePrefixCount: result.prefixCount, mapper: mapper, bounds: viewport.canvasRect,
                        highlights: self.highlights, objects: capturedContent.cacheSeedRows,
                        visualTokens: capturedContent.cacheSeedTokens,
                        mutableObjectStartIndex: stableCount) else { return }
                    self.paper = paper; self.backdrop = image
                    let capturedAppearanceUnchanged = capturedContent.canReuse(snapshot: currentSnapshot, mapper: mapper,
                        objects: self.objects, tokens: self.objectVisualTokens, highlights: self.highlights,
                        imageForObject: { self.imageForObject?($0) })
                    self.sceneDirty = self.navigationGeneration != generation || !capturedAppearanceUnchanged
                    self.navigationDisplayActive = false
                    self.asynchronousEditDisplayActive = false
                    self.progressiveErasureActive = false; self.progressiveErasurePending = nil
                    self.navigationCropIsUrgent = false; self.navigationUrgentRequestedGeneration = nil
                    self.navigationRasterFailureCount = 0
                    self.onNavigationStateChanged?()
                    self.navigationPendingGeometry.removeAll()
                    self.reviewBackdropDependency()
                }
            if let supplied = self.suppliedNavigationRasterRequest { supplied(request) }
            else { self.navigationRasterizer.request(request) }
        }
    }
    /// Completed strokes after the frozen tile revision stay above those tiles
    /// until an opaque crop containing them is atomically installed. Replacing
    /// the current Pencil stroke must never erase the previous short contact.
    private func navigationCompletedStrokes(mapper: InkCoordinateMapper, viewport: NativePDFRenderViewport,
                                            prefixCount: Int? = nil) -> [NativePDFMetalInk.Stroke] {
        guard let start = prefixCount ?? navigationBaseSnapshot?.objects.count, let snapshot = navigationSnapshot,
              snapshot.objects.count >= start else { navigationPendingGeometry.removeAll(); return [] }
        let origin = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 0, y: 0, p: 0.5)))
        let x = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 1, y: 0, p: 0.5)))
        let y = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 0, y: 1, p: 0.5)))
        let transform = CGAffineTransform(a: x.x-origin.x, b: x.y-origin.y, c: y.x-origin.x, d: y.y-origin.y, tx: origin.x, ty: origin.y)
        var strokes: [NativePDFMetalInk.Stroke] = []
        var usedIdentities: Set<ObjectIdentifier> = []
        defer { navigationPendingGeometry.retainOnly(usedIdentities) }
        for index in start..<snapshot.objects.count {
            guard case let .path(path, color, opacity, multiply) = snapshot.objects[index].content else { continue }
            let token = objectVisualTokens.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            if let token { usedIdentities.insert(ObjectIdentifier(token)) }
            let polygons = navigationPendingGeometry.polygons(token: token, path: path, size: snapshot.size)
            strokes.append(.init(polygons: polygons, color: UIColor(cgColor: color), opacity: Float(opacity), multiply: multiply, transform: transform))
        }
        return strokes
    }
    private func stageMetalFrame(mapper: InkCoordinateMapper, viewport: NativePDFRenderViewport,
                                 presentingIn currentMapper: InkCoordinateMapper) {
        guard let geometry = NativePDFMetalInk.FrameGeometry(canvasRect: viewport.canvasRect,
            pixelScale: viewport.pixelScale, canvasToPage: mapper.canvasToPDF) else { return }
        _ = metal.stageFrame(geometry, presentingIn: currentMapper.canvasToPDF)
    }
    private func waitForNavigationCrop() {
        requestNavigationCrop(urgent: true)
        cancelBackdropWake()
        backdropAvailability = .notRequired; backdropDependencyNeedsReview = false
        needsPreview = false
    }
    private func currentNavigationContent(mapper: InkCoordinateMapper) -> NativePDFRetainedInkBackdrop.Content? {
        guard let snapshot = navigationSnapshot else { return nil }
        return NativePDFRetainedInkBackdrop.Content(snapshot: snapshot, mapper: mapper, objects: objects,
            tokens: objectVisualTokens, highlights: highlights, imageForObject: { self.imageForObject?($0) })
    }

    private func activateProgressiveErasureIfPossible() {
        guard !progressiveErasureActive, tool.name == "eraser", navigationInProgress?() != true,
              !scene.isHidden, completionBuffer.pending == nil, estimatedCompletions.isEmpty,
              let mapper, let viewport = renderViewport, let displayed = retainedNavigationBackdrop,
              scene.image === displayed.image, displayed.viewport == viewport,
              displayed.mapper.canvasToPDF == mapper.canvasToPDF else { return }
        updateNavigationSnapshot()
        guard let latest = currentNavigationContent(mapper: mapper),
              latest.prefixCount < displayed.prefixCount,
              latest.isDeletionSuccessor(of: displayed.content) else { return }
        progressiveErasureActive = true; progressiveErasurePending = nil
        asynchronousEditDisplayActive = true; navigationDisplayActive = true
    }

    /// Do not starve continuous erasing by requiring a worker to catch up to
    /// every pointer event. A strict deletion between displayed and latest is
    /// useful progress, but remains separate from the authoritative cache.
    private func queueProgressiveErasureCrop(_ result: NativePDFNavigationSnapshot.Raster,
        content: NativePDFRetainedInkBackdrop.Content, mapper: InkCoordinateMapper,
        viewport: NativePDFRenderViewport) -> Bool {
        guard progressiveErasureActive, !journalBlocked,
              let displayed = retainedNavigationBackdrop,
              displayed.viewport == viewport, displayed.mapper.canvasToPDF == mapper.canvasToPDF,
              let latest = currentNavigationContent(mapper: mapper),
              content.prefixCount < displayed.prefixCount, latest.prefixCount < content.prefixCount,
              content.isDeletionSuccessor(of: displayed.content), latest.isDeletionSuccessor(of: content)
        else { return false }
        if let pending = progressiveErasurePending,
           !content.isDeletionSuccessor(of: pending.content) { return true }
        let image = UIImage(cgImage: result.image, scale: result.scale, orientation: .up)
        guard let ready = NativePDFRetainedInkBackdrop(image: image, content: content, mapper: mapper, viewport: viewport)
        else { return false }
        progressiveErasurePending = ready
        schedulePreview()
        requestNavigationCrop(urgent: true)
        return true
    }

    private func validProgressiveErasureCrop(_ candidate: NativePDFRetainedInkBackdrop,
        mapper: InkCoordinateMapper, viewport: NativePDFRenderViewport) -> Bool {
        guard progressiveErasureActive, let displayed = retainedNavigationBackdrop,
              candidate.viewport == viewport, candidate.mapper.canvasToPDF == mapper.canvasToPDF,
              candidate.mapper.geometry == mapper.geometry,
              candidate.prefixCount < displayed.prefixCount,
              let latest = currentNavigationContent(mapper: mapper) else { return false }
        return candidate.content.isDeletionSuccessor(of: displayed.content) && latest.isDeletionSuccessor(of: candidate.content)
    }

    /// Keep the last complete image visible; never replace it with empty tiles.
    /// A switched-to ordinary pen and its completed local suffix stay above
    /// that image until an exact crop can retire them in the normal transaction.
    /// A highlighter cannot use this potentially stale image as a destination.
    private func renderProgressiveErasurePreview() -> (geometryMS: Double, submitMS: Double, submitted: Bool?) {
        let started = CACurrentMediaTime()
        guard !journalBlocked else { needsPreview = false; return (0, 0, nil) }
        updateNavigationSnapshot()
        guard let mapper, let viewport = renderViewport, let snapshot = navigationSnapshot,
              let displayed = retainedNavigationBackdrop else { needsPreview = false; return (0, 0, nil) }
        requestNavigationCrop(urgent: true)
        if let candidate = progressiveErasurePending,
           !validProgressiveErasureCrop(candidate, mapper: mapper, viewport: viewport) {
            progressiveErasurePending = nil
        }
        let candidate = progressiveErasurePending
        let nextDisplay = candidate ?? displayed
        let bakedIDs = nextDisplay.content.continuityIdentifiers
        let pending = completionBuffer.pending
        let points = previewPoints(pending)
        let style = pending?.style ?? strokeTool.style
        let highlighter = pending?.kind == "highlighter" || (pending == nil && strokeTool.name == "highlighter")
        let hasLiveInk = !points.isEmpty && (pending != nil || ["pen", "highlighter"].contains(strokeTool.name))
        let hasUnbakedMultiply = zip(objects, snapshot.objects).contains { object, command in
            let id = object["clientMutationId"] as? String ?? object["id"] as? String
            guard id.map({ !bakedIDs.contains($0) }) ?? true else { return false }
            if case .path(_, _, _, true) = command.content { return true }
            return false
        }
        if hasLiveInk && highlighter || hasUnbakedMultiply {
            // Preserve the last displayed frame and all measured/durable input.
            // The exact crop request above stays live even during texture retry.
            waitForNavigationCrop()
            return ((CACurrentMediaTime() - started) * 1000, 0, nil)
        }
        guard prepareFrameBackdrop(nil, required: false) else {
            return ((CACurrentMediaTime() - started) * 1000, 0, false)
        }
        stageMetalFrame(mapper: mapper, viewport: viewport, presentingIn: mapper)
        let origin = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 0, y: 0, p: 0.5)))
        let x = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 1, y: 0, p: 0.5)))
        let y = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 0, y: 1, p: 0.5)))
        let transform = CGAffineTransform(a: x.x-origin.x, b: x.y-origin.y, c: y.x-origin.x, d: y.y-origin.y,
            tx: origin.x, ty: origin.y)
        var strokes: [NativePDFMetalInk.Stroke] = []
        var used = Set<ObjectIdentifier>()
        for (index, object) in objects.enumerated() {
            guard let id = object["clientMutationId"] as? String ?? object["id"] as? String,
                  !bakedIDs.contains(id), continuityLocalInkIDs.contains(id),
                  case let .path(path, color, opacity, false) = snapshot.objects[index].content else { continue }
            let token = objectVisualTokens.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            if let token { used.insert(ObjectIdentifier(token)) }
            let polygons = navigationPendingGeometry.polygons(token: token, path: path, size: snapshot.size)
            strokes.append(.init(polygons: polygons, color: UIColor(cgColor: color), opacity: Float(opacity),
                multiply: false, transform: transform))
        }
        navigationPendingGeometry.retainOnly(used)
        if hasLiveInk {
            let polygons = previewGeometry.polygons(version: pending?.inkVersion ?? strokeInkVersion, points: points, predictions: pending == nil ? previewPredictions : [],
                width: style.width, aspect: mapper.geometry.height / mapper.geometry.width, highlighter: false, fixedWidth: style.fixedWidth == true, heldShape: previewShape(pending))
            strokes.append(.init(polygons: polygons, color: Self.color(style.color), opacity: Float(style.opacity),
                multiply: false, transform: transform, retainedPrefixPolygonCount: previewGeometry.retainedPrefixPolygonCount,
                geometryRevision: previewGeometry.revision))
        }
        metal.strokes = strokes
        let install: (() -> Void)? = candidate.map { candidate in { [self] in
            guard validProgressiveErasureCrop(candidate, mapper: mapper, viewport: viewport) else {
                progressiveErasurePending = nil; schedulePreview(); return
            }
            scene.image = candidate.image; scene.isHidden = false
            retainedNavigationBackdrop = candidate
            navigationBaseSnapshot = candidate.snapshot; navigationBaseTokens = candidate.content.cacheSeedTokens
            navigationView.isHidden = true; navigationView.clearContinuity()
            progressiveErasurePending = nil; progressiveErasureInstallCount += 1
            // Do not mutate paper/backdrop/cache here: they still describe the
            // earlier authoritative snapshot until the exact latest crop wins.
            onSceneInstalled?()
        } }
        if hasLiveInk, active != nil, let contact = contactTimings[inputSequence], contact.firstPresentedAt == nil {
            metal.noteInputReceived(at: contact.beganAt, strokeID: inputSequence)
        }
        needsPreview = false
        let geometryMS = (CACurrentMediaTime() - started) * 1000, submitStarted = CACurrentMediaTime()
        let submitted = metal.submitFrame(synchronizedUpdate: install, reportsInput: hasLiveInk)
        #if targetEnvironment(simulator)
        let awaitingFirst = hasLiveInk && active != nil && contactTimings[inputSequence]?.firstSubmittedAt == nil
        #else
        let awaitingFirst = hasLiveInk && active != nil && contactTimings[inputSequence]?.firstPresentedAt == nil
        #endif
        if !submitted || awaitingFirst { schedulePreview() }
        return (geometryMS, (CACurrentMediaTime() - submitStarted) * 1000, submitted)
    }

    /// Only entered after an existing settled scene needs a destructive full
    /// replay. A completed object belongs to the latest immutable tile base,
    /// while an ordinary active pen stays transparent above that base. This
    /// deliberately does not reuse an obsolete highlighter destination.
    private func renderAsynchronousEditPreview() -> (geometryMS: Double, submitMS: Double, submitted: Bool?) {
        if progressiveErasureActive { return renderProgressiveErasurePreview() }
        let geometryStarted = CACurrentMediaTime()
        guard !journalBlocked else {
            // Durability remains the input gate. Do not replace the old front
            // with tiles that may already contain this pending checkpoint,
            // nor blend its translucent pending stroke over itself.
            needsPreview = false
            return (0, 0, nil)
        }
        updateNavigationSnapshot()
        guard let mapper, let viewport = renderViewport, let snapshot = navigationSnapshot else {
            needsPreview = false; return (0, 0, nil)
        }
        requestNavigationCrop(urgent: true)
        let pending = completionBuffer.pending ?? (journalBlocked ? estimatedCompletions.first?.stroke : nil)
        let points = previewPoints(pending)
        let style = pending?.style ?? strokeTool.style
        let highlighter = pending?.kind == "highlighter" || (pending == nil && strokeTool.name == "highlighter")
        let hasLiveInk = !points.isEmpty && (pending != nil || ["pen", "highlighter"].contains(strokeTool.name))
        let hasOrdinaryInk = hasLiveInk && !highlighter
        let mustInstallTiles = navigationBaseSnapshot !== snapshot || !scene.isHidden
        // A stationary highlighter still owns all raw points, but its exact
        // opaque destination is pending. Do not submit an ordinary-alpha fake
        // or consume its first-input clock while waiting for the crop.
        guard mustInstallTiles || hasOrdinaryInk else {
            needsPreview = false
            return ((CACurrentMediaTime() - geometryStarted) * 1000, 0, nil)
        }
        guard prepareFrameBackdrop(nil, required: false) else {
            return ((CACurrentMediaTime() - geometryStarted) * 1000, 0, false)
        }
        stageMetalFrame(mapper: mapper, viewport: viewport, presentingIn: mapper)
        if hasOrdinaryInk {
            let polygons = previewGeometry.polygons(version: pending?.inkVersion ?? strokeInkVersion, points: points, predictions: pending == nil ? previewPredictions : [],
                width: style.width, aspect: mapper.geometry.height / mapper.geometry.width, highlighter: false, fixedWidth: style.fixedWidth == true, heldShape: previewShape(pending))
            let origin = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 0, y: 0, p: 0.5)))
            let x = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 1, y: 0, p: 0.5)))
            let y = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 0, y: 1, p: 0.5)))
            metal.strokes = [.init(polygons: polygons, color: Self.color(style.color), opacity: Float(style.opacity),
                multiply: false, transform: CGAffineTransform(a: x.x-origin.x, b: x.y-origin.y,
                    c: y.x-origin.x, d: y.y-origin.y, tx: origin.x, ty: origin.y),
                retainedPrefixPolygonCount: previewGeometry.retainedPrefixPolygonCount,
                geometryRevision: previewGeometry.revision)]
        } else { metal.strokes = [] }
        let tokens = objectVisualTokens
        let install: (() -> Void)? = mustInstallTiles ? { [self] in
            // This closure only runs after encoding and drawable submission
            // have succeeded. The old opaque/live frame must not survive over
            // the new revision, nor may it clear before that revision exists.
            navigationView.frame = bounds
            navigationView.retainContinuity(retainedNavigationBackdrop, mapper: mapper, viewport: viewport)
            navigationView.updateContinuity(snapshot: snapshot, objects: objects, tokens: objectVisualTokens,
                localInkIDs: continuityLocalInkIDs)
            navigationView.install(snapshot, mapper: mapper); navigationView.isHidden = false
            navigationBaseSnapshot = snapshot; navigationBaseTokens = tokens
            retainedNavigationBackdrop = nil; scene.isHidden = true
            navigationPendingGeometry.removeAll()
            asynchronousEditTileInstallCount += 1
            onSceneInstalled?()
        } : nil
        if hasOrdinaryInk, active != nil, let contact = contactTimings[inputSequence], contact.firstPresentedAt == nil {
            metal.noteInputReceived(at: contact.beganAt, strokeID: inputSequence)
        }
        needsPreview = false
        let geometryMS = (CACurrentMediaTime() - geometryStarted) * 1000
        let submissionStarted = CACurrentMediaTime()
        let submitted = metal.submitFrame(synchronizedUpdate: install, reportsInput: hasOrdinaryInk)
        #if targetEnvironment(simulator)
        let awaitingFirst = hasOrdinaryInk && active != nil && contactTimings[inputSequence]?.firstSubmittedAt == nil
        #else
        let awaitingFirst = hasOrdinaryInk && active != nil && contactTimings[inputSequence]?.firstPresentedAt == nil
        #endif
        if !submitted || awaitingFirst { schedulePreview() }
        return (geometryMS, (CACurrentMediaTime() - submissionStarted) * 1000, submitted)
    }
    private func renderNavigationPreview() -> (geometryMS: Double, submitMS: Double, submitted: Bool?) {
        let geometryStarted = CACurrentMediaTime()
        updateNavigationSnapshot()
        guard let mapper, let viewport = renderViewport else { needsPreview = false; return (0,0,nil) }
        let pending = completionBuffer.pending ?? (journalBlocked ? estimatedCompletions.first?.stroke : nil)
        let points = previewPoints(pending)
        let style = pending?.style ?? strokeTool.style
        let highlighter = pending?.kind == "highlighter" || (pending == nil && strokeTool.name == "highlighter")
        let hasLiveInk = !points.isEmpty && (pending != nil || ["pen", "highlighter"].contains(strokeTool.name))
        // Decide dependencies from immutable command metadata before rebuilding
        // paths. A following pen still needs the unadopted highlighter suffix.
        let suffix = navigationSnapshot.map { snapshot in
            snapshot.objects.dropFirst(navigationBaseSnapshot?.objects.count ?? snapshot.objects.count)
        }
        let hasCompletedMultiply = suffix?.contains { command in
            if case .path(_, _, _, let multiply) = command.content { return multiply }; return false
        } ?? false
        let needsOpaqueBase = hasCompletedMultiply || hasLiveInk && highlighter
        let retained = retainedNavigationBackdrop
        let canReuse = retained.flatMap { retained in
            navigationSnapshot.map { snapshot in
                retained.canReuse(snapshot: snapshot, mapper: mapper, objects: objects, tokens: objectVisualTokens,
                    highlights: highlights, imageForObject: { self.imageForObject?($0) })
            }
        } ?? false
        if suffix?.contains(where: { command in
            if case .path = command.content { return false }; return true
        }) == true {
            waitForNavigationCrop()
            return ((CACurrentMediaTime()-geometryStarted)*1000,0,nil)
        }
        // Undo, a corrected frozen-prefix row or a changed PDF background must
        // never leave stale pixels under newly composited ink. Crop work is
        // allowed even when a previous texture's recovery is exhausted.
        if (retained != nil && !canReuse) || needsOpaqueBase && retained == nil {
            waitForNavigationCrop()
            return ((CACurrentMediaTime()-geometryStarted)*1000,0,nil)
        }
        if needsOpaqueBase, let retained, let snapshot = navigationSnapshot {
            guard snapshot.objects.dropFirst(retained.prefixCount).allSatisfy({ command in
                if case .path = command.content { return true }; return false
            }) else {
                waitForNavigationCrop()
                return ((CACurrentMediaTime()-geometryStarted)*1000,0,nil)
            }
            guard prepareFrameBackdrop(retained.image.cgImage, required: true) else {
                // The first stationary point may already lie outside the old
                // crop. Its initial append preceded this failure state, so it
                // cannot rely on another move to request an exact destination.
                // One urgent capture per generation is also a bounded escape
                // from a failed retained texture; adoption leaves navigation.
                requestNavigationCrop(urgent: true)
                return ((CACurrentMediaTime()-geometryStarted)*1000,0,false)
            }
        } else {
            guard prepareFrameBackdrop(nil, required: false) else {
                return ((CACurrentMediaTime()-geometryStarted)*1000,0,false)
            }
        }
        let polygons = hasLiveInk ? previewGeometry.polygons(version: pending?.inkVersion ?? strokeInkVersion, points: points, predictions: pending == nil ? previewPredictions : [],
            width: style.width, aspect: mapper.geometry.height / mapper.geometry.width, highlighter: highlighter, fixedWidth: style.fixedWidth == true, heldShape: previewShape(pending)) : []
        func liveStroke(mapper: InkCoordinateMapper, viewport: NativePDFRenderViewport) -> NativePDFMetalInk.Stroke {
            let origin = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 0, y: 0, p: 0.5)))
            let x = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 1, y: 0, p: 0.5)))
            let y = viewport.localPoint(mapper.canvasPoint(InkPoint(x: 0, y: 1, p: 0.5)))
            return .init(polygons: polygons, color: Self.color(style.color), opacity: Float(style.opacity), multiply: highlighter,
                transform: CGAffineTransform(a: x.x-origin.x, b: x.y-origin.y, c: y.x-origin.x, d: y.y-origin.y, tx: origin.x, ty: origin.y),
                retainedPrefixPolygonCount: previewGeometry.retainedPrefixPolygonCount, geometryRevision: previewGeometry.revision)
        }
        var strokes: [NativePDFMetalInk.Stroke]
        var reportsInput = true
        if needsOpaqueBase, let retained, canReuse {
            strokes = navigationCompletedStrokes(mapper: retained.mapper, viewport: retained.viewport,
                prefixCount: retained.prefixCount)
            if hasLiveInk { strokes.append(liveStroke(mapper: retained.mapper, viewport: retained.viewport)) }
            if !strokes.allSatisfy({ retained.contains(normalizedPolygons: $0.polygons) }) {
                requestNavigationCrop(urgent: true)
            }
            reportsInput = hasLiveInk && retained.contains(normalizedPolygons: polygons)
            navigationBaseSnapshot = retained.snapshot
            navigationView.install(retained.snapshot, mapper: mapper)
            stageMetalFrame(mapper: retained.mapper, viewport: retained.viewport, presentingIn: mapper)
        } else {
            strokes = navigationCompletedStrokes(mapper: mapper, viewport: viewport)
            if hasLiveInk { strokes.append(liveStroke(mapper: mapper, viewport: viewport)) }
            stageMetalFrame(mapper: mapper, viewport: viewport, presentingIn: mapper)
        }
        metal.strokes = strokes
        if active != nil, let contact = contactTimings[inputSequence], contact.firstPresentedAt == nil {
            metal.noteInputReceived(at: contact.beganAt, strokeID: inputSequence)
        }
        needsPreview = false
        let geometryMS = (CACurrentMediaTime()-geometryStarted)*1000
        let submitStarted = CACurrentMediaTime(), submitted = metal.submitFrame(reportsInput: reportsInput)
        #if targetEnvironment(simulator)
        let awaitingFirst = active != nil && contactTimings[inputSequence]?.firstSubmittedAt == nil
        #else
        let awaitingFirst = active != nil && contactTimings[inputSequence]?.firstPresentedAt == nil
        #endif
        if !submitted || awaitingFirst { schedulePreview() }
        return (geometryMS,(CACurrentMediaTime()-submitStarted)*1000,submitted)
    }
    private var mutableObjectStartIndex: Int {
        let pendingIDs = Set(estimatedCompletions.ids)
        guard !pendingIDs.isEmpty else { return objects.count }
        return objects.firstIndex { object in
            (object["clientMutationId"] as? String).map(pendingIDs.contains) == true ||
                (object["id"] as? String).map(pendingIDs.contains) == true
        } ?? 0
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
            backdrop = committedScene.render(paper: paper, mapper: mapper, bounds: viewport.canvasRect,
                highlights: highlights, objects: objects,
                visualTokens: objectVisualTokens,
                mutableObjectStartIndex: mutableObjectStartIndex,
                allowFullReplay: committedScene.image == nil,
                drawHighlights: { self.drawCommittedHighlights(in: $0, mapper: mapper) },
                drawObject: { object, context in
                    NativePDFObjectRenderer.draw(object, in: context, mapper: mapper, image: self.imageForObject?(object))
                })
            if committedScene.deferredFullReplay {
                // The prior cache is still usable as an immutable displayed
                // revision. A new tile base replaces it only on successful
                // Metal handoff; its full opaque crop is built off-main.
                asynchronousEditDisplayActive = true; navigationDisplayActive = true
                updateNavigationSnapshot()
                activateProgressiveErasureIfPossible()
                requestNavigationCrop(urgent: true)
                return nil
            }
            sceneDirty = false
            if committedScene.lastRenderMode == "reuse" {
                refreshRetainedIdentityForDisplayedReuse(mapper: mapper, viewport: viewport)
            }
        }
        return backdrop
    }

    /// Canonical and editor scenes can use different receipt associations for
    /// the same saved rows. When this render reused the image already visible,
    /// carry those identities forward too, so a later deletion can prove its
    /// surviving prefix. Never relabel a newer cache awaiting its Metal clear.
    private func refreshRetainedIdentityForDisplayedReuse(mapper: InkCoordinateMapper,
                                                         viewport: NativePDFRenderViewport) {
        guard !scene.isHidden, let backdrop, let displayed = retainedNavigationBackdrop,
              backdrop === committedScene.image, backdrop === scene.image, backdrop === displayed.image,
              displayed.viewport == viewport, displayed.mapper.geometry == mapper.geometry,
              displayed.mapper.canvasToPDF == mapper.canvasToPDF else { return }
        updateNavigationSnapshot()
        // Cache reuse alone does not prove resolved image resources unchanged.
        // A successfully refreshed immutable snapshot additionally proves paper,
        // ordered appearance, highlights, and every resolved image are identical.
        guard !navigationSnapshotDirty, let snapshot = navigationSnapshot,
              snapshot === displayed.snapshot,
              let refreshed = NativePDFRetainedInkBackdrop(image: backdrop, snapshot: snapshot,
                  mapper: mapper, viewport: viewport, objects: objects, tokens: objectVisualTokens,
                  highlights: highlights, imageForObject: { self.imageForObject?($0) }) else { return }
        retainedNavigationBackdrop = refreshed
    }
    private func drawCommittedHighlights(in context: CGContext, mapper: InkCoordinateMapper) {
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
    }
    private func redrawLassoPreview() { if strokeTool.name == "lasso" || tool.name == "lasso" { decorations.setNeedsDisplay() } }
    private func drawDecorations(in context: CGContext) {
        guard let mapper else { return }
        func point(_ x: Double, _ y: Double) -> CGPoint { mapper.canvasPoint(InkPoint(x: x, y: y, p: 0.5)) }
        func roundHandle(_ center: CGPoint) {
            let handle = CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
            context.setFillColor(UIColor.systemBlue.cgColor); context.fillEllipse(in: handle)
            context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(2); context.strokeEllipse(in: handle.insetBy(dx: 1, dy: 1))
            context.setStrokeColor(UIColor.systemBlue.cgColor); context.setLineWidth(1)
        }
        if active != nil, strokeTool.name == "lasso", measured.count > 1, let first = measured.first, let last = measured.last {
            let path = CGMutablePath()
            if strokeTool.lassoBox {
                let a = point(first.x, first.y), b = point(last.x, last.y)
                path.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
            } else {
                path.move(to: point(first.x, first.y)); for sample in measured.dropFirst() { path.addLine(to: point(sample.x, sample.y)) }; path.closeSubpath()
            }
            context.setStrokeColor(UIColor.systemBlue.cgColor); context.setLineWidth(1.5); context.setLineDash(phase: 0, lengths: [6, 4])
            context.addPath(path); context.strokePath(); context.setLineDash(phase: 0, lengths: [])
        }
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
                centers.forEach(roundHandle)
            }
        }
        if let frame = textEditorLocalFrame {
            context.setStrokeColor(UIColor.systemBlue.cgColor); context.setLineWidth(1); context.stroke(frame)
            [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY),
             CGPoint(x: frame.minX, y: frame.midY), CGPoint(x: frame.maxX, y: frame.midY)].forEach(roundHandle)
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
