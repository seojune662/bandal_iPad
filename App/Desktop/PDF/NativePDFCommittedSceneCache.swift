import UIKit

/// Minted by the native drawing store after ingesting a row, never read from
/// an untrusted object dictionary. Its appearance snapshot is immutable even
/// if the original payload contained mutable Foundation containers.
@MainActor
final class NativePDFCommittedVisualToken {
    fileprivate let visual: [String: Any]
    fileprivate let canReuseIdentity: Bool

    init(object: [String: Any]) {
        let snapshot = NativePDFCommittedSceneCache.snapshot(object,
            keys: ["kind", "data", "style", "nativePath"])
        visual = snapshot.value; canReuseIdentity = snapshot.identitySafe
    }
    init(validatedJSON: NativePDFValidatedDrawingJSON) {
        var appearance: [String: Any] = [:]
        for key in ["kind", "data", "style", "nativePath"] {
            appearance[key] = validatedJSON.value[key]
        }
        visual = appearance; canReuseIdentity = true
    }
    func hasSameAppearance(as other: NativePDFCommittedVisualToken) -> Bool {
        if self === other, canReuseIdentity { return true }
        return NativePDFCommittedSceneCache.equal(visual, other.visual)
    }
}

/// Retains the opaque, viewport-sized completed scene. Appending a stroke
/// composites only new objects over those pixels; a longer page no longer
/// replays every previous CGPath before the next Pencil contact can render.
@MainActor
final class NativePDFCommittedSceneCache {
    private var paper: UIImage?
    private var canvasToPDF: CGAffineTransform?
    private var geometry: InkPageGeometry?
    private var bounds: CGRect?
    private var objectVisuals: [[String: Any]] = []
    private var visualTokens: [NativePDFCommittedVisualToken]?
    private var objectIdentifiers: [String?] = []
    private var stablePrefixImage: UIImage?
    private var stablePrefixCount = 0
    private let mutableTailCount = 4
    private var highlightVisuals: [[String: Any]] = []
    private(set) var image: UIImage?
    private(set) var lastDrawnObjectCount = 0
    private(set) var fullRenderCount = 0
    private(set) var appendRenderCount = 0
    private(set) var reuseCount = 0
    private(set) var tailRenderCount = 0
    private(set) var adoptCount = 0
    private(set) var lastRenderMode = "none"
    private(set) var lastReplayStartIndex = 0
    private(set) var lastCheckpointDrawnObjectCount = 0
    private(set) var lastRenderElapsedMS = 0.0
    private(set) var lastComparedVisualPayloadCount = 0
    private(set) var lastFullRenderReason = "none"
    private(set) var lastInvalidationReason = "initial"
    /// Explicit metadata-only outcome. No pixels or accepted scene identity
    /// changed when the owner elected to render a full replacement off-main.
    private(set) var deferredFullReplay = false
    private(set) var deferredFullReplayCount = 0

    /// External image-resource changes can alter pixels without changing an
    /// object's source payload. The owner must invalidate for those updates.
    func invalidate(reason: String = "explicit") {
        lastInvalidationReason = String(reason.prefix(40))
        paper = nil; image = nil; canvasToPDF = nil; geometry = nil; bounds = nil
        objectVisuals = []; visualTokens = nil; objectIdentifiers = []; highlightVisuals = []; lastDrawnObjectCount = 0
        stablePrefixImage = nil; stablePrefixCount = 0
        lastRenderMode = "invalidated"; lastReplayStartIndex = 0; lastCheckpointDrawnObjectCount = 0
        lastComparedVisualPayloadCount = 0
        deferredFullReplay = false
    }

