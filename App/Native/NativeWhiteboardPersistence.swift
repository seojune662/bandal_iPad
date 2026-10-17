import Foundation

/// Ordered write-ahead operations for the canonical whiteboard rows. A late
/// estimated-property correction replaces its pending version without letting
/// an earlier in-flight acknowledgement remove the corrected durable record.
@MainActor
final class NativeWhiteboardPersistence {
    typealias Invoke = (String, [String: Any]) async throws -> Any
    private let boardID: String, courseID: String, recovery: NativePDFEditRecovery, invoke: Invoke
    private var pending: [String: [String: Any]] = [:], order: [String] = []
    private var worker: Task<Void, Error>?
    private var sequence = Date().timeIntervalSince1970 * 1_000_000
    var onChange: (() async throws -> Void)?
    var pendingCount: Int { order.count }
    var pendingRecords: [[String: Any]] { order.compactMap { pending[$0] } }
    init(root: URL, courseID: String, boardID: String, invoke: @escaping Invoke) throws {
        self.boardID = boardID; self.courseID = courseID; self.invoke = invoke
        recovery = try NativePDFEditRecovery(root: root, courseID: courseID, relativePath: "whiteboard:" + boardID)
        for record in try recovery.records().sorted(by: { ($0["sequence"] as? Double ?? 0) < ($1["sequence"] as? Double ?? 0) }) {
            guard record["boardId"] as? String == boardID, record["courseId"] as? String == courseID, let id = record["recoveryId"] as? String, record["commands"] is [[String: Any]] else { throw NativePDFError.invalid("노트 복구 기록의 문서가 다릅니다.") }
            pending[id] = record; order.append(id); sequence = max(sequence, record["sequence"] as? Double ?? 0)
        }
    }
    func enqueue(id: String = UUID().uuidString, commands: [[String: Any]]) throws {
        sequence += 1
        let old = pending[id]
        let record: [String: Any] = ["recoveryId": id, "boardId": boardID, "courseId": courseID, "sequence": old?["sequence"] ?? sequence, "version": (old?["version"] as? Int ?? 0) + 1, "commands": commands]
        try recovery.save(record)
        if old == nil { order.append(id) }; pending[id] = record
    }
    func drain() async throws {
        if let worker { try await worker.value; if !order.isEmpty { try await drain() }; return }
        let task = Task { @MainActor in
            defer { self.worker = nil }
            while let id = self.order.first, let record = self.pending[id], let commands = record["commands"] as? [[String: Any]] {
                for command in commands {
                    guard let channel = command["channel"] as? String, ["canvas:putShape", "canvas:removeShapes"].contains(channel), var input = command["request"] as? [String: Any] else { throw NativePDFError.invalid("노트 복구 작업이 올바르지 않습니다.") }
                    input["boardId"] = self.boardID; input["courseId"] = self.courseID
                    _ = try await self.invoke(channel, input)
                }
                if self.pending[id]?["version"] as? Int == record["version"] as? Int {
                    try await self.onChange?()
                    guard self.pending[id]?["version"] as? Int == record["version"] as? Int else { continue }
                    try self.recovery.remove(record); self.pending.removeValue(forKey: id); self.order.removeFirst()
                }
            }
        }
        worker = task; try await task.value
    }
}
