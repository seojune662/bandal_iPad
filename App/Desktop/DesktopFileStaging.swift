import Darwin
import Foundation

/// Owns only files created for this process's import operations. Sources and
/// course assets are never candidates for cleanup. Consumers pin files across
/// asynchronous repository calls, including cancellation of an old selection.
@MainActor
final class DesktopFileStaging {
    static let chunkBytes = 256 * 1024
    private static var instances: [String: DesktopFileStaging] = [:]
    static func shared(root: URL) -> DesktopFileStaging {
        let key = root.standardizedFileURL.path
        if let value = instances[key] { return value }
        let value = DesktopFileStaging(root: root); instances[key] = value; return value
    }
    private final class Entry {
        let id: String, url: URL, expected: Int64, device: dev_t, inode: ino_t
        var handle: FileHandle?, written: Int64 = 0, ready = false, users = 0, discard = false
        init(id: String, url: URL, expected: Int64, handle: FileHandle) throws {
            var metadata = Darwin.stat()
            guard fstat(handle.fileDescriptor, &metadata) == 0 else { throw POSIXError(.EIO) }
            self.id = id; self.url = url; self.expected = expected; self.handle = handle
            device = metadata.st_dev; inode = metadata.st_ino
        }
    }
    private let directory: URL
    private var entries: [String: Entry] = [:]
    private let writeChunk: (FileHandle, Data) throws -> Void
    init(root: URL, writeChunk: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) {
        directory = root.appendingPathComponent("Temporary/Imports", isDirectory: true)
        self.writeChunk = writeChunk
    }
    func handle(_ channel: String, _ request: [String: Any]) throws -> Any {
        if channel == "runtime:stageFileBegin" {
            guard let name = request["name"] as? String, let size = request["size"] as? NSNumber,
                  size.doubleValue.isFinite, size.doubleValue >= 0, size.doubleValue <= Double(16 * 1024 * 1024 * 1024 as Int64),
                  Double(size.int64Value) == size.doubleValue else { throw DesktopRuntimeError("가져올 파일 크기를 확인해 주세요.") }
            return ["id": try begin(name: name, size: size.int64Value)]
        }
        guard let id = request["id"] as? String else { throw DesktopRuntimeError("파일 가져오기 작업을 확인해 주세요.") }
        if channel == "runtime:stageFileCancel" { cancel(id); return ["ok": true] }
        guard let entry = entries[id], !entry.ready else { throw DesktopRuntimeError("파일 가져오기 작업이 종료되었습니다.") }
        do {
            if channel == "runtime:stageFileWrite" {
                guard let offset = request["offset"] as? NSNumber, offset.doubleValue == Double(entry.written),
                      let encoded = request["data"] as? String, encoded.utf8.count <= ((Self.chunkBytes + 2) / 3) * 4,
                      let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= Self.chunkBytes,
                      entry.written <= entry.expected - Int64(data.count), let handle = entry.handle else { throw DesktopRuntimeError("파일 조각의 크기 또는 순서가 올바르지 않습니다.") }
                try writeChunk(handle, data); entry.written += Int64(data.count)
                return ["offset": entry.written]
            }
            guard channel == "runtime:stageFileFinish", entry.written == entry.expected, let handle = entry.handle else { throw DesktopRuntimeError("파일 전송이 끝나지 않았습니다.") }
            try handle.synchronize()
            var metadata = Darwin.stat()
            guard fstat(handle.fileDescriptor, &metadata) == 0, metadata.st_size == entry.expected else { throw DesktopRuntimeError("저장된 파일 길이가 올바르지 않습니다.") }
            try handle.close(); entry.handle = nil; entry.ready = true
            return ["path": entry.url.path]
        } catch { cancel(id); throw error }
    }
    private func begin(name: String, size: Int64) throws -> String {
        guard entries.values.filter({ !$0.ready }).count < 8 else { throw DesktopRuntimeError("진행 중인 파일 가져오기가 끝난 뒤 다시 시도해 주세요.") }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.utf8.contains(0) else { throw DesktopRuntimeError("파일 이름을 확인해 주세요.") }
        let id = UUID().uuidString, folder = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: folder); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { entries[id] = try Entry(id: id, url: url, expected: size, handle: handle); return id }
        catch { try? handle.close(); try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: folder); throw error }
    }
    /// Copies OS picker/download files directly on disk, without a JS bridge.
    func copy(_ source: URL) throws -> URL {
        let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true, let size = properties.fileSize else { throw DesktopRuntimeError("가져올 파일을 확인해 주세요.") }
        let id = try begin(name: source.lastPathComponent, size: Int64(size)), entry = entries[id]!
        do {
            let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
            while let bytes = try input.read(upToCount: Self.chunkBytes), !bytes.isEmpty {
                guard entry.written <= entry.expected - Int64(bytes.count), let output = entry.handle else { throw DesktopRuntimeError("복사 중 파일 크기가 변경되었습니다.") }
                try writeChunk(output, bytes); entry.written += Int64(bytes.count)
            }
            _ = try handle("runtime:stageFileFinish", ["id": id]); return entry.url
        } catch { cancel(id); throw error }
    }
    func cancel(_ id: String) {
        guard let entry = entries[id] else { return }
        entry.discard = true
        if entry.users == 0 { remove(entry) }
    }
    /// A terminated renderer cannot continue its incomplete upload. Completed
    /// files may still be referenced by a chat draft, so they remain untouched.
    func cancelUnfinished() { for entry in Array(entries.values) where !entry.ready { cancel(entry.id) } }
    func discard(paths: [String]) {
        for entry in entries.values where paths.contains(entry.url.path) { cancel(entry.id) }
    }
    func beginConsumption(paths: [String]) -> [String] {
        let pinned = entries.values.filter { $0.ready && !$0.discard && paths.contains($0.url.path) }
        for entry in pinned { entry.users += 1 }
        return pinned.map(\.id)
    }
    func endConsumption(_ lease: [String], successfulPaths: [String]) {
        for id in lease {
            guard let entry = entries[id] else { continue }
            entry.users = max(0, entry.users - 1)
            if successfulPaths.contains(entry.url.path) { entry.discard = true }
            if entry.discard && entry.users == 0 { remove(entry) }
        }
    }
    private func remove(_ entry: Entry) {
        try? entry.handle?.close(); entry.handle = nil
        // If another actor replaced the temporary path, it is no longer ours.
        var metadata = Darwin.stat()
        if lstat(entry.url.path, &metadata) == 0, metadata.st_dev == entry.device, metadata.st_ino == entry.inode {
            try? FileManager.default.removeItem(at: entry.url)
        }
        let folder = entry.url.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true { try? FileManager.default.removeItem(at: folder) }
        entries.removeValue(forKey: entry.id)
    }
}
