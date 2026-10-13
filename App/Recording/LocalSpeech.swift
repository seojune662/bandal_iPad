import Foundation
import CryptoKit
import AVFoundation
import Combine
#if canImport(SherpaOnnx)
@preconcurrency import SherpaOnnx
@preconcurrency import SherpaOnnxC
#endif

#if canImport(SherpaOnnx)
/// Access is confined to LocalSpeechEngine. C pointers are released even when
/// model creation fails, without the reference wrapper's fatalError behavior.
private final class NativeSpeechHandles: @unchecked Sendable {
    var online: OpaquePointer?
    var offline: OpaquePointer?
    func clear() {
        if let online { SherpaOnnxDestroyOnlineRecognizer(online) }
        if let offline { SherpaOnnxDestroyOfflineRecognizer(offline) }
        online = nil; offline = nil
    }
    deinit { clear() }
}
#endif

enum LocalSpeechModel: String, CaseIterable, Identifiable {
    case zipformer = "zipformer-ko", senseVoice = "sensevoice"
    var id: String { rawValue }
    var title: String { self == .zipformer ? "Zipformer · 한국어" : "SenseVoice · 다국어" }
    var sizeLabel: String { self == .zipformer ? "약 133 MB" : "약 240 MB" }
    var repository: String { self == .zipformer ? "k2-fsa/sherpa-onnx-streaming-zipformer-korean-2024-06-16" : "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17" }
    var revision: String { self == .zipformer ? "ba6078bca4daf3f0dd37f79d0ab505af71df14a6" : "2365baeacb507f821a0c8120fcee3d484dba7a07" }
    struct File { let name: String; let size: Int64; let sha256: String }
    var files: [File] {
        switch self {
        case .zipformer:
            [File(name: "encoder-epoch-99-avg-1.int8.onnx", size: 126968852, sha256: "8d0b1aa24fbedd4e3948564ab7facd151b8ce9b0c48fc987c541de2de3af5697"),
             File(name: "decoder-epoch-99-avg-1.int8.onnx", size: 2844692, sha256: "68ea197936aabd249f38b53a87c775422bca64428ad4427d0e6e8092593e71fb"),
             File(name: "joiner-epoch-99-avg-1.int8.onnx", size: 2581421, sha256: "128b80a66a1f718488af8560f9d15895109b99ff3e573f0a0130e03774ef1ced"),
             File(name: "tokens.txt", size: 60246, sha256: "016bdf0965029263b7ad01b742366ee542ef0bef38261510e8176ff6f2e9e668")]
        case .senseVoice:
            [File(name: "model.int8.onnx", size: 239233841, sha256: "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"),
             File(name: "tokens.txt", size: 315894, sha256: "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc")]
        }
    }
}

