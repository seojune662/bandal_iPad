import Foundation
import AVFoundation
import UIKit

@MainActor
final class RecordingController: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var current: RecordingMetadata?
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackTime: TimeInterval = 0
    @Published private(set) var playingID: String?
    @Published private(set) var transcribingID: String?
    @Published private(set) var speechStatus = "모델을 설치하면 기기 안에서 전사합니다."
    @Published var error: String?
    @Published var selectedModel: LocalSpeechModel = .zipformer
    let models: SpeechModelStore
    private let root: URL
    private let onUpdate: (RecordingMetadata) -> Void
    private var engine: AVAudioEngine?
    private var writer: PCMRecordingWriter?
    private var timer: Timer?
    private var player: AVAudioPlayer?
    private var lastMetadataCheckpoint = 0
    private var transcription: Task<Void, Never>?
    private let speech = LocalSpeechEngine()
    private var recovered = false
    private var starting = false

    init(root: URL, onUpdate: @escaping (RecordingMetadata) -> Void) {
        self.root = root; self.onUpdate = onUpdate; models = SpeechModelStore(root: root)
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func recover() {
        guard !recovered else { return }; recovered = true
        let directory = root.appendingPathComponent("Recordings")
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for sidecar in files where sidecar.pathExtension == "json" {
            do {
                var metadata = try Self.decoder.decode(RecordingMetadata.self, from: Data(contentsOf: sidecar))
                guard metadata.state == "recording" || metadata.state == "paused" else { continue }
                let url = try audioURL(metadata)
                let frames = try PCMRecordingWriter.repair(url: url)
                metadata.duration = Double(frames) / 16000
                metadata.state = "recovered"
                persist(metadata)
            } catch { self.error = "중단된 녹음을 복구하지 못했습니다: \(error.localizedDescription)" }
        }
    }

    func start(courseID: String, title: String) async {
        guard !isRecording, !isPaused, !starting else { return }
        starting = true; defer { starting = false }
        error = nil
        let permission = await AVAudioApplication.requestRecordPermission()
        guard permission else { error = RecordingError.microphone.localizedDescription; return }
        do {
            stopPlayback()
            var item = RecordingMetadata(courseID: courseID, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "강의 녹음" : title,
                                         fileName: "")
            item.fileName = "Recordings/\(item.id).wav"
            writer = try PCMRecordingWriter(url: audioURL(item))
            writer?.onError = { [weak self] message in Task { @MainActor in self?.captureFailed(message) } }
            current = item; elapsed = 0; lastMetadataCheckpoint = 0
            persist(item)
            try startEngine()
            isRecording = true; isPaused = false
            if models.installed.contains(selectedModel), LocalSpeechEngine.available { beginTranscription(item, live: true) }
        } catch {
            self.error = error.localizedDescription
            writer?.close(); writer = nil
            if var item = current { item.state = "interrupted"; current = item; persist(item) }
        }
    }

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredSampleRate(16000)
        try session.setActive(true)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let writer else { throw RecordingError.microphone }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in writer.append(buffer) }
        engine.prepare()
        do { try engine.start(); self.engine = engine }
        catch { input.removeTap(onBus: 0); throw error }
    }

    func pause() {
        guard isRecording else { return }
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        writer?.synchronize()
        isRecording = false; isPaused = true
        elapsed = writer?.duration ?? elapsed
        if var item = current { item.duration = elapsed; item.state = "paused"; current = item; persist(item) }
    }
    func resume() {
        guard isPaused else { return }
        do {
            stopPlayback()
            try startEngine(); isRecording = true; isPaused = false
            if var item = current { item.state = "recording"; current = item; persist(item) }
        } catch { self.error = error.localizedDescription }
    }
    func stop() {
        guard isRecording || isPaused else { return }
        if isRecording { pause() }
        writer?.close()
        elapsed = writer?.duration ?? elapsed
        writer = nil
        isRecording = false; isPaused = false
        if var item = current { item.duration = elapsed; item.state = "completed"; current = item; persist(item) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func captureFailed(_ message: String) {
        stop(); error = "녹음을 중단했습니다: \(message)"
        if var item = current { item.state = "interrupted"; current = item; persist(item) }
    }

    func addAnchor(materialID: String, page: Int?) {
        guard var item = current, isRecording || isPaused else { return }
        item.anchors.append(RecordingAnchor(time: writer?.duration ?? elapsed, materialID: materialID, page: page))
        current = item; persist(item)
    }

    func play(_ item: RecordingMetadata, at time: TimeInterval = 0) {
        guard !isRecording else { error = "녹음을 일시정지한 뒤 재생할 수 있습니다."; return }
        do {
            if playingID != item.id {
                stopPlayback()
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback); try session.setActive(true)
                player = try AVAudioPlayer(contentsOf: audioURL(item)); player?.delegate = self
                player?.prepareToPlay(); playingID = item.id
            }
            player?.currentTime = max(0, time)
            isPlaying = player?.play() ?? false
        } catch { self.error = "녹음을 재생하지 못했습니다: \(error.localizedDescription)" }
    }
    func pausePlayback() { player?.pause(); isPlaying = false }
    func stopPlayback() { player?.stop(); player = nil; isPlaying = false; playingID = nil; playbackTime = 0 }
    func seek(_ time: TimeInterval) { player?.currentTime = max(0, time); playbackTime = player?.currentTime ?? 0 }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { isPlaying = false; playbackTime = 0 }

    func audioURL(_ item: RecordingMetadata) throws -> URL {
        let result = root.appendingPathComponent(item.fileName).standardizedFileURL
        let directory = root.appendingPathComponent("Recordings", isDirectory: true).standardizedFileURL.path + "/"
        guard result.path.hasPrefix(directory), result.pathExtension == "wav" else { throw RecordingError.invalidAudio }
        return result
    }

    func retranscribe(_ item: RecordingMetadata) {
        guard !isRecording, !isPaused else { error = "진행 중인 녹음을 마친 뒤 재전사해 주세요."; return }
        beginTranscription(item, live: false)
    }
    func cancelTranscription() { transcription?.cancel(); transcription = nil; transcribingID = nil; speechStatus = "전사를 취소했습니다. 원음은 보존됩니다." }

    private func beginTranscription(_ item: RecordingMetadata, live: Bool) {
        transcription?.cancel()
        guard LocalSpeechEngine.available else { speechStatus = RecordingError.runtimeUnavailable.localizedDescription; return }
        guard models.installed.contains(selectedModel) else { speechStatus = RecordingError.modelMissing.localizedDescription; return }
        let model = selectedModel, directory = models.directory(selectedModel)
        transcribingID = item.id
        transcription = Task { [weak self] in
            guard let self else { return }
            var result = item
            // Commit replacement transcripts only after a successful full re-run.
            if !live { result.segments = [] }
            var processed: TimeInterval = 0
            do {
                let url = try audioURL(item)
                speechStatus = "음성 모델을 준비하고 있습니다."
                try await speech.prepare(model: model, directory: directory)
                while !Task.isCancelled {
                    if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
                        speechStatus = "발열이 줄면 전사를 계속합니다. 녹음은 유지됩니다."
                        try await Task.sleep(for: .seconds(5)); continue
                    }
                    let captureContinues = live && current?.id == item.id && (isRecording || isPaused)
                    let available = live ? (current?.id == item.id ? writer?.duration ?? current?.duration ?? item.duration : result.duration) : item.duration
                    let remaining = available - processed
                    if remaining < 12 && captureContinues {
                        speechStatus = "기기에서 전사 중 · \(Self.timestamp(processed))까지 완료"
                        try await Task.sleep(for: .seconds(2)); continue
                    }
                    if remaining <= 0.01 { break }
                    writer?.synchronize()
                    let duration = min(18, remaining)
                    let text = try await speech.transcribe(url: url, start: processed, duration: duration)
                    try Task.checkCancellation()
                    if !text.isEmpty { result.segments.append(TranscriptSegment(time: processed, text: text)) }
                    processed += duration
                    if live, var latest = current, latest.id == item.id {
                        latest.segments = result.segments; current = latest; result = latest; persist(latest)
                    }
                    speechStatus = "기기에서 전사 중 · \(Self.timestamp(processed))까지 완료"
                }
                try Task.checkCancellation()
                if !live { persist(result); if current?.id == result.id { current = result } }
                speechStatus = "전사 완료 · 원음은 기기에 보관됩니다."
            } catch is CancellationError { return }
            catch { speechStatus = "전사를 완료하지 못했습니다: \(error.localizedDescription)" }
            if transcribingID == item.id { transcribingID = nil; transcription = nil }
        }
    }

    private func tick() {
        if let writer, isRecording || isPaused {
            elapsed = writer.duration
            let checkpoint = Int(elapsed) / 2
            if checkpoint != lastMetadataCheckpoint, var item = current {
                lastMetadataCheckpoint = checkpoint; item.duration = elapsed; current = item; persist(item)
            }
        }
        if isPlaying { playbackTime = player?.currentTime ?? 0 }
    }
    private func persist(_ metadata: RecordingMetadata) {
        do {
            let directory = root.appendingPathComponent("Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(metadata)
            try data.write(to: directory.appendingPathComponent("\(metadata.id).json"), options: .atomic)
            onUpdate(metadata)
        } catch { self.error = "녹음 기록을 저장하지 못했습니다: \(error.localizedDescription)" }
    }
    @objc private func interrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began, isRecording else { return }
        pause(); error = "오디오 사용이 중단되어 녹음을 일시정지했습니다. 다시 시작을 눌러 계속할 수 있습니다."
    }
    @objc private func routeChanged(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable, isRecording else { return }
        pause(); error = "마이크 연결이 변경되어 녹음을 일시정지했습니다."
    }
    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    static func timestamp(_ time: TimeInterval) -> String {
        let value = max(0, Int(time)); return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
