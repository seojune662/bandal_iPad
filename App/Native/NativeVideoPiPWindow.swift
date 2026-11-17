import Combine
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Mounted over the whole workspace, above panes, sidebars and the PDF palette, below sheets and settings.
/// It takes no touch outside the PiP window, and never a Pencil's: writing goes on underneath.
struct NativeVideoPiPLayer: UIViewRepresentable {
    let store: NativeWorkspaceStore
    let browser: DesktopBrowserHost
    func makeUIView(context: Context) -> NativeVideoPiPCanvas {
        let pip = NativeVideoPiP.shared
        pip.store = store; pip.browser = browser
        return NativeVideoPiPCanvas()
    }
    func updateUIView(_ view: NativeVideoPiPCanvas, context: Context) {}
}

@MainActor
final class NativeVideoPiPCanvas: UIView {
    private(set) var windowView: NativeVideoPiPWindowView?
    /// The keyboard's frame in screen coordinates while it is up.
    private var keyboard: CGRect?
    private var pencilWatcher: NativeVideoPiPPencilWatcher?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false
        accessibilityIdentifier = "native-video-pip-layer"
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { NativeVideoPiP.shared.canvas = self }
        watchPencil(windowView != nil)
    }
    /// Only while a window is up does the app's window carry the Pencil watcher.
    private func watchPencil(_ on: Bool) {
        if let pencilWatcher { pencilWatcher.view?.removeGestureRecognizer(pencilWatcher); self.pencilWatcher = nil }
        guard on, let window else { return }
        let watcher = NativeVideoPiPPencilWatcher { [weak self] point, down in self?.windowView?.pencil(at: point, down: down) }
        window.addGestureRecognizer(watcher); pencilWatcher = watcher
    }
    /// Where the window may be: the workspace less the keyboard.
    var area: CGRect {
        NativeVideoPiPGeometry.area(bounds, keyboard: keyboard.flatMap { frame in window.map { convert($0.convert(frame, from: nil), from: $0) } })
    }
    func present(_ session: NativeVideoPiP.Session) {
        windowView?.removeFromSuperview()
        let view = NativeVideoPiPWindowView(session: session, canvas: self)
        windowView = view
        addSubview(view)
        view.frame = NativeVideoPiPGeometry.frame(for: NativeVideoPiPWindowView.savedPlacement, aspect: session.source.aspectRatio, in: area)
        view.layoutIfNeeded()
        view.appear()
        watchPencil(true)
    }
    func dismiss(_ session: NativeVideoPiP.Session) {
        guard let view = windowView, view.session === session else { return }
        windowView = nil
        view.disappear()
        watchPencil(false)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        windowView?.fit(in: area)
    }
    @objc private func keyboardChanged(_ note: Notification) {
        let frame = note.name == UIResponder.keyboardWillHideNotification ? nil : (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)
        keyboard = frame.flatMap { $0.height > 0 ? $0 : nil }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration) { self.windowView?.fit(in: self.area) }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let windowView, windowView.acceptsTouches else { return nil }
        // A Pencil goes through the window to the page or note beneath it.
        if event?.allTouches?.contains(where: { $0.type == .pencil }) == true { return nil }
        return windowView.hitTest(convert(point, to: windowView), with: event)
    }
}

