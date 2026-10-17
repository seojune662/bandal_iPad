import Foundation

/// A stable, bounded-memory snapshot for QuickLook, Share and Files.
/// The validated descriptor detects changes during copying.
enum DesktopMaterialExport {
    static func snapshot(path: String, root: URL) async throws -> URL {
        let task = Task.detached(priority: .userInitiated) {
            let input = try DesktopMaterialFile(path: path, root: root)
            let name = URL(fileURLWithPath: path).lastPathComponent
            let folder = root.appendingPathComponent("Temporary/Exports/\(UUID().uuidString)", isDirectory: true)
            let target = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw DesktopRuntimeError("공유할 사본을 만들지 못했습니다.") }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                var offset: UInt64 = 0
                while offset < UInt64(input.size) {
                    try Task.checkCancellation()
                    let chunk = try input.read(offset: offset, count: Int(min(256 * 1024, UInt64(input.size) - offset)))
                    guard !chunk.isEmpty else { throw DesktopRuntimeError("자료 사본 만들기가 중단되었습니다.") }
                    try output.write(contentsOf: chunk); offset += UInt64(chunk.count)
                }
                // Validate empty files too, and edits racing the final chunk.
                _ = try input.read(offset: offset, count: 0)
                try output.synchronize()
                try Task.checkCancellation()
                return target
            } catch { try? FileManager.default.removeItem(at: folder); throw error }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
