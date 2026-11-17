import AVKit
import SwiftUI

struct NativeMediaWorkspace: View {
    let document: NativeDocumentReference
    var store: NativeWorkspaceStore
    @StateObject private var playback = NativeMediaPlayback()
    @Environment(\.nativeEditorVisible) private var editorVisible
    @Environment(\.nativeWorkspaceChromeMode) private var chromeMode
    @Environment(\.nativeWorkspaceTopInset) private var topInset
    @Environment(\.nativeWorkspaceControlInset) private var controlInset
    var body: some View {
        Group {
            if let error = playback.error {
                ContentUnavailableView("재생할 수 없어요",systemImage:"play.slash",description:Text(error))
            } else if playback.inPictureInPicture {
                NativeVideoPiPPlaceholder { NativeVideoPiP.shared.returnToOrigin() }
            } else if let player = playback.player {
                VStack(spacing: 0) {
                    if playback.hasVideo && chromeMode != .toolsHidden { pictureInPictureBar }
                    NativeMediaPlayerController(player:player, frozen:playback.frozen, showsControls: chromeMode != .toolsHidden, attach: playback.attach, leaving: playback.leaving)
                        .nativeWorkspacePreviewSurface(id: document.id, capture: { try await playback.previewImage() })
                }
            } else { ProgressView("미디어를 여는 중…") }
        }
        .padding(.top, controlInset > 0 ? topInset + 44 : topInset)
        .onChange(of: editorVisible) { _, visible in playback.setVisible(visible) }
        .task(id:document.id) { await playback.open(document,store:store) }
        // Choosing another tab or closing this one while the video plays: it goes on in PiP (설정 › 일반 › 영상).
        .onDisappear { playback.disappear() }
        .onReceive(store.events) { event in
            guard let value = event.payload as? [String:Any], value["courseId"] as? String == document.courseID,
                  let path = (value["fromRelPath"] ?? value["relPath"]) as? String,
                  document.relativePath == path || (value["isDirectory"] as? Bool == true && document.relativePath.hasPrefix(path + "/")) else { return }
            if event.channel == "nativeWorkspace:materialWillMutate" { playback.freeze() }
            if event.channel == "nativeWorkspace:materialMutationCancelled" { playback.resume() }
            if ["nativeWorkspace:materialRenamed","nativeWorkspace:materialDeleted","nativeWorkspace:materialReplaced"].contains(event.channel) { playback.retire() }
        }
    }
    private var pictureInPictureBar: some View {
        HStack {
            Spacer(minLength: 0)
            Button { _ = playback.startPictureInPicture() } label: { Label("PiP로 보기", systemImage: "pip.enter") }
                .buttonStyle(NativeToolButtonStyle(compact: true)).disabled(playback.frozen)
                .accessibilityHint(Text("영상을 작은 창으로 띄워 다른 탭을 보면서 이어 봐요"))
                .accessibilityIdentifier("native-video-pip-start")
        }.padding(.horizontal, 12).frame(height: 44)
            .overlay(alignment: .bottom) { NativeGlass.hairline.frame(height: 1) }
    }
}

