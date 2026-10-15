import UIKit
import Metal

/// Immutable object capture on MainActor, pure CG replay on one worker, and
/// resource publication only. This cache never installs a scene or retires ink.
@MainActor
final class NativePDFRetainedObjectTextures {
    final class Source {
        let visualToken: NativePDFCommittedVisualToken
        let resolvedImage: UIImage?
        let pageSize: CGSize
        let bounds: CGRect
        let multiply: Bool
        let recordingBytes: Int
        /// Conservative retained JSON/image ownership charge, not process RSS.
        let byteCost: Int
        fileprivate let command: NativePDFNavigationSnapshot.Command
        fileprivate init(token: NativePDFCommittedVisualToken, image: UIImage?, pageSize: CGSize,
                         bounds: CGRect, multiply: Bool, bytes: Int, byteCost: Int, command: NativePDFNavigationSnapshot.Command) {
            visualToken = token; resolvedImage = image; self.pageSize = pageSize
            self.bounds = bounds; self.multiply = multiply; recordingBytes = bytes
            self.byteCost = byteCost; self.command = command
        }
    }
    struct Request {
        let source: Source
        let scale: CGFloat
        init(source: Source, scale: CGFloat) { self.source = source; self.scale = scale }
    }
    struct Resource {
        let texture: NativePDFRetainedInkRenderer.Texture
        /// Pixel-aligned physical coordinates in the display-oriented page.
        /// Normalize by Source.pageSize exactly once before the viewport map.
        let bounds: CGRect
        let effectiveScale: CGFloat
    }
    enum Status: Equatable { case pending, ready, unavailable }
    struct Work: @unchecked Sendable {
        let command: NativePDFNavigationSnapshot.Command
        let bounds: CGRect
        let scale: CGFloat
        let width: Int
        let height: Int
        var byteCount: Int { width * height * 4 }
        fileprivate func matches(_ other: Work) -> Bool {
            bounds == other.bounds && scale == other.scale && width == other.width && height == other.height
        }
    }
    struct Bitmap: Sendable {
        let bytes: Data
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }
    typealias Rasterizer = @Sendable (Work) async -> Bitmap?
    private final class Entry {
        let source: Source
        var work: Work?
        var resource: Resource?
        var attempts = 0
        var retryAt: CFTimeInterval = 0
        var terminal = false
        var budgetBlocked = false
        init(_ source: Source) { self.source = source }
    }
    nonisolated static let maximumJobBytes = 32 * 1024 * 1024
    nonisolated static let maximumRecordingBytes = 16 * 1024 * 1024
    private let renderer: NativePDFRetainedInkRenderer
    private let rasterizer: Rasterizer
    let byteLimit: Int
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var desired: [ObjectIdentifier] = []
    private var keptResources: [Resource] = []
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var runningBytes = 0
    private(set) var rasterCount = 0
    private(set) var uploadCount = 0
    var onChange: (() -> Void)?
    var retainedCount: Int { entries.count }
    var resourceCount: Int { entries.values.filter { $0.resource != nil }.count }
    /// Explicit source ownership + unique current/accepted GPU payloads + two
    /// bitmap-sized worker/upload slots. Command-buffer/driver overhead is not
    /// an RSS bound. The caller pins actual accepted Resource versions during
    /// upgrades; keeping only a Source cannot identify its previous texture.
    var accountedBytes: Int {
        var seen: Set<ObjectIdentifier> = []
        var bytes = entries.values.reduce(0) { $0 + $1.source.byteCost } + runningBytes
        for resource in keptResources + entries.values.compactMap(\.resource) {
            if seen.insert(ObjectIdentifier(resource.texture)).inserted { bytes += resource.texture.byteCount }
        }
        return bytes
    }

    init(renderer: NativePDFRetainedInkRenderer, byteLimit: Int = 64 * 1024 * 1024,
         rasterize: Rasterizer? = nil) {
        self.renderer = renderer; self.byteLimit = max(0, byteLimit)
        rasterizer = rasterize ?? { work in
            await Task.detached(priority: .userInitiated) { autoreleasepool { Self.rasterize(work) } }.value
        }
    }

