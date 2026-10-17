import Foundation
import CryptoKit

struct NativeSyncSnapshot {
    var records: [[String: Any]] = []
    var assets: [[String: Any]] = []
    var sources: [String: [String: Any]] = [:]
    mutating func append(_ other: Self) { records += other.records; assets += other.assets; sources.merge(other.sources) { _, next in next } }
}
struct NativeSyncFileChange {
    let target: URL
    let data: Data?
    var expectedHash: String?
    var expectedMissing: Bool
    init(target: URL, data: Data?, expectedHash: String? = nil, expectedMissing: Bool = false) { self.target = target; self.data = data; self.expectedHash = expectedHash; self.expectedMissing = expectedMissing }
}
struct NativeSyncPlan {
    var files: [NativeSyncFileChange] = []
    var source: [String: Any] = [:]
    var courseID: String? = nil
    var affectedCourseIDs = Set<String>()
    var apply: () throws -> Void = {}
}
enum NativeSyncFormat {
    static let coordinateSpace = "unrotated-crop-box-top-left-normalized"
    static let kinds: Set<String> = ["course", "material", "note", "drawing", "annotation", "board", "task", "calendarEvent", "recording", "favorite", "chat", "learningEvent", "vocabulary", "flashcard", "quiz", "artifact"]
    static func canonical(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }
    static func digest(_ value: Any) throws -> String { hash(Data(try canonical(value).utf8)) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func object(_ text: Any?) throws -> [String: Any] {
        guard let text = text as? String, let object = try DesktopJSON.decode(Data(text.utf8)) as? [String: Any] else { throw NativeRepositoryContext.validation("Invalid sync object") }; return object
    }
    static func validate(_ record: [String: Any]) throws {
        guard let id = record["id"] as? String, !id.isEmpty, id.count <= 512, let kind = record["kind"] as? String, kinds.contains(kind), (record["formatVersion"] as? NSNumber)?.intValue == 1, let deleted = record["deleted"] as? NSNumber, CFGetTypeID(deleted) == CFBooleanGetTypeID(), let payload = record["payload"] as? [String: Any], try canonical(payload).utf8.count <= 4 * 1024 * 1024 else { throw NativeRepositoryContext.validation("Invalid or oversized sync record") }
    }
    static func identity(_ value: Any?) throws -> String {
        guard let value = value as? String, value.range(of: #"^[a-zA-Z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { throw NativeRepositoryContext.validation("Invalid sync identity") }; return value
    }
    static func comparable(_ record: [String: Any]) throws -> String { try canonical(["kind": record["kind"] ?? NSNull(), "payload": record["payload"] ?? NSNull(), "deleted": record["deleted"] ?? false]) }
    static func record(id: String, kind: String, payload: [String: Any], deleted: Bool = false) -> [String: Any] { ["id": id, "kind": kind, "payload": payload, "deleted": deleted, "formatVersion": 1] }
    static func decodePage(_ record: [String: Any]) throws -> [String: Any] {
        guard let payload = record["payload"] as? [String: Any], let text = payload["data"] as? String, let data = Data(base64Encoded: text), data.count <= 4 * 1024 * 1024, let page = try DesktopJSON.decode(data) as? [String: Any] else { throw NativeRepositoryContext.validation("Invalid ink page") }; return page
    }
    static func encodePage(_ page: [String: Any]) throws -> [String: Any] { ["materialID": page["materialID"] ?? NSNull(), "documentRevision": page["documentRevision"] ?? NSNull(), "page": page["page"] ?? NSNull(), "data": Data(try canonical(page).utf8).base64EncodedString()] }
    static func asset(materialID: String, url: URL) throws -> [String: Any] {
        let before = try NativeRepositoryContext.identity(url), hash = try hash(url), after = try NativeRepositoryContext.identity(url)
        guard NativeRepositoryContext.sameIdentity(before, after) else { throw NativeRepositoryContext.conflict("Sync source changed while reading") }
        let ext = url.pathExtension.lowercased(), type = ["pdf": "application/pdf", "wav": "audio/wav", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg"][ext] ?? "application/octet-stream"
        return ["materialID": materialID, "sha256": hash, "path": url.path, "originalName": url.lastPathComponent, "contentType": type, "byteCount": (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0]
    }
    static func upsert(_ context: NativeRepositoryContext, table: String, values: [String: Any]) throws {
        let keys = values.keys.sorted(), updates = keys.filter { $0 != "id" }.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        try context.run("INSERT INTO \(table)(\(keys.joined(separator: ","))) VALUES(\(keys.map { _ in "?" }.joined(separator: ","))) ON CONFLICT(id) DO UPDATE SET \(updates)", keys.map { values[$0]! })
    }
}
