import Foundation

/// Security-scoped folders explicitly selected in the system picker. The same
/// registry is shared by the main-actor picker and serial repository runtime.
final class DesktopFileAccess: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registries: [String: DesktopFileAccess] = [:]
    static func shared(root: URL) -> DesktopFileAccess {
        registryLock.lock(); defer { registryLock.unlock() }
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        if let value = registries[key] { return value }
        let value = DesktopFileAccess(root: root); registries[key] = value; return value
    }

    private let file: URL
    private let lock = NSLock()
    private var loaded = false
    private var bookmarks: [String: Data] = [:]
    private var granted: [URL] = []
    private init(root: URL) { file = root.appendingPathComponent("linked-folders.json") }
    deinit { for url in granted { url.stopAccessingSecurityScopedResource() } }

    func authorize(_ selected: URL) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try load()
        guard selected.startAccessingSecurityScopedResource() else { throw DesktopRuntimeError("선택한 폴더에 접근할 수 없습니다. 다시 선택해 주세요.", code: "EACCES") }
        do {
            let bookmark = try selected.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            var next = bookmarks
            let resolved = selected.standardizedFileURL.resolvingSymlinksInPath()
            next[resolved.path] = bookmark
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(next)
            try data.write(to: file, options: .atomic)
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
            bookmarks = next; granted.append(selected)
            return resolved
        } catch { selected.stopAccessingSecurityScopedResource(); throw error }
    }

    func allows(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard (try? load()) != nil else { return false }
        guard let path = try? DesktopStoragePath.canonical(url).path else { return false }
        return granted.contains { scope in
            guard let root = try? DesktopStoragePath.canonical(scope).path else { return false }
            return path == root || path.hasPrefix(root + "/")
        }
    }

    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            bookmarks = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: file))
            for bookmark in bookmarks.values {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() else { continue }
                granted.append(url)
            }
        }
        loaded = true
    }
}
