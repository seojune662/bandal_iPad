import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// What three fingers did when they lifted: pinched together (close the pane's tab) or spread apart (open a new one).
enum NativeTabGestureDecision: Equatable { case close, open }

/// A tab just closed and where it sat: what the three-finger pinch's 되돌리기 puts back.
struct NativeClosedTab {
    let document: NativeDocumentReference
    let ref: NativeWorkspaceWindowRef
    let groupID: String
    let index: Int
    let duplicateSourceID: String?
    /// Page-note links this tab was part of (note tab → its PDF tab), restored where both ends are open.
    let pageNotes: [String: String]
    /// A browser tab's page: closing ends its web view, so it comes back at this address.
    var browserURL: String?
}

/// 일반 › 더 보기 › 탭: the three-finger gesture's switch and what a spread opens. On this iPad only.
enum NativeTabGesturePreferences {
    static let enabledKey = "native.tabGesture.enabled"
    static let openKindKey = "native.tabGesture.openKind"
    /// A spread shows the ＋ menu: the user picks each time.
    static let choose = "choose"
    static var enabled: Bool { NativeLocalPreferences.bool(enabledKey) }
    /// The ＋ menu's own rows, so the two lists never drift apart (녹음 only while its flag is on).
    static var kinds: [NativeNewTabCatalog.Item] { NativeNewTabCatalog.items(query: "") }
    /// What a spread opens: nil shows the ＋ menu. A saved kind that is no longer offered falls back to the menu.
    static func action(for value: String?) -> NativeNewTabAction? {
        guard let value, value != choose else { return nil }
        return kinds.first { $0.id == value }?.action
    }
    static var openAction: NativeNewTabAction? { action(for: UserDefaults.standard.string(forKey: openKindKey)) }
    /// iPadOS's own three-finger copy (pinch), paste (spread) and undo (swipe) are asked of the first responder
    /// itself, never of its view controller. While the gesture is on, the app's own editors (마크다운, a PDF text
    /// box) give them up to it; ⌘C/⌘V/⌘Z, the edit menu and the shortcut bar stay. Elsewhere (a web page's
    /// field, a search field) iPadOS keeps them and the tab gesture does not start (`yieldsToTextEditing`).
    static var editingInteraction: UIEditingInteractionConfiguration { enabled ? .none : .default }
    /// Text is being edited somewhere iPadOS's three-finger editing still works.
    @MainActor static var yieldsToTextEditing: Bool {
        guard let responder = NativeFirstResponder.current(), responder is UITextInput else { return false }
        return responder.editingInteractionConfiguration != .none
    }
}

/// The responder with the keyboard, found the way UIKit sends an action to "the first responder".
@MainActor enum NativeFirstResponder {
    fileprivate static weak var found: UIResponder?
    static func current() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.nativeReportFirstResponder), to: nil, from: nil, for: nil)
        return found
    }
}
extension UIResponder {
    @objc fileprivate func nativeReportFirstResponder() { MainActor.assumeIsolated { NativeFirstResponder.found = self } }
}

/// Reads three fingers from their positions alone. Fed touch by touch; it never looks at views or time of day,
/// so the rules can be tested on recorded positions.
///
/// - Three direct touches must land within `landingWindow` of the first one. A fourth finger, a finger that lifts
///   before the third lands, or a third that lands late ends the attempt until every finger is up.
/// - The spread is the fingers' mean distance from their centre. It is measured when the third finger lands, at its
///   narrowest during the gesture, and when the first of the three lifts, which is when the gesture is decided.
/// - While the Pencil is down, or for `pencilGrace` after it lifts, fingers start nothing: a palm resting on the
///   screen while writing must not read as three fingers.
struct NativeTabGestureTracker {
    struct Rules: Equatable {
        var landingWindow: TimeInterval = 0.15
        /// Closing: the spread at release is at most this share of the spread at the start.
        var closeRatio: CGFloat = 0.65
        /// Opening: the spread at release is at least this many times the narrowest, and no less than at the start.
        var openRatio: CGFloat = 1.5
        /// Below this change in spread (points) nothing happens, whatever the ratios say: fingers placed close
        /// together would otherwise read a tremor as a pinch.
        var minimumTravel: CGFloat = 20
        var maximumDuration: TimeInterval = 1.5
        var pencilGrace: TimeInterval = 0.5
    }
    enum Phase: Equatable { case idle, gathering, tracking, finished, ignored }
    enum Outcome: Equatable {
        /// The third finger landed in time: the gesture is under way around this point.
        case started(CGPoint)
        /// The first of the three lifted: what the gesture did (nil: nothing).
        case decided(NativeTabGestureDecision?)
        /// A gesture under way stopped without a decision (a fourth finger, a cancelled touch).
        case abandoned
    }