/// Watches the Pencil anywhere in the app without taking it: over the window, the window fades and lets it through.
final class NativeVideoPiPPencilWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let report: (CGPoint, Bool) -> Void
    init(_ report: @escaping (CGPoint, Bool) -> Void) {
        self.report = report
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        delegate = self
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { touches.first.map { report($0.location(in: nil), true) } }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { touches.first.map { report($0.location(in: nil), true) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { touches.first.map { report($0.location(in: nil), false) }; state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { touches.first.map { report($0.location(in: nil), false) }; state = .failed }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// The floating window: the video, its controls, and the hands that move and size it.
@MainActor
final class NativeVideoPiPWindowView: UIView, UIGestureRecognizerDelegate {
    let session: NativeVideoPiP.Session
    private weak var canvas: NativeVideoPiPCanvas?
    private let clip = UIView()
    private let model: NativeVideoPiPControlsModel
    private let controls: UIHostingController<NativeVideoPiPControls>
    private var aspect: CGFloat
    private var gestureStart = CGRect.zero
    private var pinchStart = CGRect.zero
    /// Two fingers size the window; a finger left on it after the pinch drags it on from there.
    private var pinching = false
    private weak var pan: UIPanGestureRecognizer?
    private var resizing: NativeVideoPiPGeometry.Corner?
    private var pencilFade: Task<Void, Never>?
    private(set) var acceptsTouches = true

    static var savedPlacement: NativeVideoPiPGeometry.Placement? {
        UserDefaults.standard.data(forKey: NativeVideoPiPPreferences.placementKey).flatMap { try? JSONDecoder().decode(NativeVideoPiPGeometry.Placement.self, from: $0) }
    }

    init(session: NativeVideoPiP.Session, canvas: NativeVideoPiPCanvas) {
        self.session = session; self.canvas = canvas
        aspect = session.source.aspectRatio
        model = NativeVideoPiPControlsModel(session: session)
        controls = UIHostingController(rootView: NativeVideoPiPControls(model: model))
        super.init(frame: .zero)
        accessibilityIdentifier = "native-video-pip-window"
        accessibilityLabel = NativeAppLocale.string("PiP 영상", NativeVideoPiPControlsModel.locale)
        accessibilityContainerType = .semanticGroup
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.28; layer.shadowRadius = 18; layer.shadowOffset = CGSize(width: 0, height: 8)
        clip.layer.cornerRadius = 14; clip.layer.cornerCurve = .continuous; clip.clipsToBounds = true
        clip.backgroundColor = .black
        clip.layer.borderWidth = 0.5; clip.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        addSubview(clip)
        clip.addSubview(session.source.view)
        controls.view.backgroundColor = .clear
        controls.view.accessibilityIdentifier = "native-video-pip-controls"
        clip.addSubview(controls.view)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        for recognizer in [pan, pinch] as [UIGestureRecognizer] {
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        pan.maximumNumberOfTouches = 1
        self.pan = pan
        session.source.onChange = { [weak self] in self?.sourceChanged() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        clip.frame = bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 14).cgPath
        session.source.layout(in: clip.bounds)
        controls.view.frame = clip.bounds
        model.compact = bounds.width < 280
    }
    func appear() {
        model.show()
        guard !UIAccessibility.isReduceMotionEnabled else { alpha = 0; UIView.animate(withDuration: 0.18) { self.alpha = 1 }; return }
        alpha = 0; transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) { self.alpha = 1; self.transform = .identity }
    }
    func disappear() {
        acceptsTouches = false
        UIView.animate(withDuration: 0.18, animations: {
            self.alpha = 0
            if !UIAccessibility.isReduceMotionEnabled { self.transform = CGAffineTransform(scaleX: 0.9, y: 0.9) }
        }, completion: { _ in self.removeFromSuperview() })
    }
    /// The area changed (rotation, split view, the keyboard): keep the window inside it.
    func fit(in area: CGRect) {
        guard acceptsTouches, area.width > 0, area.height > 0 else { return }
        let next = NativeVideoPiPGeometry.reshaped(frame, aspect: aspect, in: area)
        if next != frame { frame = next }
    }
    private func sourceChanged() {
        model.refresh()
        let next = session.source.aspectRatio
        guard abs(next - aspect) > 0.01, let canvas else { return }
        aspect = next
        UIView.animate(withDuration: 0.2) { self.frame = NativeVideoPiPGeometry.reshaped(self.frame, aspect: next, in: canvas.area); self.layoutIfNeeded() }
    }
    private func remember() {
        guard let canvas else { return }
        let placement = NativeVideoPiPGeometry.placement(of: frame, in: canvas.area)
        if let data = try? JSONEncoder().encode(placement) { UserDefaults.standard.set(data, forKey: NativeVideoPiPPreferences.placementKey) }
    }
    private func settle(_ target: CGRect) {
        let animations = { self.frame = target; self.layoutIfNeeded() }
        if UIAccessibility.isReduceMotionEnabled { animations() }
        else { UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0, options: [.allowUserInteraction], animations: animations) }
        remember()
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let canvas else { return }
        let area = canvas.area
        switch recognizer.state {
        case .began:
            gestureStart = frame
            resizing = NativeVideoPiPGeometry.corner(at: recognizer.location(in: self), in: bounds.size)
            model.hold()
        case .changed:
            guard !pinching else { return }
            let translation = recognizer.translation(in: canvas)
            if let resizing {
                frame = NativeVideoPiPGeometry.resized(gestureStart, corner: resizing, by: translation, aspect: aspect, in: area)
            } else {
                frame = NativeVideoPiPGeometry.clamp(gestureStart.offsetBy(dx: translation.x, dy: translation.y), in: area)
            }
            layoutIfNeeded()
        case .ended, .cancelled, .failed:
            settle(resizing == nil ? NativeVideoPiPGeometry.projected(frame, velocity: recognizer.velocity(in: canvas), in: area)
                                   : NativeVideoPiPGeometry.snap(frame, in: area))
            resizing = nil
            model.release()
        default: break
        }
    }
    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard let canvas else { return }
        switch recognizer.state {
        case .began: pinching = true; pinchStart = frame; model.hold()
        case .changed:
            frame = NativeVideoPiPGeometry.scaled(pinchStart, by: recognizer.scale, aspect: aspect, in: canvas.area); layoutIfNeeded()
        case .ended, .cancelled, .failed:
            pinching = false
            // A drag still going on carries on from the new size, not from where it started.
            gestureStart = frame; resizing = nil; pan?.setTranslation(.zero, in: canvas)
            settle(NativeVideoPiPGeometry.snap(frame, in: canvas.area)); model.release()
        default: break
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view === self
    }
    /// The Pencil over the window: it fades and lets strokes through until the Pencil has been away a moment.
    func pencil(at point: CGPoint, down: Bool) {
        guard let window, superview != nil else { return }
        let local = convert(point, from: window)
        let near = bounds.insetBy(dx: -24, dy: -24).contains(local)
        guard near || alpha < 1 else { return }
        pencilFade?.cancel()
        if near && down {
            acceptsTouches = false
            UIView.animate(withDuration: 0.12) { self.alpha = 0.22 }
        }
        pencilFade = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(near && down ? 1200 : 700))
            guard let self, !Task.isCancelled, self.superview != nil else { return }
            self.acceptsTouches = true
            UIView.animate(withDuration: 0.25) { self.alpha = 1 }
        }
    }
    override func accessibilityPerformEscape() -> Bool { NativeVideoPiP.shared.close(); return true }
}

/// What the controls show, and when they hide.
@MainActor
final class NativeVideoPiPControlsModel: ObservableObject {
    static var locale: Locale { Locale(identifier: NativeAppLocale.current) }
    let session: NativeVideoPiP.Session
    @Published private(set) var visible = false
    @Published private(set) var playing = false
    @Published private(set) var progress: (time: Double, duration: Double)?
    @Published var compact = false
    private var hiding: Task<Void, Never>?
    private var held = false
    init(session: NativeVideoPiP.Session) {
        self.session = session
        refresh()
    }
    var isWeb: Bool { session.source is NativeVideoPiPWebSource }
    func refresh() {
        if playing != session.source.isPlaying { playing = session.source.isPlaying }
        // Shown only with the controls, and only when the second on the clock changes: a view that redraws
        // twice a second keeps the app from ever looking idle (to VoiceOver and to UI tests).
        let next = session.source.progress
        if visible, next.map({ Int($0.time) }) != progress.map({ Int($0.time) }) || next.map({ Int($0.duration) }) != progress.map({ Int($0.duration) }) {
            progress = next
        }
        if !playing { hiding?.cancel(); hiding = nil } else if visible && hiding == nil && !held { scheduleHide() }
    }
    func toggle() { visible ? hide() : show() }
    func show() { progress = session.source.progress; visible = true; scheduleHide() }
    func hide() {
        guard !UIAccessibility.isVoiceOverRunning else { return }
        hiding?.cancel(); hiding = nil; visible = false
    }
    /// A finger is moving or sizing the window: the controls stay as they are.
    func hold() { held = true; hiding?.cancel(); hiding = nil }
    func release() { held = false; if visible { scheduleHide() } }
    /// A control was used: the controls stay a little longer.
    func touched() { if visible { scheduleHide() } }
    private func scheduleHide() {
        hiding?.cancel(); hiding = nil
        guard playing, !UIAccessibility.isVoiceOverRunning else { return }
        let delay: Double = ProcessInfo.processInfo.arguments.contains("--native-ui-testing") ? 10 : 3
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.hiding = nil
            withAnimation(.easeOut(duration: 0.2)) { self.visible = false }
        }
    }
    func playPause() { playing ? session.source.pause() : session.source.play(); playing.toggle(); touched() }
    func skip(_ seconds: Double) { session.source.skip(seconds); touched() }
    func close() { NativeVideoPiP.shared.close() }
    func returnToOrigin() { NativeVideoPiP.shared.returnToOrigin() }
}

