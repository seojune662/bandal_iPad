import AVKit
import SwiftUI

struct NativeMediaWorkspace: View {
    let document: NativeDocumentReference
    @ObservedObject var store: NativeWorkspaceStore
    @StateObject private var playback = NativeMediaPlayback()
    var body: some View {
        Group {
            if let error = playback.error {
                ContentUnavailableView("재생할 수 없어요",systemImage:"play.slash",description:Text(error))
            } else if let player = playback.player {
                NativeMediaPlayerController(player:player, frozen:playback.frozen)
            } else { ProgressView("미디어를 여는 중…") }
        }
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
        token = store.registerDocumentFlush(id:document.id,
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
            rate = min(3,max(0.25,(progress?["playbackRate"] as? NSNumber)?.floatValue ?? 1))
            player.defaultRate = rate
            let position = max(0,(progress?["positionSec"] as? NSNumber)?.doubleValue ?? 0)
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
        _ = try await store.invoke("media:setProgress",["courseId":document.courseID,"relPath":document.relativePath,"positionSec":position,"durationSec":duration as Any? ?? NSNull(),"playbackRate":Double(rate)])
    }
    func freeze() {
        guard !retired, !frozen else { return }
        if let player { rate = min(3,max(0.25,player.rate > 0 ? player.rate : player.defaultRate)); player.defaultRate = rate }
        frozen = true; player?.pause()
    }
    func resume() { guard !retired else { return }; writesSuspended = false; frozen = false }
    func retire() { retired = true; writesSuspended = false; frozen = true; close() }
    func close() {
        generation = UUID(); opening?.cancel(); opening = nil; player?.pause()
        if let observation { player?.removeTimeObserver(observation); self.observation = nil }
        if let token { store?.unregisterDocumentFlush(token); self.token = nil }
        ready = false; player = nil
    }
}

private struct NativeMediaPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let frozen: Bool
    func makeUIViewController(context:Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = player
        controller.allowsPictureInPicturePlayback = true; controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.view.accessibilityIdentifier = "native-media-player"
        controller.view.isUserInteractionEnabled = !frozen
        return controller
    }
    func updateUIViewController(_ controller:AVPlayerViewController,context:Context) {
        if controller.player !== player { controller.player = player }
        controller.view.isUserInteractionEnabled = !frozen
    }
}