    var rules = Rules()
    private(set) var phase = Phase.idle
    private var fingers: [Int: CGPoint] = [:]
    private var trio: [Int] = []
    private var firstLanding: TimeInterval = 0
    private(set) var startTime: TimeInterval = 0
    private(set) var startSpread: CGFloat = 0
    private(set) var narrowest: CGFloat = 0
    private var pencilDown = false
    private var pencilLastSeen = -TimeInterval.infinity

    init(rules: Rules = Rules()) { self.rules = rules }

    static func spread(_ points: [CGPoint]) -> CGFloat {
        guard !points.isEmpty else { return 0 }
        let centre = centroid(points)
        return points.reduce(0) { $0 + hypot($1.x - centre.x, $1.y - centre.y) } / CGFloat(points.count)
    }
    static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
    /// The rule itself: what a gesture that started at `start`, was at its narrowest `narrowest` and lifted at `end`
    /// (spreads, in points) after `duration` seconds did.
    static func decide(start: CGFloat, narrowest: CGFloat, end: CGFloat, duration: TimeInterval, rules: Rules = Rules()) -> NativeTabGestureDecision? {
        guard duration <= rules.maximumDuration, start > 0 else { return nil }
        if end <= start * rules.closeRatio, start - end >= rules.minimumTravel { return .close }
        if end >= narrowest * rules.openRatio, end >= start, end - narrowest >= rules.minimumTravel { return .open }
        return nil
    }

    /// The spread now, while the gesture is under way.
    var currentSpread: CGFloat { Self.spread(trio.compactMap { fingers[$0] }) }
    var centre: CGPoint { Self.centroid(trio.compactMap { fingers[$0] }) }
    /// What lifting now would do; nil outside a gesture. Time is left out: the preview follows the fingers.
    var armed: NativeTabGestureDecision? {
        guard phase == .tracking else { return nil }
        return Self.decide(start: startSpread, narrowest: narrowest, end: currentSpread, duration: 0, rules: rules)
    }

    /// The Pencil touched, moved or lifted. `down` is whether it is still on the screen.
    mutating func pencil(down: Bool, time: TimeInterval) {
        pencilDown = down; pencilLastSeen = time
        // A palm that came first and the Pencil after it: the fingers were the hand writing.
        if phase == .gathering || phase == .tracking { phase = .ignored }
    }

    /// A finger landed. `pencilDown` is what the event says about the Pencil, which this tracker may not have seen
    /// lift if the touches went elsewhere.
    @discardableResult
    mutating func began(_ id: Int, at point: CGPoint, time: TimeInterval, pencilDown pencilNow: Bool? = nil) -> Outcome? {
        if let pencilNow { pencilDown = pencilNow }
        fingers[id] = point
        switch phase {
        case .idle:
            if pencilDown || time - pencilLastSeen < rules.pencilGrace { phase = .ignored; return nil }
            phase = .gathering; firstLanding = time; trio = [id]
            return nil
        case .gathering:
            guard time - firstLanding <= rules.landingWindow else { phase = .ignored; return nil }
            trio.append(id)
            guard trio.count == 3 else { return nil }
            phase = .tracking; startTime = time
            startSpread = currentSpread; narrowest = startSpread
            return .started(centre)
        case .tracking:
            phase = .ignored
            return .abandoned
        case .finished, .ignored:
            return nil
        }
    }

    mutating func moved(_ id: Int, to point: CGPoint) {
        guard fingers[id] != nil else { return }
        fingers[id] = point
        if phase == .tracking, trio.contains(id) { narrowest = min(narrowest, currentSpread) }
    }

