import Foundation
import AVFoundation
import Combine
import UIKit

/// The original renderer/repository remain the UI and metadata authority.
/// Native capture writes the repository's mono 16 kHz PCM16 WAV format.
@MainActor
final class DesktopRecordingService {
    typealias Invoke = (String, [String: Any]) async throws -> Any
    private let invoke: Invoke
    private let models: SpeechModelStore
    private let speech = LocalSpeechEngine()
    var emit: (String, Any) -> Void = { _, _ in }
    private var engine: AVAudioEngine?
    private var writer: PCMRecordingWriter?
    private var capture: [String: Any]?
    private var jobs: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var tail: Task<Any, Error>?
    private var timer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var modelError: [String: String] = [:]
    private var requestedModel: LocalSpeechModel?
    private var lastModelSnapshot = ""

    init(root: URL, invoke: @escaping Invoke) {
        self.invoke = invoke
        models = SpeechModelStore(root: root)
        models.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.publishModels() } }.store(in: &subscriptions)
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if type == AVAudioSession.InterruptionType.began.rawValue { Task { @MainActor in await self?.interruptForLifecycle() } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                self.emit("runtime:recordingDevicesChanged", [:])
                if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { await self.interruptForLifecycle() }
            }
        })
    }
    deinit { timer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver); jobs.values.forEach { $0.cancel() } }

    func canHandle(_ channel: String) -> Bool {
        ["recordings:create", "recordings:control", "recordings:append", "recordings:models", "recordings:downloadModel", "recordings:cancelDownload", "runtime:recordingStart", "runtime:recordingDevices", "runtime:recordingAbandon"].contains(channel)
    }
    func handle(channel: String, request: [String: Any]) async throws -> Any {
        switch channel {
        case "recordings:models": return modelStates()
        case "recordings:downloadModel":
            let model = try localModel(request["modelId"])
            guard models.downloading == nil || models.downloading == model else { throw DesktopRuntimeError("다른 모델을 내려받는 중입니다.") }
            requestedModel = model; modelError[model.rawValue] = nil; models.install(model); publishModels(); return ["ok": true]
        case "recordings:cancelDownload":
            if models.downloading?.rawValue == request["modelId"] as? String { models.cancel() }; return ["ok": true]
        case "runtime:recordingDevices":
            var devices: [[String: String]] = [["deviceId": "default", "kind": "audioinput", "groupId": "", "label": "시스템 기본 마이크"]]
            for input in AVAudioSession.sharedInstance().availableInputs ?? [] { devices.append(["deviceId": input.uid, "kind": "audioinput", "groupId": input.uid, "label": input.portName]) }
            return devices
        default:
            return try await serial { [self] in
                switch channel {
                case "recordings:create":
                    _ = try localModel(request["modelId"])
                    return try await invoke("nativeRecording:create", request)
                case "recordings:append":
                    guard capture?["id"] as? String != request["id"] as? String else { throw DesktopRuntimeError("기기 녹음에 외부 음성 조각을 추가할 수 없습니다.") }
                    return try await invoke("nativeRecording:append", request)
                case "runtime:recordingAbandon":
                    if let id = capture?["id"] as? String { _ = try await finish(id: id, status: "interrupted") }; return ["ok": true]
                case "runtime:recordingStart": return try await start(id: requiredID(request), deviceID: request["deviceId"] as? String ?? "default")
                case "recordings:control":
                    let id = try requiredID(request)
                    switch request["action"] as? String {
                    case "start": return try await start(id: id, deviceID: request["deviceId"] as? String ?? "default")
                    case "pause": return try await finish(id: id, status: "paused")
                    case "stop": return try await finish(id: id, status: "processing")
                    case "interrupt": return try await finish(id: id, status: "interrupted")
                    case "retry": return try await retry(id: id, requested: request["modelId"])
                    default: throw DesktopRuntimeError("녹음 동작을 확인할 수 없습니다.")
                    }
                default: throw DesktopRuntimeError("지원하지 않는 녹음 요청입니다.")
                }
            }
        }
    }
    private func serial(_ operation: @escaping @MainActor () async throws -> Any) async throws -> Any {
        let previous = tail
        let task = Task { @MainActor in _ = try? await previous?.value; return try await operation() }
        tail = task
        return try await task.value
    }
    private func requiredID(_ request: [String: Any]) throws -> String {
        guard let id = request["id"] as? String, !id.isEmpty else { throw DesktopRuntimeError("녹음 ID가 없습니다.") }; return id
    }
    private func localModel(_ value: Any?) throws -> LocalSpeechModel {
        guard let string = value as? String, let model = LocalSpeechModel(rawValue: string) else { throw DesktopRuntimeError("iPad에서는 한국어 Zipformer 또는 다국어 SenseVoice 모델을 선택해 주세요.") }; return model
    }
    private func session(_ id: String) async throws -> [String: Any] {
        guard let result = try await invoke("nativeRecording:get", ["id": id]) as? [String: Any] else { throw DesktopRuntimeError("녹음을 찾을 수 없습니다.") }; return result
    }
    private func audioURL(_ id: String) async throws -> URL {
        guard let path = try await invoke("nativeRecording:audioPath", ["id": id]) as? String else { throw RecordingError.invalidAudio }; return URL(fileURLWithPath: path)
    }
    private func publish(_ session: [String: Any], segment: Any? = nil, rtf: Double? = nil, cooling: Bool = false) {
        emit("recordings:event", ["session": session, "partial": NSNull(), "segment": segment ?? NSNull(), "rtf": rtf as Any? ?? NSNull(), "cooling": cooling])
    }
    private func start(id: String, deviceID: String) async throws -> Any {
        if let active = capture, active["id"] as? String != id { throw DesktopRuntimeError("이미 다른 녹음이 진행 중입니다.") }
        if capture?["status"] as? String == "recording" { return capture! }
        var record = try await session(id)
        guard ["ready", "paused", "interrupted"].contains(record["status"] as? String ?? "") else { throw DesktopRuntimeError("이 녹음은 다시 시작할 수 없습니다.") }
        _ = try localModel(record["modelId"])
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw RecordingError.microphone }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audio.setPreferredSampleRate(16000); try audio.setActive(true)
        var didStart = false
        defer { if !didStart { try? audio.setActive(false, options: .notifyOthersOnDeactivation) } }
        if deviceID != "default" {
            guard let input = audio.availableInputs?.first(where: { $0.uid == deviceID }) else { throw DesktopRuntimeError("선택한 마이크 연결을 확인해 주세요.") }
            try audio.setPreferredInput(input)
        } else { try audio.setPreferredInput(nil) }
        let url = try await audioURL(id)
        let inputEngine = AVAudioEngine()
        let input = inputEngine.inputNode, format = inputEngine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw RecordingError.microphone }
        let output = try PCMRecordingWriter(url: url, resuming: true, encoding: .signed16)
        output.onError = { [weak self] message in Task { @MainActor in await self?.captureFailed(message) } }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in output.append(buffer) }
        record = try await commitCaptureStart(record, output: output, startEngine: {
            inputEngine.prepare(); try inputEngine.start()
        }, stopEngine: {
            input.removeTap(onBus: 0); inputEngine.stop()
        })
        engine = inputEngine; writer = output; capture = record
        didStart = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self else { return }
            do { _ = try await self.serial { try await self.checkpoint(); return NSNull() } }
            catch { await self.captureFailed(error.localizedDescription) }
        } }
        publish(record); beginTranscription(id: id); return record
    }
    /// Called inside the serialized capture operation. Persist the intent before
    /// the engine can write, then durably recover both WAV and status on failure.
    /// Engine closures keep this boundary testable without requesting a microphone.
    func commitCaptureStart(_ original: [String: Any], output: PCMRecordingWriter,
                            startEngine: () throws -> Void, stopEngine: () -> Void) async throws -> [String: Any] {
        let id = try requiredID(original)
        var record = original
        record["status"] = "recording"; record["error"] = NSNull(); record["samples"] = output.samples
        do {
            _ = try await invoke("nativeRecording:save", ["session": record])
            try startEngine()
            return record
        } catch {
            let startError = error
            stopEngine()
            var message = startError.localizedDescription
            do { try output.closeOrThrow() }
            catch { message += "\n원음 파일 저장 확인 실패: \(error.localizedDescription)" }
            do {
                // Reread so transcript/checkpoint fields are never replaced by
                // the snapshot captured before starting the engine.
                var recovered = try await session(id)
                recovered["status"] = "interrupted"; recovered["error"] = message
                recovered["samples"] = output.samples
                _ = try await invoke("nativeRecording:save", ["session": recovered])
                publish(recovered)
            } catch {
                throw DesktopRuntimeError("녹음을 시작하지 못했습니다: \(message)\n복구 상태를 저장하지 못했습니다: \(error.localizedDescription)")
            }
            throw startError
        }
    }
    private func checkpoint() async throws {
        guard let writer, var record = capture, record["status"] as? String == "recording", let id = record["id"] as? String else { return }
        try writer.synchronizeOrThrow()
        // Read the repository again so a completed transcript job is retained.
        record = try await session(id); record["samples"] = writer.samples; record["status"] = "recording"
        _ = try await invoke("nativeRecording:save", ["session": record]); capture = record
        publish(record); emit("runtime:recordingLevel", ["id": id, "level": writer.level])
        if writer.samples >= 24 * 60 * 60 * 16000 { _ = try await finish(id: id, status: "processing") }
    }
    private func finish(id: String, status: String) async throws -> Any {
        var record = try await session(id)
        if capture?["id"] as? String == id {
            timer?.invalidate(); timer = nil
            engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
            let output = writer; writer = nil
            do { try output?.closeOrThrow() }
            catch { record["error"] = error.localizedDescription; record["status"] = "interrupted"; record["samples"] = output?.samples ?? 0; capture = nil; _ = try await invoke("nativeRecording:save", ["session": record]); publish(record); throw error }
            record["samples"] = output?.samples ?? (record["samples"] as? NSNumber)?.uint64Value ?? 0
            capture = nil; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } else if record["status"] as? String == "recording" { throw DesktopRuntimeError("현재 녹음 소유권을 확인할 수 없습니다.") }
        record["status"] = status
        _ = try await invoke("nativeRecording:save", ["session": record]); publish(record)
        if status == "paused" { capture = record; beginTranscription(id: id) }
        else if status == "processing" { beginTranscription(id: id) }
        else { generations[id] = UUID(); jobs.removeValue(forKey: id)?.cancel() }
        return record
    }
    private func captureFailed(_ message: String) async {
        _ = try? await serial { [self] in
            guard let id = capture?["id"] as? String else { return NSNull() }
            _ = try await finish(id: id, status: "interrupted")
            var record = try await session(id); record["error"] = message
            _ = try await invoke("nativeRecording:save", ["session": record]); publish(record); return NSNull()
        }
    }
    func interruptForLifecycle() async {
        _ = try? await serial { [self] in
            guard let id = capture?["id"] as? String else { return NSNull() }
            return try await finish(id: id, status: "interrupted")
        }
    }
    private func beginTranscription(id: String) {
        guard jobs[id] == nil else { return }
        let generation = UUID(); generations[id] = generation
        self.jobs[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let first = try await self.session(id), model = try self.localModel(first["modelId"])
                try await self.speech.prepare(model: model, directory: self.models.directory(model))
                let url = try await self.audioURL(id)
                while !Task.isCancelled && self.generations[id] == generation {
                    let record = try await self.session(id)
                    let start = (record["transcribedSamples"] as? NSNumber)?.intValue ?? 0
                    let end = (record["samples"] as? NSNumber)?.intValue ?? 0
                    let recording = record["status"] as? String == "recording"
                    if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
                        self.publish(record, cooling: true); try await Task.sleep(for: .seconds(5)); continue
                    }
                    if end <= start || (recording && end - start < 12 * 16000) {
                        if !recording { break }; try await Task.sleep(for: .seconds(2)); continue
                    }
                    let count = min(18 * 16000, end - start), began = Date()
                    let text = try await self.speech.transcribe(model: model, directory: self.models.directory(model), url: url, start: Double(start) / 16000, duration: Double(count) / 16000)
                    try Task.checkCancellation()
                    _ = try await serial { [self] in
                        guard self.generations[id] == generation else { return NSNull() }
                        let committed = try await self.invoke("nativeRecording:commitTranscriptWindow", ["id": id, "startSample": start, "endSample": start + count, "text": text])
                        guard let result = committed as? [String: Any], let latest = result["session"] as? [String: Any] else { throw DesktopRuntimeError("전사 저장 응답을 확인하지 못했습니다.") }
                        self.publish(latest, segment: result["segment"], rtf: Date().timeIntervalSince(began) / (Double(count) / 16000)); return NSNull()
                    }
                }
                if !Task.isCancelled { _ = try await serial { [self] in
                    guard self.generations[id] == generation else { return NSNull() }
                    var record = try await self.session(id)
                    if record["status"] as? String == "processing" { record["status"] = "complete"; _ = try await self.invoke("nativeRecording:save", ["session": record]); self.publish(record) }
                    return NSNull()
                } }
            } catch is CancellationError { }
            catch { _ = try? await serial { [self] in
                guard self.generations[id] == generation else { return NSNull() }
                var record = try await self.session(id); record["error"] = error.localizedDescription
                if record["status"] as? String == "processing" { record["status"] = "interrupted" }
                _ = try await self.invoke("nativeRecording:save", ["session": record]); self.publish(record); return NSNull()
            } }
            if self.generations[id] == generation { self.jobs[id] = nil }
        }
    }
    private func retry(id: String, requested: Any?) async throws -> Any {
        guard capture?["id"] as? String != id, self.jobs[id] == nil else { throw DesktopRuntimeError("녹음 또는 전사가 끝난 뒤 재전사해 주세요.") }
        var record = try await self.session(id)
        let model = try self.localModel(requested ?? record["modelId"])
        guard self.models.installed.contains(model) else { throw RecordingError.modelMissing }
        record["status"] = "processing"; record["error"] = NSNull()
        _ = try await self.invoke("nativeRecording:save", ["session": record]); self.publish(record)
        let generation = UUID(); self.generations[id] = generation
        let samples = (record["samples"] as? NSNumber)?.intValue ?? 0
        self.jobs[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.speech.prepare(model: model, directory: self.models.directory(model))
                let url = try await self.audioURL(id)
                var segments: [[String: Any]] = []
                var offset = 0
                while offset < samples {
                    try Task.checkCancellation()
                    if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { try await Task.sleep(for: .seconds(5)); continue }
                    let count = min(18 * 16000, samples - offset)
                    let text = try await self.speech.transcribe(model: model, directory: self.models.directory(model), url: url, start: Double(offset) / 16000, duration: Double(count) / 16000)
                    if !text.isEmpty { segments.append(["startSample": offset, "endSample": offset + count, "text": text]) }
                    offset += count
                }
                try Task.checkCancellation()
                _ = try await serial { [self] in
                    guard self.generations[id] == generation else { return NSNull() }
                    _ = try await self.invoke("nativeRecording:replaceTranscript", ["id": id, "modelId": model.rawValue, "segments": segments, "transcribedSamples": samples])
                    self.publish(try await self.session(id)); return NSNull()
                }
            } catch { _ = try? await serial { [self] in
                var latest = try await self.session(id); latest["status"] = "interrupted"; latest["error"] = error.localizedDescription
                _ = try await self.invoke("nativeRecording:save", ["session": latest]); self.publish(latest); return NSNull()
            } }
            if self.generations[id] == generation { self.jobs[id] = nil }
        }
        return record
    }
    private func modelStates() -> [[String: Any]] {
        LocalSpeechModel.allCases.map { model in
            let total = model.files.reduce(Int64(0)) { $0 + $1.size }
            let downloaded = model.files.reduce(Int64(0)) { sum, file in
                let attrs = try? FileManager.default.attributesOfItem(atPath: models.directory(model).appendingPathComponent(file.name).path)
                return sum + min(file.size, (attrs?[.size] as? NSNumber)?.int64Value ?? 0)
            }
            let status = models.downloading == model ? "downloading" : models.installed.contains(model) ? "installed" : modelError[model.rawValue] == nil ? "available" : "error"
            return ["id": model.rawValue, "name": model.title, "description": model == .zipformer ? "한국어 · 기기 내 실시간 전사" : "한국어·영어·일본어·중국어 · 기기 내 전사", "bytes": total, "downloadedBytes": downloaded, "status": status, "error": modelError[model.rawValue] as Any? ?? NSNull(), "unavailableReason": LocalSpeechEngine.available ? NSNull() : RecordingError.runtimeUnavailable.localizedDescription]
        }
    }
    private func publishModels() {
        if models.downloading == nil, let requestedModel {
            if let error = models.error { modelError[requestedModel.rawValue] = error }; self.requestedModel = nil
        }
        let states = modelStates()
        let snapshot = (try? JSONSerialization.data(withJSONObject: states, options: .sortedKeys)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if snapshot != lastModelSnapshot { lastModelSnapshot = snapshot; emit("recordings:modelsChanged", states) }
    }
}
