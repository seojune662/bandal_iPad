import Combine
import Foundation

/// One durable queue and canonical row snapshot per profile/document. Individual
/// canvases own only their viewport, input tool and undo history.
@MainActor
final class NativeWhiteboardSession {
    let writer: NativeWhiteboardPersistence
    let changes = PassthroughSubject<Void, Never>()
    private(set) var rows: [[String: Any]] = []
    private(set) var board: [String: Any] = [:]
    private(set) var pageGeometries: [String: [String: Any]] = [:]
    private(set) var retired = false
    private let invoke: NativeWhiteboardPersistence.Invoke
    private let identity: [String: Any]
    private var opening: Task<Void, Error>?
    private var readRevision = 0
    private let metadataWrites = NativeCourseRefreshQueue()
    private var removedIDs = Set<String>()

    init(root: URL, courseID: String, boardID: String, invoke: @escaping NativeWhiteboardPersistence.Invoke) throws {
        self.invoke = invoke; identity = ["courseId": courseID, "boardId": boardID]
        writer = try NativeWhiteboardPersistence(root: root, courseID: courseID, boardID: boardID, invoke: invoke)
        writer.onChange = { [weak self] in try await self?.reload() }
    }
    func open() async throws {
        if let opening { try await opening.value; return }
        let task = Task { @MainActor in try await self.drain(); try await self.reload() }
        opening = task
        do { try await task.value; opening = nil } catch { opening = nil; throw error }
    }
    func reload() async throws {
        guard !retired else { return }
        readRevision += 1; let revision = readRevision
        guard let result = try await invoke("canvas:open", identity) as? [String: Any],
              let rows = result["shapes"] as? [[String: Any]], let board = result["board"] as? [String: Any] else {
            throw NativePDFError.invalid("노트를 읽지 못했습니다.")
        }
        guard !retired, readRevision == revision else { return }
        self.rows = rows; self.board = board
        pageGeometries = result["pageGeometries"] as? [String: [String: Any]] ?? [:]
        changes.send()
    }
    func enqueue(id: String = UUID().uuidString, commands: [[String: Any]]) throws {
        guard !retired else { throw NativePDFError.invalid("노트 저장 연결이 닫혔습니다.") }
        try writer.enqueue(id: id, commands: commands)
        for command in commands {
            guard let request = command["request"] as? [String: Any] else { continue }
            if command["channel"] as? String == "canvas:removeShapes" { removedIDs.formUnion(request["ids"] as? [String] ?? []) }
            else if request["restore"] as? Bool == true, let id = request["id"] as? String { removedIDs.remove(id) }
        }
        changes.send()
    }
    func drain() async throws { try await writer.drain(); changes.send() }
    func addPage() async throws {
        try await metadataWrites.run { [self] in
            try await drain()
            _ = try await invoke("canvas:setPageCount", identity.merging(["pageCount": (board["pageCount"] as? Int ?? 1) + 1]) { _, new in new })
            try await reload()
        }
    }
    func retire() { retired = true; readRevision += 1 }
    var visibleRows: [[String: Any]] {
        var result = rows
        for record in writer.pendingRecords {
            for command in record["commands"] as? [[String: Any]] ?? [] {
                guard let request = command["request"] as? [String: Any] else { continue }
                if command["channel"] as? String == "canvas:removeShapes", let ids = request["ids"] as? [String] {
                    result.removeAll { ids.contains($0["id"] as? String ?? "") }
                } else if let id = request["id"] as? String, var shape = request["shape"] as? [String: Any] {
                    if removedIDs.contains(id), request["restore"] as? Bool != true { continue }
                    result.removeAll { $0["id"] as? String == id }
                    shape["id"] = id; shape["page"] = request["page"] ?? 1; result.append(shape)
                }
            }
        }
        return result
    }
}

@MainActor
final class NativeWhiteboardSessionRegistry {
    private var sessions: [String: NativeWhiteboardSession] = [:]
    func session(root: URL, document: NativeDocumentReference, invoke: @escaping NativeWhiteboardPersistence.Invoke) throws -> NativeWhiteboardSession {
        if let current = sessions[document.storageID], !current.retired { return current }
        let created = try NativeWhiteboardSession(root: root, courseID: document.courseID, boardID: document.relativePath, invoke: invoke)
        sessions[document.storageID] = created
        return created
    }
}

/// Undo is local to a pane and conditional on the exact post-edit objects. A
/// peer edit must never be silently removed or resurrected by stale history.
struct NativeWhiteboardHistoryEntry {
    let commands: [[String: Any]]
    let expected: [String: String]
    init(commands: [[String: Any]], rows: [[String: Any]]) {
        self.commands = commands
        let ids = Set(commands.flatMap { command -> [String] in
            guard let request = command["request"] as? [String: Any] else { return [] }
            return request["ids"] as? [String] ?? (request["id"] as? String).map { [$0] } ?? []
        })
        expected = Dictionary(uniqueKeysWithValues: ids.map { id in (id, Self.fingerprint(rows.first { $0["id"] as? String == id })) })
    }
    func matches(_ rows: [[String: Any]]) -> Bool {
        expected.allSatisfy { id, value in Self.fingerprint(rows.first { $0["id"] as? String == id }) == value }
    }
    private static func fingerprint(_ row: [String: Any]?) -> String {
        guard let row else { return "missing" }
        let value = ["id", "page", "kind", "data", "style"].reduce(into: [String: Any]()) { result, key in result[key] = row[key] }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { $0.base64EncodedString() } ?? "invalid"
    }
}
