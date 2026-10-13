import Foundation

/// Operational diagnostics only. Request bodies, URLs, file paths, messages
/// and credentials never enter this log; desktop export adds its own redaction.
final class DesktopLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.bandal.desktop-log", qos: .utility)
    private let directory: URL
    private let limit: Int
    init(root: URL, limit: Int = 1024 * 1024) {
        directory = root.appendingPathComponent("Logs", isDirectory: true)
        self.limit = limit
    }
    func record(_ event: String, channel: String? = nil, code: String? = nil) {
        let safe: (String) -> String = { String($0.prefix(128)).replacingOccurrences(of: "[^a-zA-Z0-9_.:-]", with: "_", options: .regularExpression) }
        let components = [safe(event), channel.map { "channel=" + safe($0) }, code.map { "code=" + safe($0) }].compactMap { $0 }
        let bytes = Data((ISO8601DateFormatter().string(from: Date()) + " " + components.joined(separator: " ") + "\n").utf8)
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let current = directory.appendingPathComponent("bandal.log")
                let old = directory.appendingPathComponent("bandal.previous.log")
                let count = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if count + bytes.count > limit {
                    if FileManager.default.fileExists(atPath: old.path) { try FileManager.default.removeItem(at: old) }
                    if FileManager.default.fileExists(atPath: current.path) { try FileManager.default.moveItem(at: current, to: old) }
                }
                if !FileManager.default.fileExists(atPath: current.path) { try bytes.write(to: current, options: .atomic); return }
                let handle = try FileHandle(forWritingTo: current)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: bytes)
            } catch { NSLog("[Desktop diagnostics] write failed (%ld)", (error as NSError).code) }
        }
    }
    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
