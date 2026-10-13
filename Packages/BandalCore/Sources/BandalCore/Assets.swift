import CryptoKit
import Foundation

public struct AssetRevision: Codable, Sendable, Equatable, Identifiable {
    public var id: String { sha256 }
    public let sha256: String
    public let byteCount: Int64
    public let originalName: String
    public let contentType: String
    public init(sha256: String, byteCount: Int64, originalName: String, contentType: String) {
        self.sha256 = sha256; self.byteCount = byteCount
        self.originalName = originalName; self.contentType = contentType
    }
}

public protocol AssetTransport: Sendable {
    func uploadAsset(_ revision: AssetRevision, from file: URL) async throws
    func downloadAsset(_ revision: AssetRevision, to destination: URL) async throws
}

public enum AssetHasher {
    public static func revision(of file: URL, contentType: String = "application/octet-stream") throws -> AssetRevision {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256(), count: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data); count += Int64(data.count)
        }
        return AssetRevision(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                             byteCount: count, originalName: file.lastPathComponent, contentType: contentType)
    }
    public static func verify(_ revision: AssetRevision, file: URL) throws {
        try validateAsset(revision)
        let actual = try Self.revision(of: file)
        guard actual.sha256 == revision.sha256, actual.byteCount == revision.byteCount else { throw CoreError.assetIntegrity }
    }
}

func validateAsset(_ revision: AssetRevision) throws {
    guard revision.sha256.count == 64, revision.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
          revision.byteCount >= 0, !revision.contentType.contains("\r"), !revision.contentType.contains("\n") else {
        throw CoreError.assetIntegrity
    }
}

/// Immutable, content-addressed local assets. Hashes refer to bytes, never file paths.
public actor AssetStore {
    private let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func importFile(at source: URL, contentType: String = "application/octet-stream") throws -> AssetRevision {
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        let snapshot = try AssetHasher.revision(of: temporary, contentType: contentType)
        let revision = AssetRevision(sha256: snapshot.sha256, byteCount: snapshot.byteCount,
                                     originalName: source.lastPathComponent, contentType: contentType)
        let destination = try url(for: revision)
        if FileManager.default.fileExists(atPath: destination.path) {
            try AssetHasher.verify(revision, file: destination)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        return revision
    }

    public func url(for revision: AssetRevision) throws -> URL {
        try validateAsset(revision)
        return directory.appendingPathComponent(revision.sha256)
    }

    public func ensureAvailable(_ revision: AssetRevision, transport: any AssetTransport) async throws -> URL {
        let destination = try url(for: revision)
        if FileManager.default.fileExists(atPath: destination.path) {
            try AssetHasher.verify(revision, file: destination); return destination
        }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await transport.downloadAsset(revision, to: temporary)
        try AssetHasher.verify(revision, file: temporary)
        // Another suspended caller may have completed the same download.
        if FileManager.default.fileExists(atPath: destination.path) {
            try AssetHasher.verify(revision, file: destination)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        return destination
    }

    public func upload(_ revision: AssetRevision, transport: any AssetTransport) async throws {
        let source = try url(for: revision)
        try AssetHasher.verify(revision, file: source)
        try await transport.uploadAsset(revision, from: source)
    }
}
