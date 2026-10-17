import Foundation

/// Product scope does not change the wire protocol: older content is retained
/// in the record store and its cursor still advances, without publishing it.
public enum SyncScope: String, Sendable {
    case all
    case personalContentV1 = "personal-content-v1"

    public func includes(_ record: StoredRecord) -> Bool {
        if self == .all { return true }
        if ["course", "material", "note", "drawing", "annotation"].contains(record.kind) { return true }
        guard record.kind == "artifact",
              let payload = try? JSONSerialization.jsonObject(with: record.payload) as? [String: Any] else { return false }
        return payload["recordType"] as? String == "desktop-course-group"
    }
}

public struct SyncAccessStatus: Codable, Sendable, Equatable {
    public let writeAllowed: Bool
    public let storageLimitBytes: Int64
    public let storageUsedBytes: Int64
    public let usageComplete: Bool
    public var quotaExceeded: Bool { writeAllowed && usageComplete && storageLimitBytes > 0 && storageUsedBytes >= storageLimitBytes }
    public init(writeAllowed: Bool, storageLimitBytes: Int64 = 0, storageUsedBytes: Int64 = 0, usageComplete: Bool = true) {
        self.writeAllowed = writeAllowed; self.storageLimitBytes = storageLimitBytes
        self.storageUsedBytes = storageUsedBytes; self.usageComplete = usageComplete
    }
}

public enum SyncFailureCode: String, Codable, Sendable {
    case subscriptionRequired = "subscription_required"
    case storageLimitExceeded = "storage_limit_exceeded"
    case authenticationRequired = "sign_in_required"
    case rateLimited = "rate_limited"
    case unavailable = "service_unavailable"
    case requestRejected = "request_rejected"
}

public struct SyncRequestFailure: Error, Sendable, Equatable, LocalizedError {
    public let code: SyncFailureCode
    public let status: Int
    public let retryAfter: TimeInterval?
    public init(code: SyncFailureCode, status: Int, retryAfter: TimeInterval? = nil) {
        self.code = code; self.status = status; self.retryAfter = retryAfter
    }
    public var blocksWrites: Bool { code == .subscriptionRequired || code == .storageLimitExceeded }
    public var errorDescription: String? {
        switch code {
        case .subscriptionRequired: "동기화 구독이 필요합니다. 기기의 자료는 계속 사용할 수 있습니다."
        case .storageLimitExceeded: "동기화 저장 공간이 가득 찼습니다. 기기의 변경 내용은 보관됩니다."
        case .authenticationRequired: "다시 로그인하면 동기화를 이어갈 수 있습니다."
        case .rateLimited: "잠시 후 동기화를 다시 시도합니다."
        case .unavailable: "동기화 서버에 연결하지 못했습니다. 기기의 자료는 보관됩니다."
        case .requestRejected: "동기화 요청을 확인하지 못했습니다. 기기의 자료는 보관됩니다."
        }
    }
}
