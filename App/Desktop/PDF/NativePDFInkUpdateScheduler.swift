import UIKit

/// Render after UIKit's freshest eligible Pencil delivery, including its
/// mid-frame dispatch. A display-link-only renderer misses that second batch
/// until the next refresh. Keep the link passive whenever no work is pending.
@MainActor
final class NativePDFInkUpdateScheduler {
    private let link: UIUpdateLink
    var render: (() -> Void)?
    var isRequestingFrames: Bool { link.isEnabled && link.requiresContinuousUpdates }

    init(view: UIView) {
        link = UIUpdateLink(view: view)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.addAction(to: .afterEventDispatch) { [weak self] _, info in
            guard let self, self.link.requiresContinuousUpdates else { return }
            // UIKit guarantees the later callback if this flag is true.
            // Submit just once with the newer samples, not twice per refresh.
            guard !info.isLowLatencyEventDispatchConfirmed else { return }
            self.render?()
        }
        link.addAction(to: .afterLowLatencyEventDispatch) { [weak self] _, _ in
            guard let self, self.link.requiresContinuousUpdates else { return }
            self.render?()
        }
        link.isEnabled = true
    }

    func setPencilActive(_ active: Bool) { link.wantsLowLatencyEventDispatch = active }
    func setNeedsFrame(_ needed: Bool) { link.requiresContinuousUpdates = needed }
    func stop() { link.isEnabled = false; link.requiresContinuousUpdates = false }
}
