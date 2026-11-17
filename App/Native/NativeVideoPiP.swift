import AVFoundation
import Combine
import UIKit
import WebKit

/// 영상 PiP: a video keeps playing in a small window over every pane, sidebar and palette of the app, which the
/// person moves and sizes freely. In-app only (no UIBackgroundModes audio, which App Review 2.5.4 refused in
/// 1.0.0): it is not shown over other apps, and a video pauses when the app leaves the foreground.
///
/// The window shows the very player that was playing, so nothing restarts or buffers:
/// - a downloaded video: the tab's `AVPlayer`, drawn by another `AVPlayerLayer`;
/// - a web video (YouTube or any site): the tab's own web view, moved into the window inside the same UIKit
///   window (WebKit never sees it leave the screen) and cropped to the video's rectangle.
enum NativeVideoPiPPreferences {
    /// Leaving a tab while its video plays (choosing another tab or closing it) moves the video to PiP.
    static let autoKey = "native.video.autoPiP"
    /// Where the window was and how wide (`NativeVideoPiPGeometry.Placement`).
    static let placementKey = "native.video.pipPlacement"
    static var autoStarts: Bool { NativeLocalPreferences.bool(autoKey) }
    #if DEBUG
    static func resetForUITesting() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--native-ui-testing"), arguments.contains("--reset-native-ui-testing") else { return }
        [autoKey, placementKey].forEach(UserDefaults.standard.removeObject(forKey:))
    }
    #endif
}

/// The tab a PiP video came from. `document` is nil only for the browser outside any folder (the 브라우저 screen).
struct NativeVideoPiPOrigin {
    var document: NativeDocumentReference?
    /// The page's tab inside a browser.
    var browserTabID: String?
}

@MainActor
protocol NativeVideoPiPSource: AnyObject {
    /// What the window draws; the window sizes it with `layout(in:)`.
    var view: UIView { get }
    /// The picture's width over its height.
    var aspectRatio: CGFloat { get }
    var isPlaying: Bool { get }
    /// Seconds played and the length, when the source knows them (a live stream has no length).
    var progress: (time: Double, duration: Double)? { get }
    /// Called when the picture's shape, play state or progress changes.
    var onChange: (() -> Void)? { get set }
    func play()
    func pause()
    func skip(_ seconds: Double)
    func layout(in bounds: CGRect)
    /// The window is on screen with `view` in it: a web page moves its web view in now, window to window.
    func attached()
    /// ✕: pause and give the player back to nobody (its tab shows it paused, or saves where it stopped).
    func stop()
    /// 돌아가기 was chosen and the origin tab is being opened. Return true once the tab has taken the player back.
    func beginReturn() -> Bool
}

@MainActor
final class NativeVideoPiP: ObservableObject {
    static let shared = NativeVideoPiP()
    final class Session: Identifiable {
        let id = UUID()
        let origin: NativeVideoPiPOrigin
        let source: NativeVideoPiPSource
        fileprivate(set) var returning = false
        init(origin: NativeVideoPiPOrigin, source: NativeVideoPiPSource) { self.origin = origin; self.source = source }
    }
    @Published private(set) var session: Session?
    /// The layer the window lives in (`NativeVideoPiPCanvas`); it is mounted over the whole workspace.
    weak var canvas: NativeVideoPiPCanvas?
    weak var store: NativeWorkspaceStore?
    weak var browser: DesktopBrowserHost? {
        didSet {
            browser?.pictureInPicture = self
            browser?.onVideoChange = { [weak self] page in self?.browserVideoChanged(page) }
        }
    }
    private var returnTimeout: Task<Void, Never>?

    private init() {
        #if DEBUG
        NativeVideoPiPPreferences.resetForUITesting()
        #endif
    }

