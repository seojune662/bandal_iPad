import Darwin
import Foundation

/// Opened once, then read in bounded chunks. This avoids round-tripping entire
/// videos/PDFs through JavaScriptCore for every WebKit Range request.
final class DesktopMaterialFile: @unchecked Sendable {
    let handle: FileHandle
    let size: Int64
    private let modified: timespec
    init(path: String, root: URL) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let allowed = { (candidate: URL) in
            // iPadOS may spell F_GETPATH's opened descriptor with /private/var
            // while Foundation supplies /var (or conversely). Compare both
            // sides after the same canonicalization, retaining the root check.
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            return resolved.path.hasPrefix(canonicalRoot.path + "/") || DesktopFileAccess.shared(root: root).allows(resolved)
        }
        guard allowed(url) else { throw DesktopRuntimeError("과목의 자료에 접근할 수 없습니다.") }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw DesktopRuntimeError("자료를 열지 못했습니다.") }
        let opened = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            var actual = [CChar](repeating: 0, count: Int(MAXPATHLEN)), metadata = Darwin.stat()
            guard fcntl(fd, F_GETPATH, &actual) == 0, allowed(URL(fileURLWithPath: String(cString: actual))),
                  fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0 else { throw DesktopRuntimeError("자료 위치나 파일 형식이 변경되었습니다.") }
            handle = opened; size = metadata.st_size; modified = metadata.st_mtimespec
        } catch { try? opened.close(); throw error }
    }
    func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, count <= 256 * 1024 else { throw DesktopRuntimeError("잘못된 자료 읽기 크기입니다.") }
        var metadata = Darwin.stat()
        guard fstat(handle.fileDescriptor, &metadata) == 0, metadata.st_size == size,
              metadata.st_mtimespec.tv_sec == modified.tv_sec, metadata.st_mtimespec.tv_nsec == modified.tv_nsec else { throw DesktopRuntimeError("읽는 동안 자료가 변경되었습니다.") }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }
    deinit { try? handle.close() }

    struct Selection: Equatable { let status: Int; let offset: Int64; let length: Int64; let contentRange: String? }
    static func selection(size: Int64, range: String?) -> Selection {
        let whole = Selection(status: 200, offset: 0, length: size, contentRange: nil)
        guard let range else { return whole }
        let invalid = Selection(status: 416, offset: 0, length: 0, contentRange: "bytes */\(size)")
        guard size > 0, range.hasPrefix("bytes="), !range.contains(",") else { return invalid }
        let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return invalid }
        let start: Int64, end: Int64
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { return invalid }
            start = max(0, size - suffix); end = size - 1
        } else {
            guard let first = Int64(parts[0]), first >= 0, first < size else { return invalid }
            start = first
            if parts[1].isEmpty { end = size - 1 }
            else { guard let last = Int64(parts[1]), last >= first else { return invalid }; end = min(last, size - 1) }
        }
        return Selection(status: 206, offset: start, length: end - start + 1, contentRange: "bytes \(start)-\(end)/\(size)")
    }
}
