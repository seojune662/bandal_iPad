import Darwin
import Foundation
import Testing
@testable import BandalCore

private func digestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigestCache-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func unchangedRecordingIsNotReadOnEverySync() throws {
    let root = try digestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("lecture.wav")
    let bytes = Data(repeating: 41, count: 4 * 1024 * 1024)
    try bytes.write(to: file)
    let cache = FileDigestCache()
    let first = try cache.revision(of: file, contentType: "audio/wav")
    for _ in 0..<20 {
        #expect(try cache.revision(of: file, contentType: "audio/wav") == first)
    }
    #expect(cache.bytesHashed == Int64(bytes.count))
    #expect(first == (try AssetHasher.revision(of: file, contentType: "audio/wav")))
}

@Test func sameSizeEditsWithRestoredModificationTimeInvalidateDigest() throws {
    let root = try digestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("note.md")
    try Data("before".utf8).write(to: file)
    let cache = FileDigestCache()
    let first = try cache.revision(of: file)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let handle = try FileHandle(forWritingTo: file)
    try handle.write(contentsOf: Data("after!".utf8)); try handle.synchronize(); try handle.close()
    try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: file.path)
    let second = try cache.revision(of: file)
    #expect(first.sha256 != second.sha256)
    #expect(second == (try AssetHasher.revision(of: file)))
    #expect(cache.bytesHashed == 12)
    // Atomic replacement with equal bytes/metadata must still use the new inode.
    try Data("third!".utf8).write(to: file, options: .atomic)
    let third = try cache.revision(of: file)
    #expect(third.sha256 != second.sha256)
}

@Test func digestChecksOpenedFileAuthorizationEvenOnCacheHit() throws {
    let root = try digestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("private.pdf")
    try Data("document".utf8).write(to: file)
    let cache = FileDigestCache()
    _ = try cache.revision(of: file)
    #expect(throws: CoreError.self) {
        try cache.revision(of: file, validateOpenedFile: { _ in throw CoreError.assetIntegrity })
    }
    #expect(throws: CoreError.self) { try cache.revision(of: root) }
    let fifo = root.appendingPathComponent("stream")
    #expect(Darwin.mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: CoreError.self) { try cache.revision(of: fifo) }
}