    @discardableResult
    func start(_ source: NativeVideoPiPSource, origin: NativeVideoPiPOrigin) -> Bool {
        NativeInputTrace.record("pip.start", "\(type(of: source)) canvas=\(canvas != nil) window=\(canvas?.window != nil)")
        guard let canvas, canvas.window != nil else { return false }
        if session != nil { close() }
        let session = Session(origin: origin, source: source)
        self.session = session
        canvas.present(session)
        session.source.attached()
        UIAccessibility.post(notification: .screenChanged, argument: canvas.windowView)
        return true
    }
    /// ✕: the video stops; its tab keeps it where it stopped.
    func close() {
        guard let session else { return }
        end(session)
        session.source.stop()
    }
    /// 돌아가기: open the video's tab and give the player back to it, still playing.
    func returnToOrigin() {
        guard let session, !session.returning else { return }
        session.returning = true
        objectWillChange.send()
        if let store {
            store.events.send(.init(channel: "nativeVideoPiP:return", payload: session.origin.document as Any))
        }
        if session.source.beginReturn() { end(session); return }
        returnTimeout?.cancel()
        returnTimeout = Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, let session, self.session === session, !Task.isCancelled else { return }
            // The tab never showed (a refused transition, a closed folder): stop rather than play on unseen.
            self.close()
        }
    }
    /// A source took its player back (the tab is showing it).
    func finishReturn(_ source: NativeVideoPiPSource) {
        guard let session, session.source === source else { return }
        end(session)
    }
    private func end(_ session: Session) {
        guard self.session === session else { return }
        returnTimeout?.cancel(); returnTimeout = nil
        self.session = nil
        canvas?.dismiss(session)
    }
    func holds(documentID: String) -> Bool { session?.origin.document?.id == documentID }
    func holds(browserTabID: String) -> Bool { session?.origin.browserTabID == browserTabID }

    // MARK: Downloaded video

    /// The PiP source showing this document's player, if any.
    func mediaSource(for documentID: String) -> NativeVideoPiPMediaSource? {
        guard let source = session?.source as? NativeVideoPiPMediaSource, source.document.id == documentID else { return nil }
        return source
    }
    var isReturning: Bool { session?.returning == true }

    // MARK: Web video

    /// PiP로 보기 in a browser tab, or leaving a tab whose video plays.
    @discardableResult
    func startWeb(_ page: DesktopBrowserPage, origin: NativeVideoPiPOrigin) -> Bool {
        guard let report = page.video, let browser, let canvas, canvas.window != nil, page.liveWebView?.window != nil, !page.inPictureInPicture else { return false }
        // The window that plays now lets its page go first: its layout pass must not meet this page half-moved.
        if session != nil { close() }
        return start(NativeVideoPiPWebSource(page: page, report: report, host: browser), origin: origin)
    }
    private func browserVideoChanged(_ page: DesktopBrowserPage) {
        (session?.source as? NativeVideoPiPWebSource).map { if $0.page === page { $0.videoChanged() } }
    }
    /// Which tab a page belongs to, for 돌아가기. Set by the browser screens as they show their pages.
    private var browserOrigins: [String: NativeVideoPiPOrigin] = [:]
    func register(browserTab tabID: String, origin: NativeVideoPiPOrigin) { browserOrigins[tabID] = origin }
}

extension NativeVideoPiP: DesktopBrowserPictureInPicture {
    func browserPageWillHide(_ page: DesktopBrowserPage) -> Bool {
        guard NativeVideoPiPPreferences.autoStarts, page.video?.state.continuesInPiP == true,
              let origin = browserOrigins[page.tabID] else { return false }
        return startWeb(page, origin: origin)
    }
    func browserPageWillClose(_ page: DesktopBrowserPage) -> Bool {
        if let source = session?.source as? NativeVideoPiPWebSource, source.page === page {
            // A private page ends with its tab, and its video with it.
            if page.isPrivate { close(); return false }
            source.tabClosed(); return true
        }
        // Closing the tab that shows it: the video goes on in PiP (when 탭을 떠나면 PiP is on).
        guard !page.isPrivate, page.bounds != nil, browserPageWillHide(page), let source = session?.source as? NativeVideoPiPWebSource, source.page === page else { return false }
        source.tabClosed()
        return true
    }
    func browserPage(_ page: DesktopBrowserPage, returnsTo target: UIView) -> Bool {
        guard let source = session?.source as? NativeVideoPiPWebSource, source.page === page else {
            // A page that thinks it is in PiP with no window holding it: let it come home.
            page.inPictureInPicture = false
            return true
        }
        guard session?.returning == true else { return false }
        source.finishReturn(into: target)
        finishReturn(source)
        return true
    }
}

// MARK: - Downloaded video

/// The tab's own `AVPlayer`, drawn in the window by a second `AVPlayerLayer`. The tab (`NativeMediaPlayback`)
/// shows "PiP에서 재생 중" meanwhile, and takes the same player back on 돌아가기 or when the window closes.
@MainActor
final class NativeVideoPiPMediaSource: NativeVideoPiPSource {
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    let player: AVPlayer
    let document: NativeDocumentReference
    private weak var store: NativeWorkspaceStore?
    /// The tab while it is on screen; nil after it closed (the window then saves where the video stopped).
    weak var owner: NativeMediaPlayback?
    private let playerView = PlayerView()
    private var observations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    var onChange: (() -> Void)?
    var view: UIView { playerView }

