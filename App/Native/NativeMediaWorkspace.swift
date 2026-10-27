import AVKit
import SwiftUI

struct NativeMediaWorkspace: View {
    let document: NativeDocumentReference
    @ObservedObject var store: NativeWorkspaceStore
    @StateObject private var playback = NativeMediaPlayback()
    @Environment(\.nativeEditorVisible) private var editorVisible
    @Environment(\.nativeWorkspaceChromeMode) private var chromeMode
    @Environment(\.nativeWorkspaceTopInset) private var topInset
    @Environment(\.nativeWorkspaceControlInset) private var controlInset
    var body: some View {
        Group {
            if let error = playback.error {
                ContentUnavailableView("재생할 수 없어요",systemImage:"play.slash",description:Text(error))
            } else if let player = playback.player {
                NativeMediaPlayerController(player:player, frozen:playback.frozen, showsControls: chromeMode != .toolsHidden, attach: playback.attach)
                    .nativeWorkspacePreviewSurface(id: document.id, capture: { try await playback.previewImage() })
            } else { ProgressView("미디어를 여는 중…") }
        }
        .padding(.top, controlInset > 0 ? topInset + 44 : topInset)
        .onChange(of: editorVisible) { _, visible in playback.setVisible(visible) }
        .task(id:document.id) { await playback.open(document,store:store) }
        .onDisappear { playback.close() }
        .onReceive(store.events) { event in
            guard let value = event.payload as? [String:Any], value["courseId"] as? String == document.courseID,
                  let path = (value["fromRelPath"] ?? value["relPath"]) as? String,
                  document.relativePath == path || (value["isDirectory"] as? Bool == true && document.relativePath.hasPrefix(path + "/")) else { return }
            if event.channel == "nativeWorkspace:materialWillMutate" { playback.freeze() }
            if event.channel == "nativeWorkspace:materialMutationCancelled" { playback.resume() }
            if ["nativeWorkspace:materialRenamed","nativeWorkspace:materialDeleted","nativeWorkspace:materialReplaced"].contains(event.channel) { playback.retire() }
        }
    }
}

@MainActor
final class NativeMediaPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var error: String?
    @Published private(set) var frozen = false
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
        let task = Task { @MainActor in
            await store.waitForExternalMutation()
            guard generation == self.generation, !self.retired, !Task.isCancelled else { return }
            guard let path = try await store.invokePrivate("nativeMaterial:path",["courseId":document.courseID,"relPath":document.relativePath]) as? String else { throw DesktopRuntimeError("미디어 파일을 찾지 못했습니다.") }
            let asset = AVURLAsset(url:URL(fileURLWithPath:path))
            let length = try await asset.load(.duration).seconds
            guard generation == self.generation, !Task.isCancelled else { return }
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
            observation = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:2,preferredTimescale:600),queue:.main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.ready else { return }
                    if self.frozen { self.player?.pause(); return }
                    if let player = self.player, player.rate > 0 { self.rate = player.rate; self.store?.markDocumentChanged() }
                }
            }
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
        guard !visible else { return }
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
    func retire() { retired = true; writesSuspended = false; frozen = true; close() }
    func close() {
        if !retired, ready, let player, let store, let document {
            let position = player.currentTime().seconds
            if position.isFinite, position >= 0 {
                let rate = min(3,max(0.25,player.rate > 0 ? player.rate : player.defaultRate))
                do { try store.panelViewStates.write(NativeMediaPanelState(position: position, rate: rate), id: document.id, kind: "media") }
                catch { store.errorMessage = error.localizedDescription }
            }
        }
        generation = UUID(); opening?.cancel(); opening = nil; player?.pause()
        if let observation { player?.removeTimeObserver(observation); self.observation = nil }
        if let token { store?.unregisterDocumentFlush(token); self.token = nil }
        ready = false; player = nil
    }
}

private struct NativeMediaPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let frozen: Bool
    let showsControls: Bool
    let attach: (AVPlayerViewController) -> Void
    func makeUIViewController(context:Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = player
        controller.allowsPictureInPicturePlayback = true; controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.view.accessibilityIdentifier = "native-media-player"
        controller.showsPlaybackControls = showsControls
        controller.view.isUserInteractionEnabled = !frozen
        attach(controller)
        return controller
    }
    func updateUIViewController(_ controller:AVPlayerViewController,context:Context) {
        if controller.player !== player { controller.player = player }
        controller.showsPlaybackControls = showsControls
        controller.view.isUserInteractionEnabled = !frozen
    }
}