    /// A finger lifted (or the system took it: `cancelled`).
    @discardableResult
    mutating func ended(_ id: Int, at point: CGPoint, time: TimeInterval, cancelled: Bool = false) -> Outcome? {
        guard fingers[id] != nil else { return nil }
        fingers[id] = point
        var outcome: Outcome?
        switch phase {
        case .gathering: phase = .ignored
        case .tracking where trio.contains(id):
            if cancelled { outcome = .abandoned; phase = .ignored }
            else {
                narrowest = min(narrowest, currentSpread)
                outcome = .decided(Self.decide(start: startSpread, narrowest: narrowest, end: currentSpread, duration: time - startTime, rules: rules))
                phase = .finished
            }
        default: break
        }
        fingers[id] = nil
        if fingers.isEmpty { reset() }
        return outcome
    }

    /// Stops the attempt until every finger is up (the place under the fingers does not take the gesture).
    mutating func ignore() { if fingers.isEmpty { reset() } else { phase = .ignored } }

    /// Every finger is up: the next touch starts afresh. What is known about the Pencil stays.
    mutating func reset() { phase = .idle; fingers = [:]; trio = []; startSpread = 0; narrowest = 0 }
}

/// Watches every touch in the window for the three-finger gesture. It takes part in nothing until three fingers
/// land together; from then until they lift it owns the touches: everything else the fingers had started (a PDF's
/// zoom, a page's scroll, a stroke drawn with a finger, a text selection) is cancelled, and nothing new starts.
final class NativeTabGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private var tracker = NativeTabGestureTracker()
    /// Whether a gesture may start now (the switch, VoiceOver, a covering screen).
    var allowed: () -> Bool = { false }
    /// The pane under a point in window coordinates; nil when it is not over the dock.
    var target: (CGPoint) -> String? = { _ in nil }
    /// The pane the fingers are over and what lifting would do; (nil, nil) when the gesture ends.
    var preview: (String?, NativeTabGestureDecision?) -> Void = { _, _ in }
    var decide: (NativeTabGestureDecision, String) -> Void = { _, _ in }
    private var groupID: String?
    private var armed: NativeTabGestureDecision?
    private var suspended: [UIGestureRecognizer] = []
    private var down: Set<ObjectIdentifier> = []
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        delegate = self
    }

    private static func key(_ touch: UITouch) -> Int { ObjectIdentifier(touch).hashValue }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            down.insert(ObjectIdentifier(touch))
            if touch.type == .pencil { tracker.pencil(down: true, time: touch.timestamp); finishIfAbandoned(); continue }
            let pencil = event.allTouches?.contains { $0.type == .pencil && $0.phase != .ended && $0.phase != .cancelled } ?? false
            switch tracker.began(Self.key(touch), at: touch.location(in: nil), time: touch.timestamp, pencilDown: pencil) {
            case .started(let centre): start(at: centre, event: event)
            case .abandoned: abandon()
            default: break
            }
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            if touch.type == .pencil { tracker.pencil(down: true, time: touch.timestamp); finishIfAbandoned(); continue }
            tracker.moved(Self.key(touch), to: touch.location(in: nil))
        }
        guard groupID != nil else { return }
        let now = tracker.armed
        if now != armed {
            armed = now
            if now != nil { haptic.impactOccurred() }
            preview(groupID, now)
        }
        if state == .began || state == .changed { state = .changed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, cancelled: true) }

    private func lift(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches {
            down.remove(ObjectIdentifier(touch))
            if touch.type == .pencil { tracker.pencil(down: false, time: touch.timestamp); finishIfAbandoned(); continue }
            switch tracker.ended(Self.key(touch), at: touch.location(in: nil), time: touch.timestamp, cancelled: cancelled) {
            case .decided(let decision):
                let pane = groupID
                endPreview()
                if let decision, let pane { decide(decision, pane) }
            case .abandoned: abandon()
            default: break
            }
        }
        // The gesture holds the touches until the last finger lifts, so a zoom cannot pick up the two left behind.
        guard down.isEmpty else { return }
        state = state == .began || state == .changed ? (cancelled ? .cancelled : .ended) : .failed
    }

    private func start(at centre: CGPoint, event: UIEvent) {
        guard allowed(), let pane = target(centre) else { tracker.ignore(); return }
        groupID = pane; armed = nil
        haptic.prepare()
        cancelsTouchesInView = true
        // Everything the fingers had started stops here; it comes back once they are all up (`reset`).
        let mine = view
        for touch in event.allTouches ?? [] {
            for recognizer in touch.gestureRecognizers ?? [] where recognizer !== self && recognizer.view !== mine && recognizer.isEnabled {
                recognizer.isEnabled = false; suspended.append(recognizer)
            }
        }
        state = .began
        preview(pane, nil)
    }
    private func abandon() { endPreview(); if state == .possible { tracker.ignore() } }
    private func finishIfAbandoned() { if groupID != nil, tracker.phase == .ignored { endPreview() } }
    private func endPreview() {
        guard groupID != nil else { return }
        groupID = nil; armed = nil
        preview(nil, nil)
    }

    override func reset() {
        super.reset()
        endPreview()
        cancelsTouchesInView = false
        suspended.forEach { $0.isEnabled = true }; suspended = []
        down = []
        tracker.reset()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Puts the recognizer on the dock's window and maps its points to the dock's panes.
struct NativeTabGestureProbe: UIViewRepresentable {
    let panes: [(String, CGRect)]
    let allowed: () -> Bool
    let preview: (String?, NativeTabGestureDecision?) -> Void
    let decide: (NativeTabGestureDecision, String) -> Void
    func makeUIView(context: Context) -> Probe { let view = Probe(); view.isUserInteractionEnabled = false; view.isAccessibilityElement = false; return view }
    func updateUIView(_ view: Probe, context: Context) {
        let panes = panes
        view.recognizer.allowed = { [weak view] in
            guard let view, let window = view.window, !view.isHidden, allowed() else { return false }
            // A sheet, popover, menu or the paywall over the window: the fingers are on it, not on a pane.
            return window.rootViewController?.presentedViewController == nil && !NativeTabGesturePreferences.yieldsToTextEditing
        }
        view.recognizer.target = { [weak view] point in
            guard let view else { return nil }
            let local = view.convert(point, from: nil)
            return panes.first { $0.1.contains(local) }?.0
        }
        view.recognizer.preview = preview
        view.recognizer.decide = decide
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }
    final class Probe: UIView {
        let recognizer = NativeTabGestureRecognizer()
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            window?.addGestureRecognizer(recognizer)
        }
        func detach() { recognizer.view?.removeGestureRecognizer(recognizer) }
    }
}