@MainActor
final class NativeMediaPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var error: String?
    @Published private(set) var frozen = false
    /// The PiP window plays this player; the tab shows "PiP에서 재생 중".
    @Published private(set) var inPictureInPicture = false
    /// A video track: an audio file has nothing to show in PiP.
    @Published private(set) var hasVideo = false
    private weak var store: NativeWorkspaceStore?
    private weak var presentation: AVPlayerViewController?
    private var document: NativeDocumentReference?
    private var token: UUID?
    private var observation: Any?
    private var duration: Double?
    private var rate: Float = 1
    private var generation = UUID()
    private var ready = false
    private var retired = false, writesSuspended = false
    private var opening: Task<Void, Error>?
    func open(_ document: NativeDocumentReference,store: NativeWorkspaceStore) async {
        close(); let generation = UUID(); self.generation = generation
        self.store = store; self.document = document; error = nil; retired = false; frozen = false; writesSuspended = false
        token = store.registerDocumentFlush(id:document.id, document: document,
            freeze: { [weak self] in self?.freeze() },
            suspendWrites: { [weak self] in self?.writesSuspended = true },
            resume: { [weak self] in self?.resume() },
            retire: { [weak self] in self?.retire() },
            flush: { [weak self] in try await self?.save() })
        // The PiP window plays this document: take its player as it is, still playing, without reopening the file.
        if let source = NativeVideoPiP.shared.mediaSource(for: document.id) {
            let player = source.player
            self.player = player; hasVideo = true; inPictureInPicture = true
            let length = player.currentItem?.duration.seconds ?? .nan
            duration = length.isFinite && length >= 0 ? length : nil
            rate = min(3, max(0.25, player.defaultRate))
            ready = true; observe(player)
            if source.adopt(by: self) { inPictureInPicture = false }
            return
        }
        let task = Task { @MainActor in
            await store.waitForExternalMutation()
            guard generation == self.generation, !self.retired, !Task.isCancelled else { return }
            guard let path = try await store.invokePrivate("nativeMaterial:path",["courseId":document.courseID,"relPath":document.relativePath]) as? String else { throw DesktopRuntimeError("미디어 파일을 찾지 못했습니다.") }
            let asset = AVURLAsset(url:URL(fileURLWithPath:path))
            let length = try await asset.load(.duration).seconds
            let visual = try await !asset.loadTracks(withMediaType: .video).isEmpty
            guard generation == self.generation, !Task.isCancelled else { return }
            hasVideo = visual
            let progress = try await store.invoke("media:getProgress",["courseId":document.courseID,"relPath":document.relativePath]) as? [String:Any]
            guard generation == self.generation, !Task.isCancelled else { return }
            let player = AVPlayer(playerItem:AVPlayerItem(asset:asset)); self.player = player
            duration = length.isFinite && length >= 0 ? length : nil
            let saved = store.panelViewStates.read(NativeMediaPanelState.self, id: document.id, kind: "media")
            let panel = saved?.isValid == true ? saved : nil
            rate = min(3,max(0.25,panel?.rate ?? (progress?["playbackRate"] as? NSNumber)?.floatValue ?? 1))
            player.defaultRate = rate
            let position = max(0,panel?.position ?? (progress?["positionSec"] as? NSNumber)?.doubleValue ?? 0)
            await player.seek(to:CMTime(seconds:min(position,duration ?? position),preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
            guard generation == self.generation, !Task.isCancelled else { player.pause(); return }
            ready = true
            observe(player)
        }
        opening = task
        do { try await task.value; if generation == self.generation { opening = nil } }
        catch { if generation == self.generation { opening = nil; self.error = error.localizedDescription } }
    }
    func save() async throws {
        if writesSuspended { await store?.waitForExternalMutation() }
        guard !retired else { return }
        if let opening { try await opening.value }
        guard ready, let player, let document, let store else { return }
        let position = player.currentTime().seconds
        guard position.isFinite,position >= 0 else { return }
        if !frozen { rate = min(3,max(0.25,player.rate > 0 ? player.rate : player.defaultRate)) }
        try store.panelViewStates.write(NativeMediaPanelState(position: position, rate: rate), id: document.id, kind: "media")
        // Keep the canonical file default for newly opened panels, while every
        // existing panel restores its own persisted state above.
        _ = try await store.invoke("media:setProgress",["courseId":document.courseID,"relPath":document.relativePath,"positionSec":position,"durationSec":duration as Any? ?? NSNull(),"playbackRate":Double(rate)])
    }
    private func observe(_ player: AVPlayer) {
        observation = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:2,preferredTimescale:600),queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.ready else { return }
                if self.frozen { self.player?.pause(); return }
                if let player = self.player, player.rate > 0 { self.rate = player.rate; self.store?.markDocumentChanged() }
            }
        }
    }
    /// PiP로 보기: the window takes this very player, so the picture goes on without a pause.
    @discardableResult
    func startPictureInPicture() -> Bool {
        guard ready, hasVideo, !frozen, !retired, !inPictureInPicture, let player, let document else { return false }
        let source = NativeVideoPiPMediaSource(player: player, document: document, store: store, owner: self)
        guard NativeVideoPiP.shared.start(source, origin: NativeVideoPiPOrigin(document: document)) else { return false }
        inPictureInPicture = true
        return true
    }
    /// The window closed (the player is paused) or gave the player back (it plays on here).
    func pictureInPictureEnded(returned: Bool) {
        inPictureInPicture = false
        if !returned { Task { try? await save() } }
    }
    /// The tab is going away while its player is still on screen: a playing video goes on in PiP when
    /// 탭을 떠나면 PiP로 이어 보기 is on. AVKit is let go of the player first, or it would pause it as it leaves.
    func leaving() {
        NativeInputTrace.record("pip.media.leaving", "inPiP=\(inPictureInPicture) auto=\(NativeVideoPiPPreferences.autoStarts) status=\(player?.timeControlStatus.rawValue ?? -1)")
        guard !inPictureInPicture, NativeVideoPiPPreferences.autoStarts, let player, player.timeControlStatus != .paused || player.rate > 0 else { return }
        if startPictureInPicture() { presentation?.player = nil }
    }
    func disappear() {
        leaving()
        close()
    }
    func attach(_ controller: AVPlayerViewController) { presentation = controller }
    func previewImage() async throws -> UIImage? {
        guard let controller = presentation, let player, let asset = player.currentItem?.asset,
              controller.view.bounds.width > 0, controller.view.bounds.height > 0 else { return nil }
        let generation = self.generation, bounds = controller.view.bounds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard generation == self.generation, !Task.isCancelled, controller.view.bounds == bounds else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.opaque = true; format.scale = min(1, 1600 / max(bounds.width, bounds.height))
        if tracks.isEmpty {
            return UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in controller.view.layer.render(in: renderer.cgContext) }
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1600, height: 1600)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: player.currentTime()).image
        guard generation == self.generation, !Task.isCancelled, controller.view.bounds == bounds else { return nil }
        let image = UIImage(cgImage: frame)
        let scale = controller.videoGravity == .resizeAspectFill
            ? max(bounds.width / image.size.width, bounds.height / image.size.height)
            : min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = controller.videoGravity == .resize ? bounds.size : CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
            UIColor.black.setFill(); renderer.fill(bounds)
            image.draw(in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
    }
    func setVisible(_ visible: Bool) {
        NativeInputTrace.record("pip.media.visible", "\(visible) inPiP=\(inPictureInPicture)")
        guard !visible, !inPictureInPicture else { return }
        if let player { rate = min(3,max(0.25,player.rate > 0 ? player.rate : player.defaultRate)); player.defaultRate = rate }
        player?.pause()
        Task { do { try await save() } catch { self.error = error.localizedDescription } }
    }
    func freeze() {
        guard !retired, !frozen else { return }
        if let player { rate = min(3,max(0.25,player.rate > 0 ? player.rate : player.defaultRate)); player.defaultRate = rate }
        frozen = true; player?.pause()
    }
    func resume() { guard !retired else { return }; writesSuspended = false; frozen = false }
    func retire() {
        // The file was renamed, replaced or deleted: the PiP window cannot go on with the old one.
        if inPictureInPicture { NativeVideoPiP.shared.close() }
        retired = true; writesSuspended = false; frozen = true; close()
    }
    func close() {
        if !retired, ready, let player, let store, let document {
            let position = player.currentTime().seconds
            if position.isFinite, position >= 0 {
                let rate = min(3,max(0.25,player.rate > 0 ? player.rate : player.defaultRate))
                do { try store.panelViewStates.write(NativeMediaPanelState(position: position, rate: rate), id: document.id, kind: "media") }
                catch { store.errorMessage = error.localizedDescription }
            }
        }
        generation = UUID(); opening?.cancel(); opening = nil
        // In PiP the window keeps the player playing; it saves where it stops if the tab does not come back.
        if inPictureInPicture, let document { NativeVideoPiP.shared.mediaSource(for: document.id)?.owner = nil } else { player?.pause() }
        if let observation { player?.removeTimeObserver(observation); self.observation = nil }
        if let token { store?.unregisterDocumentFlush(token); self.token = nil }
        ready = false; player = nil; inPictureInPicture = false
    }
}