/// One tap shows the controls; they hide again a few seconds into playback. ✕ stops; the other corner puts the
/// video back in its tab. Drawn over the picture only while shown.
struct NativeVideoPiPControls: View {
    @ObservedObject var model: NativeVideoPiPControlsModel
    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { model.toggle() } }
                .accessibilityHidden(true)
            if model.visible {
                ZStack {
                    LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0.2), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                    VStack(spacing: 0) {
                        HStack {
                            corner("PiP 닫기", symbol: "xmark", id: "native-video-pip-close", action: model.close)
                            Spacer(minLength: 0)
                            corner(model.isWeb ? "브라우저로 돌아가기" : "탭으로 돌아가기", symbol: "pip.exit", id: "native-video-pip-return", action: model.returnToOrigin)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: model.compact ? 14 : 26) {
                            transport("10초 뒤로", symbol: "gobackward.10", size: model.compact ? 20 : 24, id: "native-video-pip-back") { model.skip(-10) }
                            transport(model.playing ? "일시정지" : "재생", symbol: model.playing ? "pause.fill" : "play.fill", size: model.compact ? 30 : 36,
                                      id: "native-video-pip-play", action: model.playPause)
                            transport("10초 앞으로", symbol: "goforward.10", size: model.compact ? 20 : 24, id: "native-video-pip-forward") { model.skip(10) }
                        }
                        Spacer(minLength: 0)
                        if let progress = model.progress, progress.duration > 0 { progressBar(progress) } else { Color.clear.frame(height: 18) }
                    }.padding(6)
                }.transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .bandalLocalized()
    }
    private func corner(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30).background(.ultraThinMaterial, in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(Text(LocalizedStringKey(title))).accessibilityIdentifier(id)
    }
    private func transport(_ title: String, symbol: String, size: CGFloat, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(Text(LocalizedStringKey(title))).accessibilityIdentifier(id)
    }
    private func progressBar(_ progress: (time: Double, duration: Double)) -> some View {
        HStack(spacing: 8) {
            if !model.compact { Text(Self.clock(progress.time)).font(.system(size: 11, weight: .medium).monospacedDigit()) }
            GeometryReader { proxy in
                Capsule().fill(.white.opacity(0.3))
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: proxy.size.width * min(1, max(0, progress.time / progress.duration))) }
            }.frame(height: 3)
            if !model.compact { Text(Self.clock(progress.duration)).font(.system(size: 11, weight: .medium).monospacedDigit()) }
        }.frame(height: 18).padding(.horizontal, 8).padding(.bottom, 2)
            .accessibilityElement().accessibilityLabel(Text("재생 위치")).accessibilityValue(Text(Self.clock(progress.time) + " / " + Self.clock(progress.duration)))
            .accessibilityIdentifier("native-video-pip-progress")
    }
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// "PiP에서 재생 중 · 여기로 돌려놓기": what the video's tab shows while the window plays it.
struct NativeVideoPiPPlaceholder: View {
    let action: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "pip").font(.system(size: 34, weight: .light)).foregroundStyle(NativeDesktopTheme.muted)
            Text("PiP에서 재생 중").font(.system(size: 17, weight: .semibold)).foregroundStyle(NativeDesktopTheme.text)
            Button(action: action) { Label("여기로 돌려놓기", systemImage: "pip.exit") }
                .buttonStyle(NativeToolButtonStyle(primary: true))
                .accessibilityIdentifier("native-video-pip-bring-back")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativeGlass.paper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native-video-pip-placeholder")
    }
}
