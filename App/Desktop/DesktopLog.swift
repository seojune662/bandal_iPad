import Foundation
import os

/// Launch and PDF-open phases as os_signpost intervals (Instruments) plus a log line.
enum DesktopSignpost {
    static let launch = OSSignposter(subsystem: "app.bandal", category: "launch")
    static let open = OSSignposter(subsystem: "app.bandal", category: "pdf-open")
    static func measure<T>(_ poster: OSSignposter, _ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = poster.beginInterval(name); defer { poster.endInterval(name, state) }
        return try await body()
    }
}

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
    /// Revalidate the already-redacted renderer envelope. No raw error message,
    /// stack, document path, function label or URL is accepted by this boundary.
    func recordRendererDiagnostic(_ payload: [String: Any]) {
        let classes: Set<String> = ["Error", "TypeError", "RangeError", "ReferenceError", "SyntaxError", "EvalError", "URIError", "AggregateError", "DOMException", "UnknownError"]
        let name = payload["errorClass"] as? String ?? "UnknownError"
        record("renderer.error", code: classes.contains(name) ? name : "UnknownError")
        if name == "TypeError", let expression = payload["expression"] as? String, expression.count <= 64,
           expression.range(of: "^[A-Za-z_$][A-Za-z0-9_$]*(\\.[A-Za-z_$][A-Za-z0-9_$]*){1,3}$", options: .regularExpression) != nil {
            record("renderer.expression", code: expression)
        }
        for (index, frame) in (payload["frames"] as? [String] ?? []).prefix(5).enumerated() {
            guard frame.utf8.count <= 112,
                  frame.range(of: "^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,79}\\.(js|mjs):[1-9][0-9]{0,8}:[1-9][0-9]{0,8}$", options: .regularExpression) != nil else { continue }
            record("renderer.frame", channel: String(index), code: frame)
        }
    }
    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