private struct NativeMediaPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let frozen: Bool
    let showsControls: Bool
    let attach: (AVPlayerViewController) -> Void
    /// The player is about to leave the screen (its tab went away): AVKit pauses a player it stops showing.
    let leaving: () -> Void
    func makeUIViewController(context:Context) -> Host {
        let controller = AVPlayerViewController(); controller.player = player
        // The system's PiP needs background audio, which the app does not declare: the app's own window (PiP로 보기) instead.
        controller.allowsPictureInPicturePlayback = false
        controller.view.accessibilityIdentifier = "native-media-player"
        controller.showsPlaybackControls = showsControls
        controller.view.isUserInteractionEnabled = !frozen
        attach(controller)
        let host = Host(controller: controller); host.leaving = leaving
        return host
    }
    func updateUIViewController(_ host: Host, context:Context) {
        let controller = host.controller
        if controller.player !== player { controller.player = player }
        controller.showsPlaybackControls = showsControls
        controller.view.isUserInteractionEnabled = !frozen
        host.leaving = leaving
    }
    /// Holds the AVKit controller and hears, while it is still on screen, that it is about to go.
    final class Host: UIViewController {
        let controller: AVPlayerViewController
        var leaving: () -> Void = {}
        init(controller: AVPlayerViewController) { self.controller = controller; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func loadView() {
            let view = LeavingView(); view.willLeave = { [weak self] in self?.leaving() }
            self.view = view
            addChild(controller)
            controller.view.frame = view.bounds; controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(controller.view)
            controller.didMove(toParent: self)
        }
    }
    final class LeavingView: UIView {
        var willLeave: (() -> Void)?
        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil, window != nil { willLeave?() }
            super.willMove(toWindow: newWindow)
        }
    }
}