/// Over the pane the fingers are on: the card draws in a little for a pinch and says what lifting will do.
struct NativeTabGesturePreview: View {
    let decision: NativeTabGestureDecision?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NativeDockCard.radius, style: .continuous)
                .fill(Color.black.opacity(decision == .close ? 0.10 : 0.04))
                .overlay { RoundedRectangle(cornerRadius: NativeDockCard.radius, style: .continuous).strokeBorder(NativeGlass.accent, lineWidth: decision == nil ? 1 : 2) }
                .scaleEffect(decision == .close && !reduceMotion ? 0.96 : 1)
            if let decision {
                HStack(spacing: 8) {
                    Image(systemName: decision == .close ? "xmark" : "plus")
                    BandalText(decision == .close ? "놓으면 탭 닫기" : "놓으면 새 탭")
                }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeDesktopTheme.text)
                    .padding(.horizontal, 16).frame(minHeight: 40)
                    .bandalGlass(in: Capsule())
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: decision)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if DEBUG
/// `--native-tab-gesture-fixture`: neither XCUITest nor the simulator can put three fingers down, so each pane
/// gets two small buttons that hand the dock what the recognizer would have decided.
enum NativeTabGestureFixture {
    static let argument = "--native-tab-gesture-fixture"
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains(argument) }
    struct Buttons: View {
        let index: Int
        let perform: (NativeTabGestureDecision) -> Void
        var body: some View {
            HStack(spacing: 6) {
                Button { perform(.close) } label: { Text(verbatim: "3⊖").frame(minWidth: 44, minHeight: 32) }
                    .accessibilityIdentifier("native-tab-gesture-fixture-close-\(index)")
                Button { perform(.open) } label: { Text(verbatim: "3⊕").frame(minWidth: 44, minHeight: 32) }
                    .accessibilityIdentifier("native-tab-gesture-fixture-open-\(index)")
            }
            .font(.system(size: 12, weight: .semibold)).buttonStyle(.bordered)
        }
    }
}
#endif