    /// Existing drawing precedence is significant: valid native ink, nativePath,
    /// then the kind-specific shape/box renderer. A valid empty PDF alone is not
    /// proof that an unsupported/malformed object was actually drawable.
    static func capture(object: [String: Any], visualToken supplied: NativePDFCommittedVisualToken? = nil,
                        image: UIImage? = nil, pageSize: CGSize, reusing previous: Source? = nil) -> Source? {
        guard [pageSize.width,pageSize.height].allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        // supplied is an explicit native-store token argument, never a claimed
        // dictionary marker. The caller binds it to this immutable row. Reuse
        // its proof before copying raw JSON; unchanged ink/viewport updates do
        // not re-freeze text/image payloads or record their PDF commands again.
        let resolved = ["image", "clip"].contains(object["kind"] as? String ?? "") ? image : nil
        if let supplied, let previous, previous.pageSize == pageSize,
           previous.resolvedImage === resolved,
           previous.visualToken.hasSameAppearance(as: supplied) { return previous }
        var clean = object
        clean.removeValue(forKey: "_nativeInk"); clean.removeValue(forKey: "_nativeVisualToken")
        guard let frozen = try? DesktopJSON.immutableCopy(clean) as? [String: Any],
              let kind = frozen["kind"] as? String, let data = frozen["data"] as? [String: Any],
              let style = frozen["style"] as? [String: Any] else { return nil }
        let token = NativePDFCommittedVisualToken(object: frozen)
        guard supplied == nil || supplied!.hasSameAppearance(as: token) else { return nil }
        if let previous, previous.pageSize == pageSize, previous.resolvedImage === resolved,
           previous.visualToken.hasSameAppearance(as: token) { return previous }
        for name in ["width", "opacity", "fontSizePt", "fontScale"] where style[name] != nil {
            guard number(style[name]) != nil else { return nil }
        }
        let mapper = InkCoordinateMapper.whiteboard(size: pageSize)
        let native = NativePDFObjectRenderer.prepareInk(frozen, aspect: pageSize.height/pageSize.width)
        let legacy = (frozen["nativePath"] as? String).flatMap {
            NativePDFObjectRenderer.path($0, width: pageSize.width, height: pageSize.height)
        }
        if native == nil && legacy == nil {
            guard ["line", "arrow", "rect", "ellipse", "textbox", "image", "clip"].contains(kind) else { return nil }
            if ["textbox", "image", "clip"].contains(kind) {
                guard let box = data["box"] as? [String: Any],
                      let x = number(box["x"]), let y = number(box["y"]),
                      let width = number(box["width"]), let height = number(box["height"]),
                      width > 0, height > 0, x.isFinite, y.isFinite else { return nil }
                if kind == "textbox", let text = data["text"], !(text is String) { return nil }
            }
        }
        guard let bounds = NativePDFObjectRenderer.hitBounds(frozen, mapper: mapper),
              !bounds.isNull, !bounds.isEmpty,
              [bounds.minX,bounds.minY,bounds.maxX,bounds.maxY,bounds.width,bounds.height].allSatisfy(\.isFinite) else { return nil }
        let pageBounds = CGRect(origin: .zero, size: pageSize)
        let pdf = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            context.beginPage()
            NativePDFObjectRenderer.draw(frozen, in: context.cgContext, mapper: mapper, image: resolved, overrideBlend: true)
        }
        guard pdf.count <= maximumRecordingBytes,
              let recording = NativePDFNavigationSnapshot.Paper(data: pdf, size: pageSize) else { return nil }
        guard let encoded = try? JSONSerialization.data(withJSONObject: frozen) else { return nil }
        let jsonCharge = encoded.count.multipliedReportingOverflow(by: 8)
        let imageCharge = (resolved?.cgImage?.bytesPerRow ?? 0).multipliedReportingOverflow(by: resolved?.cgImage?.height ?? 0)
        let firstCharge = pdf.count.addingReportingOverflow(jsonCharge.partialValue)
        let totalCharge = firstCharge.partialValue.addingReportingOverflow(imageCharge.partialValue)
        guard !jsonCharge.overflow, !imageCharge.overflow, !firstCharge.overflow, !totalCharge.overflow else { return nil }
        // Two physical points also cover placeholder borders; raster request
        // adds a further physical pixel at its own effective density.
        let padded = bounds.insetBy(dx: -2, dy: -2)
        guard [padded.minX,padded.minY,padded.maxX,padded.maxY,padded.width,padded.height].allSatisfy(\.isFinite) else { return nil }
        return Source(token: supplied ?? token, image: resolved, pageSize: pageSize,
            bounds: padded, multiply: kind == "highlighter", bytes: pdf.count, byteCost: totalCharge.partialValue,
            command: .init(bounds: padded, content: .pdf(recording)))
    }
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    /// Invalid scales/over-budget sources are unavailable, never empty success.
    /// All current/keeping entries are protected; unreferenced resources leave
    /// the cache immediately. A running immutable job keeps only its own slot.
    func update(requests: [Request], keeping: [Source] = [], keepingResources: [Resource] = []) {
        self.keptResources = keepingResources
        let requested = Dictionary(requests.map { (ObjectIdentifier($0.source), $0) }, uniquingKeysWith: { a,b in a.scale >= b.scale ? a : b })
        let protected = Set(keeping.map(ObjectIdentifier.init)).union(requested.keys)
        entries = entries.filter { protected.contains($0.key) }
        desired = []
        var seen: Set<ObjectIdentifier> = []
        for request in requests {
            let key = ObjectIdentifier(request.source)
            guard seen.insert(key).inserted, let selected = requested[key] else { continue }
            desired.append(key)
            if entries[key] == nil {
                guard request.source.byteCost <= byteLimit - accountedBytes else { continue }
                entries[key] = Entry(request.source)
            }
            guard let entry = entries[key] else { continue }
            let next = Self.work(source: selected.source, scale: selected.scale)
            if let old = entry.work, let next, old.matches(next) { continue }
            entry.work = next; entry.attempts = 0; entry.retryAt = 0
            entry.terminal = next == nil; entry.budgetBlocked = false
        }
        startIfPossible()
    }
    func resource(for source: Source) -> Resource? { entries[ObjectIdentifier(source)]?.resource }
    func status(for source: Source) -> Status {
        guard let entry = entries[ObjectIdentifier(source)] else { return .unavailable }
        if entry.resource != nil { return .ready }
        return entry.terminal || entry.budgetBlocked || entry.work == nil ? .unavailable : .pending
    }
    func reset() {
        generation &+= 1; desired = []; entries.removeAll(); keptResources = []; wake?.cancel(); wake = nil
        // The in-flight CG call is not cancelled. Its reserved slot is released
        // only on completion, and its old generation can never publish.
    }

    static func work(source: Source, scale proposed: CGFloat) -> Work? {
        let bounds = source.bounds
        guard proposed.isFinite, proposed > 0 else { return nil }
        var scale = min(proposed, 4092/bounds.width, 4092/bounds.height,
                        sqrt(CGFloat(maximumJobBytes/4)/(bounds.width*bounds.height)) * 0.999)
        guard scale.isFinite, scale > 0 else { return nil }
        for _ in 0..<3 {
            let x = floor(bounds.minX*scale)-1, y = floor(bounds.minY*scale)-1
            let width = ceil(bounds.maxX*scale)+1-x, height = ceil(bounds.maxY*scale)+1-y
            guard [x,y,width,height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
            if width <= 4096, height <= 4096, width*height*4 <= CGFloat(maximumJobBytes) {
                return Work(command: source.command,
                    bounds: CGRect(x: x/scale, y: y/scale, width: width/scale, height: height/scale),
                    scale: scale, width: Int(width), height: Int(height))
            }
            scale *= min(4093/width, 4093/height, sqrt(CGFloat(maximumJobBytes/4)/(width*height))) * 0.999
        }
        return nil
    }

    nonisolated static func rasterize(_ work: Work) -> Bitmap? {
        guard work.width > 0, work.height > 0, work.width <= 4096, work.height <= 4096,
              work.byteCount <= maximumJobBytes,
              let context = CGContext(data: nil, width: work.width, height: work.height, bitsPerComponent: 8,
                bytesPerRow: work.width*4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.clear(CGRect(x: 0,y: 0,width: work.width,height: work.height))
        context.translateBy(x: 0, y: CGFloat(work.height)); context.scaleBy(x: work.scale, y: -work.scale)
        context.translateBy(x: -work.bounds.minX, y: -work.bounds.minY)
        work.command.draw(in: context)
        context.flush()
        guard let bytes = context.data else { return nil }
        return Bitmap(bytes: Data(bytes: bytes, count: work.byteCount), width: work.width,
                      height: work.height, bytesPerRow: work.width*4)
    }

    private func startIfPossible() {
        guard worker == nil else { return }
        wake?.cancel(); wake = nil
        var earliest: CFTimeInterval?
        let now = CACurrentMediaTime()
        for key in desired {
            guard let entry = entries[key], let requestedWork = entry.work, !entry.terminal else { continue }
            if let resource = entry.resource, resource.effectiveScale >= requestedWork.scale { continue }
            if entry.retryAt > now { earliest = min(earliest ?? entry.retryAt, entry.retryAt); continue }
            // A context+Data or Data+new GPU texture can coexist during a job.
            // A newly restored object has no low-density resource to keep. A
            // capped ~32 MiB texture would need almost the entire 64 MiB cache
            // just for its two transient slots, starving it behind accepted
            // objects. Select a bounded lower-density job without evicting
            // those accepted resources or changing the requested density.
            guard let work = admittedWork(for: entry, requested: requestedWork) else {
                entry.budgetBlocked = true; continue
            }
            entry.budgetBlocked = false
            // The retained lower-density result satisfies this admission.
            // Repeated requests must not rasterize it again; a later update
            // can upgrade only when the protected-resource budget permits it.
            if let resource = entry.resource, resource.effectiveScale >= work.scale { continue }
            let reservation = work.byteCount * 2 + entry.source.byteCost + (entry.resource?.texture.byteCount ?? 0)
            entry.attempts += 1
            // Include a duplicate recording charge: reset/removal may release
            // the entry while this job still owns its CGPDF recording.
            runningBytes = reservation
            let expected = generation, rasterize = rasterizer
            worker = Task { [weak self, entry] in
                let bitmap = await rasterize(work)
                guard let self else { return }
                self.worker = nil; self.runningBytes = 0
                guard self.generation == expected, self.entries[key] === entry, self.desired.contains(key) else {
                    // Releasing an obsolete worker's reservation can make the
                    // latest request admissible. Its owner still owns that
                    // immutable candidate; ask it to retry admission once.
                    self.startIfPossible(); self.onChange?(); return
                }
                // Retries belong to the requested source/density, even when
                // the actual job was admitted at a lower effective scale.
                let sameRequest = entry.work?.matches(requestedWork) == true
                if let bitmap, bitmap.width == work.width, bitmap.height == work.height,
                   bitmap.bytesPerRow == work.width*4, bitmap.bytes.count == work.byteCount,
                   let texture = self.renderer.makeTexture(premultipliedBGRA8: bitmap.bytes,
                       width: bitmap.width, height: bitmap.height, bytesPerRow: bitmap.bytesPerRow) {
                    if entry.resource.map({ $0.effectiveScale < work.scale }) ?? true {
                        entry.resource = Resource(texture: texture, bounds: work.bounds, effectiveScale: work.scale)
                        self.rasterCount += 1; self.uploadCount += 1
                    }
                    if sameRequest { entry.terminal = false; entry.retryAt = 0; entry.attempts = 0 }
                } else if sameRequest {
                    if entry.attempts >= 3 { entry.terminal = true }
                    else { entry.retryAt = CACurrentMediaTime() + (entry.attempts == 1 ? 0.05 : 0.2) }
                }
                self.onChange?(); self.startIfPossible()
            }
            return
        }
        if let earliest {
            let expected = generation
            wake = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0, earliest-CACurrentMediaTime()) * 1_000_000_000)) } catch { return }
                guard let self, self.generation == expected else { return }
                self.wake = nil; self.startIfPossible()
            }
        }
    }

    private func admittedWork(for entry: Entry, requested: Work) -> Work? {
        let available = byteLimit - accountedBytes
        let ownership = entry.source.byteCost + (entry.resource?.texture.byteCount ?? 0)
        var candidate = requested
        while true {
            if candidate.byteCount * 2 + ownership <= available { return candidate }
            // Native requests use power-of-two density. Per-object dimension
            // and byte caps may already have lowered the effective scale, so
            // step to the next strictly smaller power rather than repeatedly
            // requesting the same capped bitmap. Below one pixel/page point,
            // preserve the existing cap; do not invent an unbounded quality
            // degradation for a genuinely exhausted cache.
            guard candidate.scale > 1 else { return nil }
            let lower = max(1, pow(2, ceil(log2(candidate.scale)) - 1))
            guard lower < candidate.scale,
                  let next = Self.work(source: entry.source, scale: lower),
                  next.scale < candidate.scale else { return nil }
            candidate = next
        }
    }
}
