import Foundation
import AVFoundation

/// Ownership is transferred to the writer queue before the conversion begins.
private final class RecordingConversionInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    private var supplied = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true; status.pointee = .haveData; return buffer
    }
}

/// Audio capture only queues copies here. Disk IO and conversion never run on
/// the realtime audio thread, and speech inference never blocks this queue.
final class PCMRecordingWriter: @unchecked Sendable {
    enum Encoding { case float32, signed16
        var bytes: UInt64 { self == .float32 ? 4 : 2 }
    }
    private let encoding: Encoding
    private var peakLevel: Float = 0
    private var failureMessage: String?
    private let queue = DispatchQueue(label: "app.bandal.recording.writer", qos: .userInitiated)
    private let lock = NSLock()
    private var sampleCount: UInt64 = 0
    private var lastCheckpoint: UInt64 = 0
    private var file: FileHandle?
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var failed = false
    var onError: (@Sendable (String) -> Void)?

    init(url: URL, resuming: Bool = false, encoding: Encoding = .float32) throws {
        self.encoding = encoding
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if resuming {
            sampleCount = try Self.repair(url: url, encoding: encoding)
        } else {
            try Self.header(samples: 0, encoding: encoding).write(to: url, options: .atomic)
        }
        file = try FileHandle(forUpdating: url)
        try file?.seekToEnd()
    }

    var duration: TimeInterval { lock.lock(); defer { lock.unlock() }; return Double(sampleCount) / 16000 }

    var samples: UInt64 { lock.lock(); defer { lock.unlock() }; return sampleCount }
    var level: Float { lock.lock(); defer { lock.unlock() }; return peakLevel }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (a, b) in zip(source, destination) {
            if let from = a.mData, let to = b.mData { memcpy(to, from, Int(a.mDataByteSize)) }
        }
        let input = RecordingConversionInput(copy)
        queue.async { [self] in
            guard !failed, let file else { return }
            autoreleasepool {
                do {
                    let copy = input.buffer
                    if converter?.inputFormat != copy.format {
                        try drainConverter()
                        converter = AVAudioConverter(from: copy.format, to: outputFormat)
                    }
                    guard let converter,
                          let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                            frameCapacity: AVAudioFrameCount(ceil(Double(copy.frameLength) * 16000 / copy.format.sampleRate)) + 128)
                    else { throw RecordingError.conversion }
                    var error: NSError?
                    converter.convert(to: output, error: &error) { _, status in input.take(status) }
                    if let error { throw error }
                    try write(output, to: file)
                    if sampleCount - lastCheckpoint >= 16000 { try checkpoint(); lastCheckpoint = sampleCount }
                } catch {
                    failed = true; failureMessage = error.localizedDescription
                    onError?(error.localizedDescription)
                }
            }
        }
    }

    func synchronizeOrThrow() throws { try queue.sync {
        if let failureMessage { throw NSError(domain: "BandalAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: failureMessage]) }
        try checkpoint()
    } }
    func synchronize() { do { try synchronizeOrThrow() } catch { onError?(error.localizedDescription) } }
    func closeOrThrow() throws {
        try queue.sync {
            defer { try? file?.close(); file = nil }
            if let failureMessage { throw NSError(domain: "BandalAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: failureMessage]) }
            try drainConverter(); try checkpoint()
        }
    }
    func close() { do { try closeOrThrow() } catch { onError?(error.localizedDescription) } }
    private func write(_ buffer: AVAudioPCMBuffer, to file: FileHandle) throws {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        var rms: Float = 0
        for index in 0..<count { rms += samples[index] * samples[index] }
        let bytes: Data
        if encoding == .float32 { bytes = Data(bytes: samples, count: count * 4) }
        else {
            var values = [Int16](repeating: 0, count: count)
            for index in 0..<count {
                let value = samples[index].isFinite ? min(1, max(-1, samples[index])) : 0
                values[index] = Int16(clamping: Int((value * (value < 0 ? 32768 : 32767)).rounded())).littleEndian
            }
            bytes = values.withUnsafeBytes { Data($0) }
        }
        guard sampleCount * encoding.bytes + UInt64(bytes.count) < UInt64(UInt32.max) - 36 else { throw RecordingError.fileTooLarge }
        try file.write(contentsOf: bytes)
        lock.lock(); sampleCount += UInt64(buffer.frameLength); peakLevel = min(1, sqrt(rms / Float(max(1, count))) * 3); lock.unlock()
    }
    private func drainConverter() throws {
        guard let converter, let file else { return }
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { throw RecordingError.conversion }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream; return nil
            }
            if let error { throw error }
            try write(output, to: file)
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        self.converter = nil
    }
    private func checkpoint() throws {
        guard let file else { return }
        try file.seek(toOffset: 0); try file.write(contentsOf: Self.header(samples: sampleCount, encoding: encoding))
        try file.seekToEnd(); try file.synchronize()
    }

    /// Rebuilds the WAV length from committed PCM bytes after process termination.
    @discardableResult
    static func repair(url: URL, encoding: Encoding = .float32) throws -> UInt64 {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 44 else { throw RecordingError.invalidAudio }
        try handle.seek(toOffset: 0)
        guard let prefix = try handle.read(upToCount: 44), prefix.count == 44,
              prefix.prefix(4) == Data("RIFF".utf8), prefix[8..<12] == Data("WAVE".utf8),
              prefix[20] == (encoding == .float32 ? 3 : 1), prefix[22] == 1, prefix[34] == UInt8(encoding.bytes * 8) else { throw RecordingError.invalidAudio }
        let samples = (size - 44) / encoding.bytes
        try handle.truncate(atOffset: 44 + samples * encoding.bytes)
        try handle.seek(toOffset: 0); try handle.write(contentsOf: header(samples: samples, encoding: encoding)); try handle.synchronize()
        return samples
    }
    static func header(samples: UInt64, encoding: Encoding = .float32) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        let bytes = UInt32(clamping: samples * encoding.bytes)
        text("RIFF"); u32(36 &+ bytes); text("WAVE"); text("fmt "); u32(16)
        u16(encoding == .float32 ? 3 : 1); u16(1); u32(16000); u32(UInt32(16000 * encoding.bytes)); u16(UInt16(encoding.bytes)); u16(UInt16(encoding.bytes * 8))
        text("data"); u32(bytes)
        return data
    }
}

enum RecordingError: LocalizedError {
    case microphone, conversion, invalidAudio, fileTooLarge, runtimeUnavailable, modelMissing, modelInitialization
    var errorDescription: String? {
        switch self {
        case .microphone: "마이크 접근을 허용해야 녹음할 수 있습니다. 설정 앱에서 반달의 마이크 권한을 확인해 주세요."
        case .conversion: "오디오 입력 형식을 변환하지 못했습니다."
        case .invalidAudio: "복구할 수 있는 오디오 데이터가 없습니다."
        case .fileTooLarge: "녹음 파일의 최대 크기에 도달했습니다. 새 녹음을 시작해 주세요."
        case .runtimeUnavailable: "이 앱 빌드에 기기 내 음성 인식 엔진이 포함되지 않았습니다. 녹음은 계속 사용할 수 있습니다."
        case .modelMissing: "선택한 음성 인식 모델을 먼저 내려받아 주세요."
        case .modelInitialization: "기기 내 음성 인식을 시작하지 못했습니다. 메모리를 확보한 뒤 다시 시도해 주세요. 원음은 보존됩니다."
        }
    }
}