    /// Installs one already-rendered immutable navigation revision. The owner
    /// must reject stale viewport/revision generations before calling. Both
    /// bitmaps and visual rows must come from that same captured snapshot.
    /// Invalid input leaves the currently usable scene untouched.
    @discardableResult
    func adopt(paper: UIImage, image: UIImage, stablePrefixImage: UIImage?, stablePrefixCount: Int,
               mapper: InkCoordinateMapper, bounds: CGRect, highlights: [[String: Any]],
               objects: [[String: Any]], visualTokens suppliedTokens: [NativePDFCommittedVisualToken]? = nil,
               mutableObjectStartIndex: Int? = nil) -> Bool {
        let requestedPrefixCount = mutableObjectStartIndex ?? max(0, objects.count - mutableTailCount)
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height, paper.scale].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, paper.scale > 0,
              (0...objects.count).contains(requestedPrefixCount), stablePrefixCount == requestedPrefixCount,
              (stablePrefixCount > 0) == (stablePrefixImage != nil),
              let paperCG = paper.cgImage else { return false }
        let pixelWidth = ceil(bounds.width * paper.scale), pixelHeight = ceil(bounds.height * paper.scale)
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              CGFloat(paperCG.width) == pixelWidth, CGFloat(paperCG.height) == pixelHeight else { return false }
        for bitmap in [paper, image] + (stablePrefixImage.map { [$0] } ?? []) {
            guard bitmap.scale == paper.scale, bitmap.imageOrientation == .up, let cg = bitmap.cgImage,
                  cg.width == paperCG.width, cg.height == paperCG.height else { return false }
        }
        let started = CACurrentMediaTime()
        let tokens = suppliedTokens?.count == objects.count ? suppliedTokens : nil
        let visuals = tokens?.map(\.visual) ?? objects.map { Self.snapshot($0, keys: ["kind", "data", "style", "nativePath"]).value }
        let highlightVisuals = highlights.map { Self.snapshot($0, keys: ["rects", "color", "nativeColor", "nativeOpacity"]).value }
        self.paper = paper; self.image = image; self.canvasToPDF = mapper.canvasToPDF; self.geometry = mapper.geometry; self.bounds = bounds
        self.stablePrefixImage = stablePrefixImage; self.stablePrefixCount = stablePrefixCount
        objectVisuals = visuals; visualTokens = tokens
        objectIdentifiers = objects.map { $0["clientMutationId"] as? String ?? $0["id"] as? String }
        self.highlightVisuals = highlightVisuals
        lastRenderMode = "adopt"; lastReplayStartIndex = objects.count
        lastDrawnObjectCount = 0; lastCheckpointDrawnObjectCount = 0; lastComparedVisualPayloadCount = 0
        adoptCount += 1; lastRenderElapsedMS = (CACurrentMediaTime() - started) * 1000
        deferredFullReplay = false
        return true
    }

    /// Call only when the scene is dirty. Closures draw in the original canvas
    /// coordinate space; the bounded bitmap's origin is translated here once.
    func render(paper: UIImage, mapper: InkCoordinateMapper, bounds: CGRect,
                highlights: [[String: Any]], objects: [[String: Any]],
                visualTokens suppliedTokens: [NativePDFCommittedVisualToken]? = nil,
                mutableObjectStartIndex: Int? = nil,
                allowFullReplay: Bool = true,
                drawHighlights: (CGContext) -> Void,
                drawObject: ([String: Any], CGContext) -> Void) -> UIImage? {
        let renderStartedAt = CACurrentMediaTime()
        defer { lastRenderElapsedMS = (CACurrentMediaTime() - renderStartedAt) * 1000 }
        lastDrawnObjectCount = 0; lastComparedVisualPayloadCount = 0; lastCheckpointDrawnObjectCount = 0
        deferredFullReplay = false
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height, paper.scale].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, paper.scale > 0 else { invalidate(); return nil }
        // Dedicated native tokens refer to immutable, validated appearance.
        // The dictionary API still snapshots the actual payload, so a copied
        // stale _nativeInk reference cannot conceal an edited raw point.
        let nextTokens = suppliedTokens?.count == objects.count ? suppliedTokens : nil
        let nextObjects = nextTokens?.map(\.visual) ?? objects.map {
            Self.snapshot($0, keys: ["kind", "data", "style", "nativePath"]).value
        }
        let nextIdentifiers = objects.map { $0["clientMutationId"] as? String ?? $0["id"] as? String }
        // The input owner can retain every unresolved UIKit estimate, even
        // across more than four quick contacts. Invalid boundaries retain all
        // objects rather than accidentally freezing still-mutable pressure.
        let nextPrefixCount = mutableObjectStartIndex.map { (0...objects.count).contains($0) ? $0 : 0 }
            ?? max(0, objects.count - mutableTailCount)
        let promoteRenderedImage = mutableObjectStartIndex != nil && nextPrefixCount == objects.count
        let nextHighlights = highlights.map { Self.snapshot($0, keys: ["rects", "color", "nativeColor", "nativeOpacity"]).value }
        let sameBase = self.paper === paper && self.canvasToPDF == mapper.canvasToPDF &&
            self.geometry == mapper.geometry && self.bounds == bounds &&
            Self.equal(highlightVisuals, nextHighlights)
        var commonPrefix = 0
        if sameBase, image != nil {
            while commonPrefix < min(objectVisuals.count, nextObjects.count) {
                let index = commonPrefix
                if let old = visualTokens?[index], let new = nextTokens?[index], old === new, new.canReuseIdentity {
                    commonPrefix += 1; continue
                }
                lastComparedVisualPayloadCount += 1
                guard Self.equal(objectVisuals[index], nextObjects[index]) else { break }
                commonPrefix += 1
            }
        }
        let checkpointCoversBoundary = stablePrefixCount <= nextPrefixCount
        let appendOnly = sameBase && image != nil && checkpointCoversBoundary &&
            objectVisuals.count <= nextObjects.count && commonPrefix == objectVisuals.count
        if appendOnly, objectVisuals.count == nextObjects.count {
            // Transport ACKs can replace IDs/tokens without changing pixels.
            objectVisuals = nextObjects; visualTokens = nextTokens; objectIdentifiers = nextIdentifiers
            if promoteRenderedImage {
                // Finalization changes no pixels. Reuse the complete opaque
                // scene itself; do not repaint every newly resolved object.
                stablePrefixImage = objects.isEmpty ? nil : image
                stablePrefixCount = objects.count
            }
            lastRenderMode = "reuse"; lastReplayStartIndex = objects.count; reuseCount += 1
            return image
        }
        // UIKit can correct pressure after lift, including while the next
        // stroke starts. One opaque checkpoint excludes unresolved objects
        // (or the latest four for callers without input lifecycle knowledge).
        // Earlier edits, deletion and reordering deliberately rebuild.
        let sameTailOrder = objectVisuals.count <= nextObjects.count &&
            (stablePrefixCount..<objectVisuals.count).allSatisfy { index in
                objectIdentifiers[index] != nil && objectIdentifiers[index] == nextIdentifiers[index]
            }
        let hasUsablePrefix = stablePrefixImage != nil || (stablePrefixCount == 0 && mutableObjectStartIndex != nil)
        let tailCorrection = !appendOnly && sameBase && checkpointCoversBoundary && hasUsablePrefix &&
            commonPrefix >= stablePrefixCount && sameTailOrder
        let fullReplay = !appendOnly && !tailCorrection
        if fullReplay {
            if image == nil { lastFullRenderReason = "invalidated.\(lastInvalidationReason)" }
            else if self.paper !== paper { lastFullRenderReason = "paper" }
            else if self.canvasToPDF != mapper.canvasToPDF { lastFullRenderReason = "mapper" }
            else if self.geometry != mapper.geometry { lastFullRenderReason = "geometry" }
            else if self.bounds != bounds { lastFullRenderReason = "bounds" }
            else if !Self.equal(highlightVisuals, nextHighlights) { lastFullRenderReason = "highlights" }
            else if !checkpointCoversBoundary { lastFullRenderReason = "mutableBoundary" }
            else if nextObjects.count < objectVisuals.count { lastFullRenderReason = "deletion" }
            else if !sameTailOrder { lastFullRenderReason = "tailOrder" }
            else { lastFullRenderReason = "appearance.\(commonPrefix)" }
        }
        if fullReplay, !allowFullReplay {
            // All comparisons above are read-only. In particular, retain the
            // previous checkpoint, row identities and full image until an
            // immutable replacement has actually been rasterized and adopted.
            deferredFullReplay = true; deferredFullReplayCount += 1
            lastRenderMode = "deferred"; lastReplayStartIndex = 0
            return nil
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = paper.scale; format.opaque = true
        func raster(previous: UIImage?, range: Range<Int>) -> UIImage {
            UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
                let context = renderer.cgContext
                // Both paper and retained scene images already have the
                // target pixel dimensions. Copy at native size so fractional
                // logical crops never resample the PDF or committed ink.
                context.saveGState(); context.interpolationQuality = .none
                (previous ?? paper).draw(at: .zero, blendMode: .copy, alpha: 1)
                context.restoreGState()
                context.translateBy(x: -bounds.minX, y: -bounds.minY)
                if previous == nil { drawHighlights(context) }
                for index in range { drawObject(objects[index], context) }
            }
        }
        if promoteRenderedImage {
            // Render from the already-retained prefix, then promote the final
            // pixels below. This also avoids replaying matured objects twice
            // when the last pressure correction and finalization coincide.
            if fullReplay { stablePrefixImage = nil; stablePrefixCount = 0 }
        } else if nextPrefixCount > 0 {
            let retainPrefix = !fullReplay && stablePrefixImage != nil && commonPrefix >= stablePrefixCount &&
                stablePrefixCount <= nextPrefixCount
            let prefixStart = retainPrefix ? stablePrefixCount : 0
            if !retainPrefix || prefixStart < nextPrefixCount {
                stablePrefixImage = raster(previous: retainPrefix ? stablePrefixImage : nil, range: prefixStart..<nextPrefixCount)
                lastCheckpointDrawnObjectCount = nextPrefixCount - prefixStart
            }
            stablePrefixCount = nextPrefixCount
        } else {
            stablePrefixImage = nil; stablePrefixCount = 0
        }
        let start = appendOnly ? objectVisuals.count : stablePrefixCount
        let previous = appendOnly ? image : stablePrefixImage
        let rendered = raster(previous: previous, range: start..<objects.count)
        if promoteRenderedImage {
            stablePrefixImage = objects.isEmpty ? nil : rendered
            stablePrefixCount = objects.count
        }
        if appendOnly { appendRenderCount += 1; lastRenderMode = "append" }
        else if tailCorrection { tailRenderCount += 1; lastRenderMode = "tail" }
        else { fullRenderCount += 1; lastRenderMode = "full" }
        lastReplayStartIndex = fullReplay ? 0 : start
        lastDrawnObjectCount = lastCheckpointDrawnObjectCount + objects.count - start
        self.paper = paper; self.canvasToPDF = mapper.canvasToPDF; self.geometry = mapper.geometry; self.bounds = bounds
        objectVisuals = nextObjects; visualTokens = nextTokens; objectIdentifiers = nextIdentifiers
        highlightVisuals = nextHighlights; image = rendered
        return rendered
    }

    fileprivate static func snapshot(_ source: [String: Any], keys: [String]) -> (value: [String: Any], identitySafe: Bool) {
        var result: [String: Any] = [:], identitySafe = true
        for key in keys { if let value = source[key] { result[key] = freeze(value, identitySafe: &identitySafe) } }
        return (result, identitySafe)
    }

    private static func freeze(_ value: Any, identitySafe: inout Bool) -> Any {
        if let number = value as? NSNumber { return number }
        if let string = value as? String { return string }
        if value is NSNull { return NSNull() }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { freeze($0, identitySafe: &identitySafe) }
        }
        if let array = value as? [Any] { return array.map { freeze($0, identitySafe: &identitySafe) } }
        identitySafe = false
        return value
    }

    /// NSDictionary.isEqual treats NSNumber(true) and NSNumber(1) alike, but
    /// the renderer deliberately rejects booleans as widths/opacities. Keep
    /// JSON types distinct while accepting equivalent finite numeric boxes.
    fileprivate static func equal(_ left: Any, _ right: Any) -> Bool {
        if let a = left as? NSNumber, let b = right as? NSNumber {
            guard (CFGetTypeID(a) == CFBooleanGetTypeID()) == (CFGetTypeID(b) == CFBooleanGetTypeID()) else { return false }
            // Foundation may preserve decimal spelling while JavaScript
            // transports a binary Double. NSNumber equality can therefore
            // reject an ACK whose rendered coordinates/pressure are identical.
            // Match the renderer's numeric representation exactly: no epsilon
            // or rounding may hide an actual measured-value change.
            let x = a.doubleValue, y = b.doubleValue
            return x.isFinite && y.isFinite && x == y
        }
        if let a = left as? String, let b = right as? String { return a == b }
        if left is NSNull, right is NSNull { return true }
        if let a = left as? [String: Any], let b = right as? [String: Any] {
            return a.count == b.count && a.allSatisfy { key, value in b[key].map { equal(value, $0) } ?? false }
        }
        if let a = left as? [Any], let b = right as? [Any] {
            return a.count == b.count && zip(a, b).allSatisfy { equal($0, $1) }
        }
        // Unknown/non-JSON render payloads cannot prove an unchanged scene.
        return false
    }
}