@MainActor
final class SpeechModelStore: ObservableObject {
    @Published var installed: Set<LocalSpeechModel> = []
    @Published var downloading: LocalSpeechModel?
    @Published var status = ""
    @Published var error: String?
    let root: URL
    private var downloadTask: Task<Void, Never>?
    init(root: URL) {
        self.root = root.appendingPathComponent("SpeechModels", isDirectory: true)
        refresh()
    }
    func directory(_ model: LocalSpeechModel) -> URL { root.appendingPathComponent(model.rawValue, isDirectory: true) }
    func refresh() {
        installed = Set(LocalSpeechModel.allCases.filter { model in
            model.files.allSatisfy { file in
                let attrs = try? FileManager.default.attributesOfItem(atPath: directory(model).appendingPathComponent(file.name).path)
                return (attrs?[.size] as? NSNumber)?.int64Value == file.size
            }
        })
    }
    func install(_ model: LocalSpeechModel) {
        guard downloading == nil else { return }
        downloading = model; error = nil
        downloadTask = Task {
            do {
                let directory = directory(model)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
                var mutableDirectory = directory; try mutableDirectory.setResourceValues(excluded)
                for (index, file) in model.files.enumerated() {
                    try Task.checkCancellation()
                    status = "\(model.title) \(index + 1)/\(model.files.count) 내려받는 중"
                    let destination = directory.appendingPathComponent(file.name)
                    if (try? await Task.detached(priority: .utility) { try Self.checksum(destination) }.value) == file.sha256 { continue }
                    let url = URL(string: "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(file.name)")!
                    let (temporary, response) = try await URLSession.shared.download(from: url)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    let attrs = try FileManager.default.attributesOfItem(atPath: temporary.path)
                    let hash = try await Task.detached(priority: .utility) { try Self.checksum(temporary) }.value
                    guard (attrs[.size] as? NSNumber)?.int64Value == file.size,
                          hash == file.sha256 else { throw URLError(.cannotDecodeContentData) }
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                status = "모델 설치 완료"; refresh()
            } catch is CancellationError { status = "다운로드 취소됨" }
            catch { self.error = "모델을 설치하지 못했습니다: \(error.localizedDescription)" }
            downloading = nil; downloadTask = nil
        }
    }
    func cancel() { downloadTask?.cancel() }
    nonisolated static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Each inference job runs on this actor, separately from realtime capture.
/// Jobs use bounded WAV windows, so long lectures do not load all PCM into RAM.
actor LocalSpeechEngine {
    static var available: Bool {
        #if canImport(SherpaOnnx)
        true
        #else
        false
        #endif
    }
    private var loadedModel: LocalSpeechModel?
    #if canImport(SherpaOnnx)
    private let handles = NativeSpeechHandles()
    #endif

    func prepare(model: LocalSpeechModel, directory: URL) throws {
        guard Self.available else { throw RecordingError.runtimeUnavailable }
        if loadedModel == model { return }
        for file in model.files {
            guard try SpeechModelStore.checksum(directory.appendingPathComponent(file.name)) == file.sha256 else { throw RecordingError.modelMissing }
        }
        #if canImport(SherpaOnnx)
        let tokens = directory.appendingPathComponent("tokens.txt").path
        if model == .zipformer {
            let encoder = directory.appendingPathComponent("encoder-epoch-99-avg-1.int8.onnx").path
            let decoder = directory.appendingPathComponent("decoder-epoch-99-avg-1.int8.onnx").path
            let joiner = directory.appendingPathComponent("joiner-epoch-99-avg-1.int8.onnx").path
            let transducer = sherpaOnnxOnlineTransducerModelConfig(encoder: encoder, decoder: decoder, joiner: joiner)
            let modelConfig = sherpaOnnxOnlineModelConfig(tokens: tokens, transducer: transducer, numThreads: 2)
            var config = sherpaOnnxOnlineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(), modelConfig: modelConfig, enableEndpoint: true)
            guard let recognizer = SherpaOnnxCreateOnlineRecognizer(&config) else { throw RecordingError.modelInitialization }
            handles.clear(); handles.online = recognizer
        } else {
            let path = directory.appendingPathComponent("model.int8.onnx").path
            let sense = sherpaOnnxOfflineSenseVoiceModelConfig(model: path, language: "auto", useInverseTextNormalization: true)
            let modelConfig = sherpaOnnxOfflineModelConfig(tokens: tokens, numThreads: 2, senseVoice: sense)
            var config = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(), modelConfig: modelConfig)
            guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else { throw RecordingError.modelInitialization }
            handles.clear(); handles.offline = recognizer
        }
        loadedModel = model
        #endif
    }

    func transcribe(url: URL, start: TimeInterval, duration: TimeInterval) throws -> String {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        file.framePosition = min(file.length, AVAudioFramePosition(start * format.sampleRate))
        let count = AVAudioFrameCount(min(Double(file.length - file.framePosition), duration * format.sampleRate))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return "" }
        try file.read(into: buffer, frameCount: count)
        guard let samples = buffer.floatChannelData?[0] else { throw RecordingError.invalidAudio }
        let audio = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
        let energy = audio.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(audio.count, 1))
        if energy < 0.000_001 { return "" }
        #if canImport(SherpaOnnx)
        if let recognizer = handles.online {
            guard let stream = SherpaOnnxCreateOnlineStream(recognizer) else { throw RecordingError.modelInitialization }
            defer { SherpaOnnxDestroyOnlineStream(stream) }
            SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(format.sampleRate), audio, Int32(audio.count))
            // Padding flushes the streaming model's final receptive field.
            let padding = [Float](repeating: 0, count: 8000)
            SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, padding, Int32(padding.count))
            SherpaOnnxOnlineStreamInputFinished(stream)
            while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
                try Task.checkCancellation(); SherpaOnnxDecodeOnlineStream(recognizer, stream)
            }
            guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { throw RecordingError.modelInitialization }
            defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
            guard let text = result.pointee.text else { return "" }
            return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let recognizer = handles.offline {
            guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw RecordingError.modelInitialization }
            defer { SherpaOnnxDestroyOfflineStream(stream) }
            SherpaOnnxAcceptWaveformOffline(stream, Int32(format.sampleRate), audio, Int32(audio.count))
            SherpaOnnxDecodeOfflineStream(recognizer, stream)
            guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw RecordingError.modelInitialization }
            defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
            guard let text = result.pointee.text else { return "" }
            return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw RecordingError.modelMissing
    }

    /// Selection and decoding share one actor turn. Concurrent sessions may
    /// request different models; no intervening prepare may change the model
    /// after this window has selected it.
    func transcribe(model: LocalSpeechModel, directory: URL, url: URL, start: TimeInterval, duration: TimeInterval) throws -> String {
        try prepare(model: model, directory: directory)
        return try transcribe(url: url, start: start, duration: duration)
    }
}
