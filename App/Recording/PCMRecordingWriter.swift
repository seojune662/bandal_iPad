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
    private let queue = DispatchQueue(label: "app.bandal.recording.writer", qos: .userInitiated)
    private let lock = NSLock()
    private var sampleCount: UInt64 = 0
    private var lastCheckpoint: UInt64 = 0
    private var file: FileHandle?
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var failed = false
    var onError: (@Sendable (String) -> Void)?

    init(url: URL, resuming: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if resuming {
            sampleCount = try Self.repair(url: url)
        } else {
            try Self.header(samples: 0).write(to: url, options: .atomic)
        }
        file = try FileHandle(forUpdating: url)
        try file?.seekToEnd()
    }

    var duration: TimeInterval { lock.lock(); defer { lock.unlock() }; return Double(sampleCount) / 16000 }

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
                    failed = true
                    onError?(error.localizedDescription)
                }
            }
        }
    }

    func synchronize() { queue.sync { try? checkpoint() } }
    func close() {
        queue.sync {
            do { try drainConverter(); try checkpoint(); try file?.close(); file = nil }
            catch { onError?(error.localizedDescription) }
        }
    }
    private func write(_ buffer: AVAudioPCMBuffer, to file: FileHandle) throws {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let bytes = Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
        guard sampleCount * 4 + UInt64(bytes.count) < UInt64(UInt32.max) - 36 else { throw RecordingError.fileTooLarge }
        try file.write(contentsOf: bytes)
        lock.lock(); sampleCount += UInt64(buffer.frameLength); lock.unlock()
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
        try file.seek(toOffset: 0); try file.write(contentsOf: Self.header(samples: sampleCount))
        try file.seekToEnd(); try file.synchronize()
    }

    /// Rebuilds the WAV length from committed PCM bytes after process termination.
    @discardableResult
    static func repair(url: URL) throws -> UInt64 {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 44 else { throw RecordingError.invalidAudio }
        try handle.seek(toOffset: 0)
        guard let prefix = try handle.read(upToCount: 44), prefix.count == 44,
              prefix.prefix(4) == Data("RIFF".utf8), prefix[8..<12] == Data("WAVE".utf8),
              prefix[20] == 3, prefix[22] == 1, prefix[34] == 32 else { throw RecordingError.invalidAudio }
        let samples = (size - 44) / 4
        try handle.truncate(atOffset: 44 + samples * 4)
        try handle.seek(toOffset: 0); try handle.write(contentsOf: header(samples: samples)); try handle.synchronize()
        return samples
    }
    static func header(samples: UInt64) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        let bytes = UInt32(clamping: samples * 4)
        text("RIFF"); u32(36 &+ bytes); text("WAVE"); text("fmt "); u32(16)
        u16(3); u16(1); u32(16000); u32(64000); u16(4); u16(32)
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
