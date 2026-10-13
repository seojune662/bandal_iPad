import Foundation

public enum CoreError: Error, Sendable, Equatable, LocalizedError {
    case database(String)
    case invalidRecord(String)
    case missingRecord(String)
    case unsupportedVersion(Int)
    case transport(Int, String)
    case invalidResponse(String)
    case assetIntegrity

    public var errorDescription: String? {
        switch self {
        case .database(let detail): "저장소 오류: \(detail)"
        case .invalidRecord(let detail): "자료를 처리할 수 없습니다: \(detail)"
        case .missingRecord: "자료를 찾을 수 없습니다."
        case .unsupportedVersion: "더 새로운 자료 형식입니다. 앱을 업데이트해 주세요."
        case .transport(let status, _): "동기화 서버에 연결하지 못했습니다 (HTTP \(status)). 저장한 자료는 기기에 보관됩니다."
        case .invalidResponse: "동기화 응답 형식이 올바르지 않습니다. 기기의 자료는 보관됩니다."
        case .assetIntegrity: "파일 무결성을 확인할 수 없어 다운로드를 적용하지 않았습니다."
        }
    }
}

/// `revision` is the optimistic record revision, not a wall-clock timestamp.
/// Payload versions belong to the domain payload; formatVersion versions this envelope.
public struct StoredRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let payload: Data
    public let revision: Int
    public let deleted: Bool
    public let formatVersion: Int

    public init(id: String, kind: String, payload: Data, revision: Int = 0,
                deleted: Bool = false, formatVersion: Int = 1) {
        self.id = id; self.kind = kind; self.payload = payload
        self.revision = revision; self.deleted = deleted; self.formatVersion = formatVersion
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}

public struct SyncOperation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let baseRevision: Int
    public let record: StoredRecord
    public init(id: String = UUID().uuidString, baseRevision: Int, record: StoredRecord) {
        self.id = id; self.baseRevision = baseRevision; self.record = record
    }
}

public struct SyncConflict: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let local: StoredRecord
    public let remote: StoredRecord
    public let createdAt: Date
}

public struct PushResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case accepted, conflict }
    public let status: Status
    public let record: StoredRecord
    public init(status: Status, record: StoredRecord) { self.status = status; self.record = record }
}

public struct PullPage: Codable, Sendable, Equatable {
    public let records: [StoredRecord]
    public let cursor: Int64
    public let hasMore: Bool
    public init(records: [StoredRecord], cursor: Int64, hasMore: Bool) {
        self.records = records; self.cursor = cursor; self.hasMore = hasMore
    }
}

public enum SyncPolicy {
    /// Device layout and credentials are intentionally local-only. Add domain kinds
    /// here and in the SQL constraint together; never sync Keychain or browser data.
    public static let allowedKinds: Set<String> = [
        "course", "material", "note", "drawing", "annotation", "board", "task",
        "calendarEvent", "recording", "favorite", "chat", "learningEvent",
        "vocabulary", "flashcard", "quiz", "artifact"
    ]
}

func validate(_ record: StoredRecord) throws {
    guard record.formatVersion == 1 else { throw CoreError.unsupportedVersion(record.formatVersion) }
    guard !record.id.isEmpty, record.id.utf8.count <= 512,
          !record.kind.isEmpty, record.kind.utf8.count <= 64,
          record.revision >= 0, record.revision < 9_007_199_254_740_991,
          record.payload.count <= 4 * 1024 * 1024 else {
        throw CoreError.invalidRecord("Invalid identifier, revision, or payload size")
    }
    guard (try? JSONSerialization.jsonObject(with: record.payload, options: [.fragmentsAllowed])) != nil else {
        throw CoreError.invalidRecord("Payload must contain valid UTF-8 JSON")
    }
}
