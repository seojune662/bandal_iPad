import BandalCore
import CryptoKit
import Darwin
import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Runs exclusively on DesktopRuntime's serial queue. Paths are verified here,
/// including symlinks and file descriptor ownership.
final class DesktopNativePrimitives: NSObject {
    let root: URL
    let legacyRoot: URL
    let database: DesktopSQLite
    var onEmit: ((String, Any) -> Void)?
    private var descriptors: Set<Int32> = []
    private var pathLocks: Set<Int32> = []
    private var hashes: [String: SHA256] = [:]
    private let fileDigests = FileDigestCache()
    private lazy var mcpVault = DesktopMCPVault(namespace: root.lastPathComponent)
    private let files = FileManager.default

    init(root: URL, legacyRoot: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = try DesktopStoragePath.canonical(root)
        self.legacyRoot = try DesktopStoragePath.canonical(legacyRoot)
        database = try DesktopSQLite(url: root.appendingPathComponent("bandal.db"))
        super.init()
        for directory in ["Courses", "Home", "Temporary"] {
            try files.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
    }

    deinit { for descriptor in descriptors.union(pathLocks) { Darwin.close(descriptor) } }

    func perform(_ request: String) -> String {
        do {
            guard let data = request.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let operation = object["op"] as? String else { throw DesktopRuntimeError("Invalid native operation") }
            let result = try perform(operation, args: object["args"] as? [String: Any] ?? [:])
            return try json(["ok": true, "value": result])
        } catch {
            let failure = normalize(error)
            return (try? json(["ok": false, "error": ["message": failure.message, "code": failure.code]])) ?? "{\"ok\":false,\"error\":{\"message\":\"Native bridge failure\"}}"
        }
    }

    func emit(_ channel: String, _ payload: String) {
        guard let data = payload.data(using: .utf8), let value = try? DesktopJSON.decode(data, options: .fragmentsAllowed) else { return }
        onEmit?(channel, value)
    }

    func log(_ level: String, _ message: String) { NSLog("[Desktop/%@] %@", level, String(message.prefix(8_192))) }

    func perform(_ operation: String, args: [String: Any]) throws -> Any {
        func string(_ key: String) throws -> String {
            guard let value = args[key] as? String else { throw DesktopRuntimeError("Missing \(key) for \(operation)", code: "EINVAL") }
            return value
        }
        func path(_ key: String = "path", write: Bool = false) throws -> URL { try checkedPath(try string(key), writing: write) }
        func descriptor() throws -> Int32 {
            guard let fd = args["fd"] as? Int, descriptors.contains(Int32(fd)) else { throw DesktopRuntimeError("Unknown descriptor", code: "EBADF") }
            return Int32(fd)
        }
        func bytes() throws -> Data {
            let value = try string("data")
            if (args["encoding"] as? String ?? "base64") == "utf8" { return Data(value.utf8) }
            guard let data = Data(base64Encoded: value) else { throw DesktopRuntimeError("Invalid base64", code: "EINVAL") }
            return data
        }
        switch operation {
        case "mcp.available": return mcpVault.available()
        case "mcp.encrypt": return try mcpVault.encrypt(string("plaintext"))
        case "mcp.decrypt": return try mcpVault.decrypt(string("ciphertext"))
        case "environment":
            return ["userDataPath": root.path, "dataRoot": root.appendingPathComponent("Courses").path,
                    "homePath": root.appendingPathComponent("Home").path, "tempPath": root.appendingPathComponent("Temporary").path,
                    "legacyDataPath": legacyRoot.path, "platform": "ios", "version": DesktopVersion.current, "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                    "resourcesPath": Bundle.main.resourceURL?.appendingPathComponent("DesktopNative").path ?? "",
                    "pdfFontPath": Bundle.main.resourceURL?.appendingPathComponent("DesktopNative/fonts").path ?? "",
                    "fsConstants": ["O_RDONLY": Int(O_RDONLY), "O_NOFOLLOW": Int(O_NOFOLLOW)]]
        case "sqlite.exec": try database.exec(try string("sql")); return NSNull()
        case "sqlite.query": return try database.query(try string("sql"), params: args["params"])
        case "sqlite.run": return try database.run(try string("sql"), params: args["params"])
        case "legacy.snapshot":
            let source = legacyRoot.appendingPathComponent("bandal.sqlite")
            var records: [[String: Any]] = []
            var appliedMutations = Set<String>()
            if files.fileExists(atPath: source.path) {
                let old = try DesktopSQLite(url: source, readOnly: true)
                if !(try old.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='local_mutation_receipts'", params: nil)).isEmpty {
                    appliedMutations = Set(try old.query("SELECT mutation_id FROM local_mutation_receipts", params: nil).compactMap { $0["mutation_id"] as? String })
                }
                records = try old.query("SELECT id,kind,payload,revision,deleted,format_version AS formatVersion FROM records ORDER BY id", params: nil).map { row in
                    var row = row
                    guard let buffer = row["payload"] as? [String: String], let encoded = buffer["__buffer"], let bytes = Data(base64Encoded: encoded) else { throw DesktopRuntimeError("Legacy record payload is not readable") }
                    row["payload"] = try JSONSerialization.jsonObject(with: bytes)
                    return row
                }
            }
            let pendingFolder = legacyRoot.appendingPathComponent("PendingEdits")
            let pendingFiles = (try? files.contentsOfDirectory(at: pendingFolder, includingPropertiesForKeys: nil)) ?? []
            let pending = try pendingFiles.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url -> [String: Any]? in
                guard var entry = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], let encoded = entry["payload"] as? String, let bytes = Data(base64Encoded: encoded) else { throw DesktopRuntimeError("Legacy pending edit is not readable: \(url.lastPathComponent)") }
                if let mutation = entry["mutationID"] as? String, appliedMutations.contains(mutation) { return nil }
                entry["payload"] = try JSONSerialization.jsonObject(with: bytes)
                entry["fileName"] = url.lastPathComponent
                return entry
            }
            return ["records": records, "pending": pending]
        case "pdf.geometry":
            guard let document = PDFDocument(url: try path()) else { throw DesktopRuntimeError("PDF could not be opened") }
            return (0..<document.pageCount).compactMap { index -> [String: Any]? in
                guard let page = document.page(at: index) else { return nil }
                let box = page.bounds(for: .cropBox)
                return ["page": index + 1, "cropBox": ["x": box.minX, "y": box.minY, "width": box.width, "height": box.height], "rotation": page.rotation]
            }
        case "pdf.source":
            let source = try path()
            let size = (try files.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= 50 * 1024 * 1024, let document = PDFDocument(url: source), !document.isLocked else { throw DesktopRuntimeError("PDF 텍스트를 읽을 수 없습니다.") }
            let maxChars = max(1, min(args["maxChars"] as? Int ?? 200_000, 200_000))
            let maxPages = max(1, min(args["maxPages"] as? Int ?? 200, 200))
            var pages: [[String: Any]] = [], sections: [String] = [], remaining = maxChars
            var truncated = document.pageCount > maxPages
            for index in 0..<min(document.pageCount, maxPages) {
                guard remaining > 0 else { truncated = true; break }
                let raw = document.page(at: index)?.string ?? ""
                let header = "## 페이지 \(index + 1)\n"
                let available = max(0, remaining - header.utf16.count - (sections.isEmpty ? 0 : 2))
                var end = min(raw.utf16.count, available)
                let units = Array(raw.utf16)
                if end > 0, end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
                let value = String(decoding: units.prefix(end), as: UTF16.self)
                if end < units.count { truncated = true }
                if available == 0 { truncated = true; break }
                pages.append(["page": index + 1, "text": value]); sections.append(header + value)
                remaining -= header.utf16.count + value.utf16.count + (sections.count > 1 ? 2 : 0)
            }
            return ["text": sections.joined(separator: "\n\n"), "pages": pages, "truncated": truncated]
        case "fs.exists": return files.fileExists(atPath: try path().path)
        case "fs.lockAcquire":
            let url = try path(write: true)
            let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw posixError() }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                Darwin.close(fd)
                if code == EWOULDBLOCK || code == EAGAIN { return NSNull() }
                errno = code
                throw posixError()
            }
            pathLocks.insert(fd)
            return Int(fd)
        case "fs.lockRelease":
            guard let token = args["token"] as? Int, let fd = Int32(exactly: token), pathLocks.remove(fd) != nil else {
                throw DesktopRuntimeError("Unknown path lock", code: "EBADF")
            }
            // Closing releases the advisory lock, including on process exit.
            guard Darwin.close(fd) == 0 else { throw posixError() }
            return NSNull()
        case "fs.realpath":
            let url = try path()
            guard files.fileExists(atPath: url.path) else { throw DesktopRuntimeError("No such file: \(url.lastPathComponent)", code: "ENOENT") }
            return url.resolvingSymlinksInPath().path
        case "fs.stat": return try stat(try path(), follow: args["followSymlinks"] as? Bool ?? true)
        case "fs.fstat":
            var value = Darwin.stat()
            guard try Darwin.fstat(descriptor(), &value) == 0 else { throw posixError() }
            return statValue(value)
        case "fs.readdir":
            return try files.contentsOfDirectory(at: path(), includingPropertiesForKeys: nil).map { url -> [String: Any] in
                var item = try stat(url, follow: false)
                item["name"] = url.lastPathComponent
                return item
            }
        case "fs.readFile":
            let data = try Data(contentsOf: path())
            if args["encoding"] as? String == "utf8" { return String(decoding: data, as: UTF8.self) }
            return data.base64EncodedString()
        case "fs.sha256":
            return try fileDigests.revision(of: path(), validateOpenedFile: { opened in
                _ = try self.checkedPath(opened.path, writing: false)
            }).sha256
        case "fs.writeFile":
            let url = try path(write: true), data = try bytes()
            let flags = (args["flag"] as? String) ?? "w"
            let fd = try openFile(url, flags: flags, mode: args["mode"] as? Int ?? 0o600)
            defer { Darwin.close(fd) }
            try writeAll(data, descriptor: fd)
            guard Darwin.fsync(fd) == 0 else { throw posixError() }
            return NSNull()
        case "fs.mkdir":
            let url = try path(write: true)
            if files.fileExists(atPath: url.path), args["recursive"] as? Bool != true { throw DesktopRuntimeError("File exists", code: "EEXIST") }
            try files.createDirectory(at: url, withIntermediateDirectories: args["recursive"] as? Bool ?? false)
            return NSNull()
        case "fs.rename":
            let from = try path("from", write: true), to = try path("to", write: true)
            guard Darwin.rename(from.path, to.path) == 0 else { throw posixError() }
            return NSNull()
        case "fs.remove":
            let url = try path(write: true)
            guard try DesktopStoragePath.canonical(url).path != root.path else { throw DesktopRuntimeError("Cannot remove the storage root", code: "EACCES") }
            if !files.fileExists(atPath: url.path), args["force"] as? Bool == true { return NSNull() }
            if (try? stat(url, follow: false)["isDirectory"] as? Bool) == true, args["recursive"] as? Bool != true {
                guard Darwin.rmdir(url.path) == 0 else { throw posixError() }
            } else { try files.removeItem(at: url) }
            return NSNull()
        case "fs.copy":
            let from = try path("from"), to = try path("to", write: true)
            if files.fileExists(atPath: to.path) {
                guard args["overwrite"] as? Bool == true else { throw DesktopRuntimeError("File exists", code: "EEXIST") }
                // NSData atomic replacement preserves the old file if copying fails.
                if (try stat(from, follow: true)["isFile"] as? Bool) == true {
                    try Data(contentsOf: from).write(to: to, options: .atomic)
                    return NSNull()
                }
                throw DesktopRuntimeError("Directory overwrite requires an explicit merge", code: "EEXIST")
            }
            if (try stat(from, follow: true)["isDirectory"] as? Bool) == true, args["recursive"] as? Bool != true {
                throw DesktopRuntimeError("Recursive copy required", code: "EISDIR")
            }
            try files.copyItem(at: from, to: to)
            return NSNull()
        case "fs.access":
            let mode = Int32(args["mode"] as? Int ?? 0)
            let url = try path(write: (mode & W_OK) != 0)
            guard Darwin.access(url.path, mode) == 0 else { throw posixError() }
            return NSNull()
        case "fs.chmod":
            let url = try path(write: true)
            guard let mode = args["mode"] as? Int, Darwin.chmod(url.path, mode_t(mode)) == 0 else { throw posixError() }
            return NSNull()
        case "fs.open":
            if let numeric = args["flags"] as? Int {
                guard numeric == Int(O_RDONLY) || numeric == Int(O_RDONLY | O_NOFOLLOW) else { throw DesktopRuntimeError("Unsupported numeric open flags", code: "EINVAL") }
                let url = try path()
                let fd = Darwin.open(url.path, Int32(numeric) | O_NOFOLLOW)
                guard fd >= 0 else { throw posixError() }
                descriptors.insert(fd); return Int(fd)
            }
            let flags = args["flags"] as? String ?? "r"
            let fd = try openFile(path(write: flags != "r"), flags: flags, mode: args["mode"] as? Int ?? 0o600)
            descriptors.insert(fd)
            return Int(fd)
        case "fs.close":
            let fd = try descriptor(); descriptors.remove(fd)
            guard Darwin.close(fd) == 0 else { throw posixError() }; return NSNull()
        case "fs.fsync": guard try Darwin.fsync(descriptor()) == 0 else { throw posixError() }; return NSNull()
        case "fs.ftruncate": guard try Darwin.ftruncate(descriptor(), off_t(args["length"] as? Int ?? 0)) == 0 else { throw posixError() }; return NSNull()
        case "fs.read":
            let fd = try descriptor(), length = args["length"] as? Int ?? 0
            guard length >= 0, length <= 256 * 1024 * 1024 else { throw DesktopRuntimeError("Invalid read size", code: "EINVAL") }
            var data = Data(count: length)
            let count = data.withUnsafeMutableBytes { buffer in
                if let offset = args["position"] as? Int { return Darwin.pread(fd, buffer.baseAddress, length, off_t(offset)) }
                return Darwin.read(fd, buffer.baseAddress, length)
            }
            guard count >= 0 else { throw posixError() }
            data.count = count
            return data.base64EncodedString()
        case "fs.write":
            let fd = try descriptor(), data = try bytes()
            let count = data.withUnsafeBytes { buffer in
                if let offset = args["position"] as? Int { return Darwin.pwrite(fd, buffer.baseAddress, data.count, off_t(offset)) }
                return Darwin.write(fd, buffer.baseAddress, data.count)
            }
            guard count >= 0 else { throw posixError() }; return count
        case "crypto.randomUUID": return UUID().uuidString.lowercased()
        case "crypto.randomBytes":
            let count = args["length"] as? Int ?? 0
            guard count >= 0, count <= 1_048_576 else { throw DesktopRuntimeError("Invalid random size", code: "EINVAL") }
            var data = Data(count: count)
            let status = data.withUnsafeMutableBytes { pointer -> OSStatus in
                guard count > 0 else { return errSecSuccess }
                return SecRandomCopyBytes(kSecRandomDefault, count, pointer.baseAddress!)
            }
            guard status == errSecSuccess else { throw DesktopRuntimeError("Random generation failed") }
            return data.base64EncodedString()
        case "crypto.sha256": return SHA256.hash(data: try bytes()).map { String(format: "%02x", $0) }.joined()
        case "crypto.hashCreate":
            guard args["algorithm"] as? String == "sha256", hashes.count < 1024 else { throw DesktopRuntimeError("Invalid hash context", code: "EINVAL") }
            let id = UUID().uuidString; hashes[id] = SHA256(); return id
        case "crypto.hashUpdate":
            let id = try string("id")
            guard var hash = hashes[id] else { throw DesktopRuntimeError("Unknown hash context", code: "EINVAL") }
            let data = try bytes()
            guard data.count <= 8 * 1024 * 1024 else { throw DesktopRuntimeError("Hash chunk is too large", code: "EINVAL") }
            hash.update(data: data); hashes[id] = hash; return NSNull()
        case "crypto.hashDigest":
            guard let hash = hashes.removeValue(forKey: try string("id")) else { throw DesktopRuntimeError("Unknown hash context", code: "EINVAL") }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        case "image.png":
            let data = try bytes()
            #if canImport(UIKit)
            guard let image = UIImage(data: data), let encoded = image.pngData() else { throw DesktopRuntimeError("이미지를 PNG로 변환하지 못했습니다.") }
            #else
            guard let image = NSBitmapImageRep(data: data), let encoded = image.representation(using: .png, properties: [:]) else { throw DesktopRuntimeError("이미지를 PNG로 변환하지 못했습니다.") }
            #endif
            return encoded.base64EncodedString()
        case "url.parse":
            let base = (args["base"] as? String).flatMap(URL.init(string:))
            guard let url = URL(string: try string("url"), relativeTo: base)?.absoluteURL,
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: true), let scheme = parts.scheme else {
                throw DesktopRuntimeError("Invalid URL", code: "ERR_INVALID_URL")
            }
            let host = url.host() ?? ""
            let port = parts.port.map(String.init) ?? ""
            let authority = host + (port.isEmpty ? "" : ":" + port)
            return ["href": url.absoluteString, "protocol": scheme + ":", "hostname": host, "host": authority,
                    "port": port, "pathname": parts.percentEncodedPath.isEmpty && !host.isEmpty ? "/" : parts.percentEncodedPath,
                    "search": parts.percentEncodedQuery.map { "?" + $0 } ?? "", "hash": parts.percentEncodedFragment.map { "#" + $0 } ?? "",
                    "username": parts.percentEncodedUser ?? "", "password": parts.percentEncodedPassword ?? "",
                    "origin": ["http", "https"].contains(scheme) ? scheme + "://" + authority : "null"]
        default: throw DesktopRuntimeError("Native operation is not implemented: \(operation)", code: "ENOSYS")
        }
    }

    func checkedPath(_ path: String, writing: Bool) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw DesktopRuntimeError("Expected an absolute sandbox path", code: "EACCES") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = try DesktopStoragePath.canonical(url)
        func inside(_ base: URL) -> Bool { resolved.path == base.path || resolved.path.hasPrefix(base.path + "/") }
        let resourceRoot = Bundle.main.resourceURL?.appendingPathComponent("DesktopNative").resolvingSymlinksInPath()
        guard inside(root) || (!writing && (inside(legacyRoot) || resourceRoot.map(inside) == true)) || DesktopFileAccess.shared(root: root).allows(resolved) else { throw DesktopRuntimeError("Path is outside Bandal storage", code: "EACCES") }
        return url
    }

    private func stat(_ url: URL, follow: Bool) throws -> [String: Any] {
        var value = Darwin.stat()
        let result = Darwin.fstatat(AT_FDCWD, url.path, &value, follow ? 0 : AT_SYMLINK_NOFOLLOW)
        guard result == 0 else { throw posixError() }
        return statValue(value)
    }

    private func statValue(_ value: Darwin.stat) -> [String: Any] {
        let kind = value.st_mode & S_IFMT
        return ["dev": String(value.st_dev), "ino": String(value.st_ino),
                "size": value.st_size, "mtimeMs": Double(value.st_mtimespec.tv_sec) * 1000 + Double(value.st_mtimespec.tv_nsec) / 1_000_000,
                "mtimeNs": String(Int64(value.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(value.st_mtimespec.tv_nsec)),
                "ctimeNs": String(Int64(value.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(value.st_ctimespec.tv_nsec)),
                "ctimeMs": Double(value.st_ctimespec.tv_sec) * 1000 + Double(value.st_ctimespec.tv_nsec) / 1_000_000,
                "birthtimeMs": Double(value.st_birthtimespec.tv_sec) * 1000 + Double(value.st_birthtimespec.tv_nsec) / 1_000_000,
                "mode": value.st_mode, "isFile": kind == S_IFREG, "isDirectory": kind == S_IFDIR, "isSymbolicLink": kind == S_IFLNK]
    }

    private func openFile(_ url: URL, flags: String, mode: Int) throws -> Int32 {
        let modes: [String: Int32] = ["r": O_RDONLY, "r+": O_RDWR, "w": O_WRONLY | O_CREAT | O_TRUNC,
                                    "wx": O_WRONLY | O_CREAT | O_TRUNC | O_EXCL, "w+": O_RDWR | O_CREAT | O_TRUNC,
                                    "a": O_WRONLY | O_CREAT | O_APPEND, "ax": O_WRONLY | O_CREAT | O_APPEND | O_EXCL,
                                    "a+": O_RDWR | O_CREAT | O_APPEND]
        guard let options = modes[flags] else { throw DesktopRuntimeError("Unsupported open flags: \(flags)", code: "EINVAL") }
        let fd = Darwin.open(url.path, options | O_NOFOLLOW, mode_t(mode))
        guard fd >= 0 else { throw posixError() }; return fd
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
    }

    private func posixError() -> DesktopRuntimeError {
        let number = errno
        let codes: [Int32: String] = [ENOENT: "ENOENT", EEXIST: "EEXIST", EACCES: "EACCES", EPERM: "EPERM", EISDIR: "EISDIR", ENOTDIR: "ENOTDIR", ENOTEMPTY: "ENOTEMPTY", ENOSPC: "ENOSPC", EBADF: "EBADF", EINVAL: "EINVAL", ELOOP: "ELOOP"]
        return DesktopRuntimeError(String(cString: strerror(number)), code: codes[number] ?? "EIO")
    }

    private func normalize(_ error: Error) -> DesktopRuntimeError {
        if let error = error as? DesktopRuntimeError { return error }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return DesktopRuntimeError(ns.localizedDescription, code: "ENOENT")
            case NSFileWriteFileExistsError: return DesktopRuntimeError(ns.localizedDescription, code: "EEXIST")
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return DesktopRuntimeError(ns.localizedDescription, code: "EACCES")
            default: break
            }
        }
        return DesktopRuntimeError(error.localizedDescription, code: "EIO")
    }

    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
    }
}
