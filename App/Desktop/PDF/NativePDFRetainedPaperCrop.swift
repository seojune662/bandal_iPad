import Foundation
import CoreGraphics

/// A bounded high-density paper/highlight crop. Completed ink must never enter
/// this worker: it remains retained GPU geometry. The owner keeps its full-page
/// paper as the immediate fallback whenever presentation returns nil.
@MainActor
final class NativePDFRetainedPaperCrop {
    struct Request: @unchecked Sendable {
        let snapshot: NativePDFNavigationSnapshot
        /// Outward pixel-grid origin; width/height may be one ULP inward only
        /// to prevent ceil() allocating an unintended extra physical pixel.
        let bounds: CGRect
        let scale: CGFloat
        let pixelOrigin: CGPoint
        let pixelWidth: Int
        let pixelHeight: Int
        var presentationBounds: CGRect {
            CGRect(origin: bounds.origin, size: CGSize(width: CGFloat(pixelWidth)/scale, height: CGFloat(pixelHeight)/scale))
        }
        func matches(_ other: Request) -> Bool {
            snapshot === other.snapshot && bounds == other.bounds && scale == other.scale
                && pixelOrigin == other.pixelOrigin && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
        }
    }
    typealias Rasterizer = @Sendable (Request) async -> NativePDFNavigationSnapshot.Raster?
    private struct Accepted { let request: Request; let image: CGImage }
    private let rasterize: Rasterizer
    private var desired: Request?
    private var accepted: Accepted?
    private var generation: UInt64 = 0
    private var attempts = 0
    private var eligible = false
    private var worker: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private(set) var rasterCount = 0
    var onReady: (() -> Void)?
    /// Nonfatal: the owner continues presenting its full-page paper fallback.
    var onFailure: ((Error) -> Void)?

    init(rasterize: Rasterizer? = nil) {
        self.rasterize = rasterize ?? { request in
            await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    request.snapshot.raster(bounds: request.bounds, scale: request.scale, canonicalToCanvas: .identity)
                }
            }.value
        }
    }

    func update(snapshot: NativePDFNavigationSnapshot, bounds: CGRect, scale: CGFloat) {
        guard let next = Self.request(snapshot: snapshot, bounds: bounds, scale: scale) else {
            clearDesired(); return
        }
        if covers(next, query: bounds) { clearDesired(); return }
        if let desired, desired.matches(next) { return }
        generation &+= 1; desired = next; attempts = 0; eligible = false
        schedule(after: 100_000_000, generation: generation)
    }
    func presentation(for snapshot: NativePDFNavigationSnapshot, bounds: CGRect, scale: CGFloat) -> (image: CGImage, bounds: CGRect)? {
        guard let query = Self.request(snapshot: snapshot, bounds: bounds, scale: scale), covers(query, query: bounds),
              let accepted else { return nil }
        return (accepted.image, accepted.request.presentationBounds)
    }
    func reset() {
        clearDesired(); accepted = nil
        // The immutable running job cannot be canceled halfway through CG.
        // Keep its slot occupied until completion, then discard its result.
    }
    private func clearDesired() {
        guard desired != nil || wake != nil else { return }
        generation &+= 1; desired = nil; attempts = 0; eligible = false
        wake?.cancel(); wake = nil
    }
    private func covers(_ query: Request, query bounds: CGRect) -> Bool {
        guard let accepted, accepted.request.snapshot === query.snapshot,
              accepted.request.scale >= query.scale else { return false }
        let clipped = bounds.intersection(CGRect(origin: .zero, size: query.snapshot.size))
        let r = accepted.request, s = r.scale
        // Compare independently quantized physical pixel extents. This avoids
        // floating-point division/addition making a covered edge look outside.
        return floor(clipped.minX*s) >= r.pixelOrigin.x && floor(clipped.minY*s) >= r.pixelOrigin.y
            && ceil(clipped.maxX*s) <= r.pixelOrigin.x + CGFloat(r.pixelWidth)
            && ceil(clipped.maxY*s) <= r.pixelOrigin.y + CGFloat(r.pixelHeight)
    }
    private func schedule(after delay: UInt64, generation expected: UInt64) {
        wake?.cancel()
        wake = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.generation == expected else { return }
            self.wake = nil; self.eligible = true; self.startIfPossible()
        }
    }
    private func startIfPossible() {
        guard worker == nil, eligible, let request = desired, attempts < 3 else { return }
        eligible = false; attempts += 1
        let expected = generation, rasterize = self.rasterize
        worker = Task { [weak self] in
            let result = await rasterize(request)
            guard let self else { return }
            self.worker = nil
            guard self.generation == expected, self.desired?.matches(request) == true else {
                self.startIfPossible(); return
            }
            if let result, result.image.width == request.pixelWidth,
               result.image.height == request.pixelHeight, result.scale == request.scale {
                self.accepted = Accepted(request: request, image: result.image)
                self.rasterCount += 1; self.onReady?()
            } else if self.attempts < 3 {
                self.schedule(after: self.attempts == 1 ? 50_000_000 : 200_000_000, generation: expected)
            } else {
                self.onFailure?(NativePDFError.invalid("확대된 PDF 배경을 준비하지 못해 기존 배경을 유지합니다."))
            }
        }
    }

    /// Pure preparation is visible to tests without allocating a near-8M image.
    /// Effective density is capped identically for update and presentation.
    static func request(snapshot: NativePDFNavigationSnapshot, bounds: CGRect, scale proposed: CGFloat) -> Request? {
        guard snapshot.objects.isEmpty,
              [bounds.minX,bounds.minY,bounds.maxX,bounds.maxY,bounds.width,bounds.height,proposed,
               snapshot.size.width,snapshot.size.height].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, proposed > 0,
              snapshot.size.width > 0, snapshot.size.height > 0 else { return nil }
        let clipped = bounds.intersection(CGRect(origin: .zero, size: snapshot.size))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        var scale = min(proposed, 4096/clipped.width, 4096/clipped.height,
                        sqrt(8_000_000/(clipped.width*clipped.height)))
        guard scale.isFinite, scale > 0 else { return nil }
        for _ in 0..<2 {
            let x = floor(clipped.minX*scale), y = floor(clipped.minY*scale)
            let width = ceil(clipped.maxX*scale)-x, height = ceil(clipped.maxY*scale)-y
            guard [x,y,width,height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
            if width <= 4096, height <= 4096, width*height <= 8_020_000 {
                let pixelWidth = Int(width), pixelHeight = Int(height)
                var w = width/scale, h = height/scale
                // Preserve integer backing dimensions despite divide/multiply
                // rounding. Presentation uses exact imagePixels / scale below.
                while ceil(w*scale) > width { w = w.nextDown }
                while ceil(h*scale) > height { h = h.nextDown }
                let aligned = CGRect(x: x/scale, y: y/scale, width: w, height: h)
                return Request(snapshot: snapshot, bounds: aligned, scale: scale,
                    pixelOrigin: CGPoint(x: x,y: y), pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            }
            // A fractional origin can add one pixel beyond the continuous cap.
            // Reserve that pixel without reducing small/already-aligned crops.
            scale = min(scale, 4095/clipped.width, 4095/clipped.height,
                        sqrt(8_000_000/(clipped.width*clipped.height)))
        }
        return nil
    }
}
