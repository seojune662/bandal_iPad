import UIKit

/// The laser pointer's one clock for a whole PDF. Every page keeps the trails drawn on it until no laser contact
/// has touched any page for `holdSeconds`; then all of them fade out together. Writing again before that restarts
/// the wait, so a sentence pointed at across two pages stays up as one gesture. Nothing here is ever saved.
@MainActor
final class NativePDFLaserSession {
    static let holdSeconds: TimeInterval = 3
    static let fadeSeconds: TimeInterval = 0.4
    /// Runs `body` after `delay` and returns its cancellation. Tests pass a manual clock.
    typealias Scheduler = @MainActor (_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> () -> Void
    private let schedule: Scheduler
    private let trails = NSHashTable<NativePDFLaserTrail>.weakObjects()
    private var contacts = 0
    private var cancelFade: (() -> Void)?
    var onChange: (() -> Void)?

    init(schedule: @escaping Scheduler = NativePDFLaserSession.mainRunLoop) { self.schedule = schedule }

    static func mainRunLoop(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { body() } }
        // .common keeps the countdown going while a finger scrolls the PDF.
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    /// Trails still on screen, across every page.
    var strokeCount: Int { trails.allObjects.reduce(0) { $0 + $1.strokes.count } }
    var isWaitingToFade: Bool { cancelFade != nil }

    func attach(_ trail: NativePDFLaserTrail) { trails.add(trail) }

    func contactBegan() {
        contacts += 1
        cancelFade?(); cancelFade = nil
    }
    func contactEnded() {
        contacts = max(0, contacts - 1)
        guard contacts == 0 else { return }
        cancelFade?()
        cancelFade = schedule(Self.holdSeconds) { [weak self] in self?.fadeAll() }
        onChange?()
    }
    /// Another tool was chosen: the pointer is gone at once.
    func clear() {
        cancelFade?(); cancelFade = nil; contacts = 0
        let had = strokeCount > 0
        for trail in trails.allObjects { trail.clear(fading: false) }
        if had { onChange?() }
    }
    private func fadeAll() {
        cancelFade = nil
        guard contacts == 0 else { return }
        for trail in trails.allObjects { trail.clear(fading: true) }
        onChange?()
    }
}

/// One page's laser marks, in page coordinates, drawn as a red core over a soft glow. Two stroked layers instead
/// of a layer shadow: a shadow re-renders offscreen every frame, and these paths keep growing until they fade.
@MainActor
final class NativePDFLaserTrail: NSObject {
    private(set) var strokes: [[NativePDFPoint]] = []
    let layer = CALayer()
    private let glow = CAShapeLayer(), core = CAShapeLayer()
    private var fading = false

    override init() {
        super.init()
        for (shape, width, alpha) in [(glow, 11.0, 0.28), (core, 4.0, 1.0)] {
            shape.fillColor = nil; shape.strokeColor = UIColor.systemRed.withAlphaComponent(alpha).cgColor
            shape.lineWidth = width; shape.lineCap = .round; shape.lineJoin = .round
            layer.addSublayer(shape)
        }
        layer.zPosition = 11
    }
    func begin(at point: NativePDFPoint) {
        if fading { stopFade() }
        strokes.append([point])
    }
    func update(_ points: [NativePDFPoint], mapper: InkCoordinateMapper?) {
        guard !strokes.isEmpty, !points.isEmpty else { return }
        strokes[strokes.count - 1] = points
        redraw(mapper: mapper)
    }
    func redraw(mapper: InkCoordinateMapper?) {
        guard !fading else { return }
        let path = CGMutablePath()
        if let mapper {
            for stroke in strokes {
                let points = stroke.map { mapper.canvasPoint(InkPoint(x: $0.x, y: $0.y, p: 0.5)) }
                guard let first = points.first else { continue }
                path.move(to: first)
                // A dot still shows as a dot.
                if points.count == 1 { path.addLine(to: first) } else { path.addLines(between: points) }
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.path = path; core.path = path
        CATransaction.commit()
    }
    func clear(fading animated: Bool) {
        guard !strokes.isEmpty else { return }
        strokes.removeAll()
        guard animated else { stopFade(); return }
        fading = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = NativePDFLaserSession.fadeSeconds
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { if self?.fading == true { self?.stopFade() } }
        }
        layer.opacity = 0; layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }
    private func stopFade() {
        fading = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "fade"); layer.opacity = 1
        glow.path = nil; core.path = nil
        CATransaction.commit()
    }
}
