import CryptoKit
import Darwin
import Foundation

/// Reuses a digest only while the opened file's identity, size and both timestamps
/// are unchanged. This avoids reading large, unchanged recordings every sync pass.
public final class FileDigestCache: @unchecked Sendable {
    private struct Signature: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: Darwin.stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }
    private struct Entry { let signature: Signature; let digest: String; var access: UInt64 }
    private let lock = NSLock()
    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private var hashedBytes: Int64 = 0

    public init(capacity: Int = 512) { self.capacity = max(1, capacity) }

    // Internal diagnostic lets tests verify that repeated sync does not read all bytes.
    var bytesHashed: Int64 { lock.withLock { hashedBytes } }

    public func revision(of file: URL, contentType: String = "application/octet-stream",
                         validateOpenedFile: ((URL) throws -> Void)? = nil) throws -> AssetRevision {
        let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
        let fd = Darwin.open(canonical.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(fd, F_GETPATH, &path) == 0 else { throw posixError() }
        let opened = URL(fileURLWithPath: String(cString: path)).standardizedFileURL.resolvingSymlinksInPath()
        guard opened.path == canonical.path else { throw CoreError.assetIntegrity }
        try validateOpenedFile?(opened)
        let before = try signature(fd)
        if let digest = lock.withLock({ () -> String? in
            guard var entry = entries[canonical.path], entry.signature == before else { return nil }
            clock &+= 1; entry.access = clock; entries[canonical.path] = entry
            return entry.digest
        }) {
            return AssetRevision(sha256: digest, byteCount: before.size,
                                 originalName: file.lastPathComponent, contentType: contentType)
        }

        var digest = SHA256(), count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let length = Darwin.read(fd, &buffer, buffer.count)
            if length < 0, errno == EINTR { continue }
            guard length >= 0 else { throw posixError() }
            if length == 0 { break }
            digest.update(data: Data(buffer[0..<length])); count += Int64(length)
        }
        guard try signature(fd) == before, count == before.size else { throw CoreError.assetIntegrity }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            hashedBytes += count; clock &+= 1
            entries[canonical.path] = Entry(signature: before, digest: hash, access: clock)
            if entries.count > capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
        return AssetRevision(sha256: hash, byteCount: count, originalName: file.lastPathComponent, contentType: contentType)
    }

    private func signature(_ fd: Int32) throws -> Signature {
        var value = Darwin.stat()
        guard Darwin.fstat(fd, &value) == 0 else { throw posixError() }
        guard value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { throw CoreError.assetIntegrity }
        return Signature(value)
    }
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
