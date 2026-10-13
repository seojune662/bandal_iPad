import Foundation

/// Runs against public fixture files, without microphone permission or capture.
@main
struct NativeSpeechFixture {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "SpeechFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass a Zipformer directory containing the pinned models, tokens.txt and official test_wavs/0.wav saved as 0.wav."])
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let engine = LocalSpeechEngine()
        try await engine.prepare(model: .zipformer, directory: directory)
        let first = try await engine.transcribe(url: directory.appendingPathComponent("0.wav"), start: 0, duration: 15)
        let second = try await engine.transcribe(url: directory.appendingPathComponent("0.wav"), start: 0, duration: 15)
        guard !first.isEmpty, first == second,
              first.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) else {
            throw NSError(domain: "SpeechFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native Korean recognition must produce the same nonempty transcript for independent repeated inputs."])
        }
        print("Native Zipformer checksum verification and two independent inference runs passed.")
        print(first)
    }
}
