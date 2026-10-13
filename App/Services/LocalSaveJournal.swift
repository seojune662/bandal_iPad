import Foundation
import BandalCore

/// A completed editor/Pencil callback first leaves a durable file. SQLite's
/// receipt makes replay idempotent even if termination occurs after DB commit.
@MainActor
final class LocalSaveJournal {
    struct RecoveryNotice: LocalizedError {
        let count: Int
        var errorDescription: String? { "지원하지 않는 편집 기록 \(count)개를 Recovery 폴더에 보관하고 나머지를 복구했습니다." }
    }
    struct Entry: Codable {
        var mutationID: String
        var id: String
        var kind: String
        var payload: Data
    }
    let directory: URL
    private var sequence: UInt64
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sequence = try FileManager.default.contentsOfDirectory(atPath: directory.path).compactMap { UInt64($0.split(separator: "-").first ?? "") }.max() ?? 0
    }
    func append(id: String, kind: String, payload: Data) throws -> (Entry, URL) {
        sequence += 1
        let entry = Entry(mutationID: UUID().uuidString, id: id, kind: kind, payload: payload)
        let file = directory.appendingPathComponent(String(format: "%020llu", sequence) + "-" + entry.mutationID + ".json")
        try JSONEncoder().encode(entry).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
        return (entry, file)
    }
    func recover(into store: RecordStore) async throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var quarantined = 0
        for file in files {
            do {
                let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
                _ = try await store.applyLocalJournalEntry(mutationID: entry.mutationID, id: entry.id, kind: entry.kind, payload: entry.payload)
                try FileManager.default.removeItem(at: file)
            } catch {
                let invalid: Bool
                if let core = error as? CoreError { switch core { case .invalidRecord, .unsupportedVersion: invalid = true; default: invalid = false } }
                else { invalid = error is DecodingError }
                guard invalid else { throw error }
                let recovery = directory.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true)
                try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: file, to: recovery.appendingPathComponent("pending-\(UUID().uuidString).json"))
                quarantined += 1
            }
        }
        if quarantined > 0 { throw RecoveryNotice(count: quarantined) }
    }
}
