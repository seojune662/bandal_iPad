import XCTest
import AVFoundation
@testable import Bandal

final class PCMRecordingWriterTests: XCTestCase {
    func testResamplingAndFinalDrainPreserveOneSecondOfAudio() throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let writer = try PCMRecordingWriter(url: url)
        try writeTone(to: writer, chunks: 10)
        writer.close()
        let audio = try AVAudioFile(forReading: url)
        XCTAssertEqual(audio.processingFormat.sampleRate, 16000)
        XCTAssertEqual(audio.processingFormat.channelCount, 1)
        XCTAssertEqual(audio.length, 16000)
        XCTAssertEqual(writer.duration, 1, accuracy: 0.0001)
    }

    func testPartialTailRecoveryAndResume() throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let writer = try PCMRecordingWriter(url: url)
        try writeTone(to: writer, chunks: 10); writer.close()
        let handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0xff, 0xff])); try handle.close()
        XCTAssertEqual(try PCMRecordingWriter.repair(url: url), 16000)
        let resumed = try PCMRecordingWriter(url: url, resuming: true)
        try writeTone(to: resumed, chunks: 5); resumed.close()
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 24000)
    }

    func testInvalidRecordingIsRejectedWithoutRewritingIt() throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data(repeating: 7, count: 80)
        try bytes.write(to: url)
        XCTAssertThrowsError(try PCMRecordingWriter.repair(url: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    private func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("audio-test-\(UUID().uuidString).wav") }
    private func writeTone(to writer: PCMRecordingWriter, chunks: Int) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        for _ in 0..<chunks {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            buffer.frameLength = 4800
            for index in 0..<4800 { buffer.floatChannelData![0][index] = 0.1 * sin(Float(index) * 2 * .pi * 440 / 48000) }
            writer.append(buffer)
        }
    }
}
