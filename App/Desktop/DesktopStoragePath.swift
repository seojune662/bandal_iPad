import Darwin
import Foundation

enum DesktopStoragePath {
    /// Foundation alone gives different /var aliases for existing and missing
    /// iPadOS paths. Resolve the existing ancestor, then append only missing
    /// components. A dangling link must never be treated as a missing name.
    static func canonical(_ url: URL) throws -> URL {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        var info = Darwin.stat()
        while Darwin.lstat(ancestor.path, &info) != 0 {
            guard errno == ENOENT, ancestor.path != "/" else {
                throw DesktopRuntimeError("자료 경로를 확인할 수 없습니다.", code: "EACCES")
            }
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        guard let bytes = Darwin.realpath(ancestor.path, nil) else {
            throw DesktopRuntimeError("자료 경로의 연결을 확인할 수 없습니다.", code: "EACCES")
        }
        defer { free(bytes) }
        var resolved = URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath()
        if !suffix.isEmpty {
            guard Darwin.fstatat(AT_FDCWD, resolved.path, &info, 0) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw DesktopRuntimeError("자료의 상위 폴더가 올바르지 않습니다.", code: "ENOTDIR")
            }
        }
        for component in suffix.reversed() { resolved.appendPathComponent(component) }
        return resolved
    }
}
