import UIKit
import PDFKit

/// Paper is independent of the ink draw list. A full-page immutable texture
/// keeps its page coordinates while navigating; deleting ink never rasters it.
@MainActor
final class NativePDFRetainedPaper {
    typealias Rasterizer = @Sendable (NativePDFNavigationSnapshot, CGFloat) async -> NativePDFNavigationSnapshot.Raster?
    private let builder = NativePDFNavigationSnapshotBuilder()
    private let rasterize: Rasterizer
    private var requested: NativePDFNavigationSnapshot?
    private var accepted: NativePDFNavigationSnapshot?
    var acceptedSnapshot: NativePDFNavigationSnapshot? { ready ? accepted : nil }
    private(set) var acceptedScale: CGFloat?
    // Canceling an awaiting Task does not stop its detached CG raster. Keep
    // exactly one running operation, and only the newest requested snapshot.
    private var task: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var attempts = 0
    private(set) var image: CGImage?
    private(set) var rasterCount = 0
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    init(rasterize: Rasterizer? = nil) {
        self.rasterize = rasterize ?? { snapshot, scale in
            await Task.detached(priority: .userInitiated) {
                snapshot.raster(bounds: CGRect(origin: .zero, size: snapshot.size), scale: scale, canonicalToCanvas: .identity)
            }.value
        }
    }

    func update(page: PDFPage, highlights: [[String: Any]]) {
        guard let snapshot = builder.make(page: page, objects: [], tokens: [], highlights: highlights, image: { _ in nil }),
              snapshot !== requested else { return }
        requested = snapshot; attempts = 0
        retryTask?.cancel(); retryTask = nil
        startIfPossible()
    }
    private func startIfPossible() {
        guard task == nil, retryTask == nil, let snapshot = requested,
              snapshot !== accepted, attempts < 3 else { return }
        attempts += 1
        let size = snapshot.size
        let scale = min(2, 4096 / max(size.width, size.height), sqrt(8_000_000 / (size.width * size.height)))
        let rasterize = self.rasterize
        task = Task { [weak self] in
            let result = await rasterize(snapshot, scale)
            guard let self else { return }
            self.task = nil
            guard self.requested === snapshot else {
                self.startIfPossible()
                return
            }
            if let result {
                self.image = result.image; self.accepted = snapshot; self.acceptedScale = result.scale; self.rasterCount += 1
                self.onReady?()
            } else if self.attempts < 3 {
                // Relative to the failed attempt: t0, at least t0+50 ms,
                // then at least 200 ms after the second failure.
                let delay: UInt64 = self.attempts == 1 ? 50_000_000 : 200_000_000
                self.retryTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: delay) } catch { return }
                    guard let self, self.requested === snapshot else { return }
                    self.retryTask = nil
                    self.startIfPossible()
                }
            } else {
                // Preserve the previous opaque image, but never label it as
                // the new snapshot or silently retry forever on later frames.
                self.onFailure?(NativePDFError.invalid("PDF 배경을 준비하지 못했습니다. 필기를 보존한 채 PDF를 다시 열어 주세요."))
            }
        }
    }
    var ready: Bool { accepted === requested && image != nil }
    func reset() {
        retryTask?.cancel(); retryTask = nil
        requested = nil; accepted = nil; acceptedScale = nil; attempts = 0; image = nil; builder.invalidate()
        // An in-flight raster owns an immutable snapshot. Its completion is
        // discarded by identity, then it may start a newer post-reset request.
    }
}