    init(player: AVPlayer, document: NativeDocumentReference, store: NativeWorkspaceStore?, owner: NativeMediaPlayback?) {
        self.player = player; self.document = document; self.store = store; self.owner = owner
        playerView.playerLayer.player = player
        playerView.playerLayer.videoGravity = .resizeAspect
        playerView.backgroundColor = .black
        playerView.isAccessibilityElement = false
        observations = [
            player.observe(\.timeControlStatus) { [weak self] _, _ in Task { @MainActor in self?.onChange?() } },
            player.observe(\.currentItem?.presentationSize) { [weak self] _, _ in Task { @MainActor in self?.onChange?() } },
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }
    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }
    var aspectRatio: CGFloat {
        let size = player.currentItem?.presentationSize ?? .zero
        return size.width > 0 && size.height > 0 ? size.width / size.height : 16 / 9
    }
    var isPlaying: Bool { player.timeControlStatus != .paused }
    var progress: (time: Double, duration: Double)? {
        let time = player.currentTime().seconds, duration = player.currentItem?.duration.seconds ?? .nan
        guard time.isFinite else { return nil }
        return (max(0, time), duration.isFinite ? duration : 0)
    }
    func play() {
        // At the end, ▶ starts it over (AVPlayer would stay at the end).
        let time = player.currentTime().seconds, duration = player.currentItem?.duration.seconds ?? .nan
        if time.isFinite, duration.isFinite, duration > 0, time >= duration - 0.25 { player.seek(to: .zero) }
        player.play()
    }
    func pause() { player.pause() }
    func skip(_ seconds: Double) {
        let target = NativeVideoPiPPlayback.skipTarget(from: player.currentTime().seconds, by: seconds, duration: player.currentItem?.duration.seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func layout(in bounds: CGRect) { playerView.frame = bounds }
    func attached() {}
    func stop() {
        player.pause()
        playerView.playerLayer.player = nil
        if let owner { owner.pictureInPictureEnded(returned: false) }
        else { save() }
    }
    func beginReturn() -> Bool {
        guard let owner else { return false }
        playerView.playerLayer.player = nil
        owner.pictureInPictureEnded(returned: true)
        return true
    }
    /// The tab opened again while the window showed its video: it takes the player when 돌아가기 comes.
    func adopt(by playback: NativeMediaPlayback) -> Bool {
        owner = playback
        guard NativeVideoPiP.shared.isReturning else { return false }
        playerView.playerLayer.player = nil
        NativeVideoPiP.shared.finishReturn(self)
        return true
    }
    /// Where the video stopped, for this file and for the tab if it opens again.
    private func save() {
        guard let store, let item = player.currentItem else { return }
        let position = player.currentTime().seconds
        guard position.isFinite, position >= 0 else { return }
        let rate = min(3, max(0.25, player.defaultRate))
        try? store.panelViewStates.write(NativeMediaPanelState(position: position, rate: rate), id: document.id, kind: "media")
        let duration = item.duration.seconds
        Task { _ = try? await store.invoke("media:setProgress", ["courseId": document.courseID, "relPath": document.relativePath, "positionSec": position,
                                                                 "durationSec": duration.isFinite ? duration : NSNull(), "playbackRate": Double(rate)]) }
    }
}

enum NativeVideoPiPPlayback {
    /// ±10 s, kept inside the video. A live stream (no length) only stops at zero.
    static func skipTarget(from time: Double, by seconds: Double, duration: Double?) -> Double {
        let start = time.isFinite ? max(0, time) : 0
        let end = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? .infinity
        return min(end, max(0, start + seconds))
    }
}

// MARK: - Web video

/// The tab's web view itself, moved into the window and cropped to the video. The page keeps its size (no
/// reflow); a scale transform shows only the video's rectangle. Touches do not reach the page while it is here.
@MainActor
final class NativeVideoPiPWebSource: NativeVideoPiPSource {
    let page: DesktopBrowserPage
    private weak var host: DesktopBrowserHost?
    private var report: BrowserVideoReport
    private let webView: WKWebView
    private let container = UIView()
    /// The video's rectangle as fractions of the web view.
    private var crop: CGRect
    private var size: CGSize
    private var bounds = CGRect.zero
    private var tracking: Task<Void, Never>?
    private var missing = 0
    /// Its tab closed: the host keeps the page for the window (`pictureInPicturePages`).
    private(set) var detached = false
    private var playing: Bool
    /// The last state read while following the video (`track`): the page reports time only on its own events.
    private var latest: BrowserVideoState?
    var onChange: (() -> Void)?
    var view: UIView { container }

    init(page: DesktopBrowserPage, report: BrowserVideoReport, host: DesktopBrowserHost) {
        self.page = page; self.report = report; self.host = host
        webView = page.webView
        size = webView.bounds.size == .zero ? CGSize(width: 960, height: 540) : webView.bounds.size
        // Where the video was at its last event; following it (`track`) corrects this within a moment.
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        crop = report.isMainFrame ? report.state.rect.map { $0.intersection(full) }.flatMap { $0.width > 0.01 && $0.height > 0.01 ? $0 : nil } ?? full : full
        playing = report.state.playing
        container.clipsToBounds = true
        container.backgroundColor = .black
        container.isAccessibilityElement = false
        container.accessibilityElementsHidden = true
    }
    func attached() {
        guard !page.inPictureInPicture else { return }
        page.inPictureInPicture = true
        // From the tab's viewport into the window, both on screen, in one call: WebKit never sees the page leave.
        let frame = webView.frame
        container.addSubview(webView)
        webView.transform = .identity; webView.frame = CGRect(origin: .zero, size: frame.size)
        webView.isHidden = false
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        layout(in: bounds)
        tracking = Task { [weak self] in await self?.track() }
    }

    var aspectRatio: CGFloat {
        let width = crop.width * size.width, height = crop.height * size.height
        return width > 0 && height > 0 ? width / height : 16 / 9
    }
    var isPlaying: Bool { playing }
    var progress: (time: Double, duration: Double)? {
        let state = latest ?? page.video?.state ?? report.state
        return (state.time, state.duration)
    }
    func play() { playing = true; onChange?(); call("return __bandalVideo.play()") }
    func pause() { playing = false; onChange?(); call("return __bandalVideo.pause()") }
    func skip(_ seconds: Double) { call("return __bandalVideo.skip(\(seconds))") }
    private func call(_ body: String) {
        let page = page, frame = report.frame
        Task { _ = try? await page.videoCall(body, frame: frame) }
    }
    func layout(in bounds: CGRect) {
        self.bounds = bounds
        container.frame = bounds
        let video = CGRect(x: crop.minX * size.width, y: crop.minY * size.height, width: crop.width * size.width, height: crop.height * size.height)
        guard webView.superview === container, video.width > 0, video.height > 0, bounds.width > 0 else { return }
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        webView.transform = .identity
        webView.bounds = CGRect(origin: .zero, size: size)
        webView.transform = CGAffineTransform(scaleX: scale, y: scale)
        // Centre the video's rectangle in the window.
        let offset = CGPoint(x: (bounds.width - video.width * scale) / 2, y: (bounds.height - video.height * scale) / 2)
        webView.center = CGPoint(x: (size.width / 2 - video.minX) * scale + offset.x, y: (size.height / 2 - video.minY) * scale + offset.y)
    }
    func videoChanged() {
        if let report = page.video { self.report = report; playing = report.state.playing }
        onChange?()
    }
    func tabClosed() { detached = true }
    func stop() {
        tracking?.cancel()
        let page = page, frame = report.frame
        Task { _ = try? await page.videoCall("__bandalVideo.pause(); __bandalVideo.release(); return true", frame: frame) }
        restore()
        if detached { host?.releasePictureInPicturePage(page) } else { host?.layoutPages() }
    }
    func beginReturn() -> Bool {
        if detached { host?.adoptPictureInPicturePage(page); detached = false }
        // The tab may already show (another pane): its viewport takes the web view at once.
        host?.layoutPages()
        return !page.inPictureInPicture
    }
    /// The tab's viewport is on screen: the web view goes straight there.
    func finishReturn(into target: UIView) {
        tracking?.cancel()
        let page = page, frame = report.frame
        Task { _ = try? await page.videoCall("__bandalVideo.release(); return true", frame: frame) }
        restore(into: target)
    }
    private func restore(into target: UIView? = nil) {
        page.inPictureInPicture = false
        webView.transform = .identity
        webView.isUserInteractionEnabled = true
        webView.accessibilityElementsHidden = false
        if let target { target.addSubview(webView); webView.frame = target.bounds }
        else if webView.superview === container {
            // Not on screen anywhere until its tab shows it again (`layoutPages` adds it to the tab's viewport).
            webView.isHidden = true
            if let home = host?.container { home.addSubview(webView) } else { webView.removeFromSuperview() }
        }
    }
    /// Follow the video while the window shows it: a page may move it (a theatre mode, the next video).
    private func track() async {
        var first = true
        while !Task.isCancelled {
            if let frame = try? await page.videoFrame(select: first, in: report), !Task.isCancelled {
                first = false; missing = 0
                let rect = frame.rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                if !rect.isNull, rect.width > 0.01, rect.height > 0.01, rect != crop {
                    crop = rect; size = webView.bounds.size == .zero ? size : webView.bounds.size
                    layout(in: bounds); onChange?()
                }
                latest = frame.state
                if frame.state.playing != playing { playing = frame.state.playing }
                onChange?()
            } else if !Task.isCancelled {
                missing += 1
                // The page went somewhere without a video for a while: nothing left to watch.
                if missing >= 8 { NativeVideoPiP.shared.close(); return }
            }
            try? await Task.sleep(for: .milliseconds(first ? 150 : 700))
        }
    }
}
