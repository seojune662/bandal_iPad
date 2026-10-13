import Foundation

/// Normal-session download metadata and opaque WebKit resume data stay local.
/// Paths are relative to this container so an app update can relocate it.
@MainActor
final class BrowserDownloadStore {
    struct Record: Codable {
        let id: String
        let profileID: String
        let courseID: String?
        let fileName: String
        let url: String?
        let destinationLeaf: String?
        let relPath: String?
        let state: String
        let receivedBytes: Int64
        let totalBytes: Int64
        let failureReason: String?
    }
    let root: URL
    private let file: URL
    private(set) var records: [Record]
    init(root: URL) throws {
        self.root = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        file = self.root.appendingPathComponent("index.json")
        records = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode([Record].self, from: Data(contentsOf: file)) : []
        guard records.allSatisfy({ Self.valid($0) }) else { throw DesktopBrowserError.invalid("다운로드 보관 기록") }
    }
    static func valid(_ record: Record) -> Bool {
        UUID(uuidString: record.id) != nil &&
        (record.destinationLeaf.map { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") } ?? true) &&
        ["progressing", "completed", "interrupted", "cancelled"].contains(record.state)
    }
    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func resumeData(_ id: String) -> Data? { try? Data(contentsOf: folder(id).appendingPathComponent(".resume")) }
    func save(_ record: Record, resumeData: Data?) throws {
        guard Self.valid(record) else { throw DesktopBrowserError.invalid("다운로드 보관 기록") }
        try FileManager.default.createDirectory(at: folder(record.id), withIntermediateDirectories: true)
        let resume = folder(record.id).appendingPathComponent(".resume")
        if let resumeData { try resumeData.write(to: resume, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        else if FileManager.default.fileExists(atPath: resume.path) { try FileManager.default.removeItem(at: resume) }
        var next = records.filter { $0.id != record.id }; next.append(record)
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        records = next
    }
    func dismiss(_ id: String) throws {
        let next = records.filter { $0.id != id }
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        records = next
        // Keep downloaded user files; only the interrupted transfer token is removed.
        let resume = folder(id).appendingPathComponent(".resume")
        if FileManager.default.fileExists(atPath: resume.path) { try FileManager.default.removeItem(at: resume) }
    }
    func forgetProfile(_ profile: String) throws {
        for id in records.filter({ $0.profileID == profile }).map(\.id) { try dismiss(id) }
    }
}
