import Foundation
import CryptoKit
import Darwin

/// A small write-ahead log for native erasures and undo/redo. Measured strokes
/// continue to use NativePDFJournal. Recovery never overwrites the PDF file.
final class NativePDFEditRecovery {
    private let directory: URL
    init(root: URL, courseID: String, relativePath: String) throws {
        let key = SHA256.hash(data: Data((courseID + "\u{0}" + relativePath).utf8)).map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent("PendingNativePDFEdits", isDirectory: true).appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func records() throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
                guard let value = try DesktopJSON.decode(Data(contentsOf: $0)) as? [String: Any] else {
                    throw NativePDFError.invalid("보관된 PDF 편집 작업을 읽지 못했습니다.")
                }
                return value
            }
    }
    func save(_ record: [String: Any]) throws {
        let target = try url(record)
        let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try bytes.write(to: target, options: .atomic)
        let file = try FileHandle(forWritingTo: target)
        defer { try? file.close() }
        try file.synchronize(); try syncDirectory()
    }
    func remove(_ record: [String: Any]) throws {
        let target = try url(record)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try syncDirectory()
    }
    private func url(_ record: [String: Any]) throws -> URL {
        guard let id = record["recoveryId"] as? String, UUID(uuidString: id) != nil else {
            throw NativePDFError.invalid("PDF 편집 복구 식별자를 확인하지 못했습니다.")
        }
        return directory.appendingPathComponent(id + ".json")
    }
    private func syncDirectory() throws {
        let fd = Darwin.open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Swift owner of the canonical drawing queue. Native input, erasure, history,
/// and close barriers all enter this owner, independently of view lifetime.
@MainActor
final class NativePDFPersistence {
    typealias Invoke = (String, [String: Any]) async throws -> Any
    private final class HistoryAction {
        let kind: String
        var expected: [[String: Any]]?
        let rows: [[String: Any]]
        var recovery: [String: Any]?
        var creationMutationIDs: [String]?
        init(_ kind: String, rows: [[String: Any]]) { self.kind = kind; self.rows = rows }
    }
    private struct PendingHistory { let action: HistoryAction; let direction: Int }
    private struct HistoryCheckpoint {
        let fingerprint: Data
        let protectedIDs: Set<String>
        let undo: [HistoryAction], redo: [HistoryAction]
        let aliases: [String: String]
        let createdAt: Date
        let byteCount: Int
    }
    private static var checkpoints: [String: HistoryCheckpoint] = [:]

    // Only a fully committed in-process editing session is transferable. The
    // current canonical rows must still match before undo can act on them.
    static let historyLimit = 200
    func checkpointHistory(root: URL) {
        // ponytail: the oldest undo steps leave once the stack exceeds the limit; raise if users miss them.
        if undoStack.count > Self.historyLimit { undoStack.removeFirst(undoStack.count - Self.historyLimit) }
        if redoStack.count > Self.historyLimit { redoStack.removeFirst(redoStack.count - Self.historyLimit) }
        let protectedIDs = Set((undoStack + redoStack).flatMap { $0.rows.compactMap { $0["id"] as? String }.map(resolve) })
        guard pendingCount == 0, pendingHistory == nil, historyFlight == nil,
              let bytes = try? historyContent(ids: protectedIDs),
              let historyBytes = try? JSONSerialization.data(withJSONObject: (undoStack + redoStack).map { $0.rows }, options: [.sortedKeys]) else { return }
        let key = historyKey(root: root), size = bytes.count + historyBytes.count
        guard size <= 20 * 1024 * 1024 else { Self.checkpoints.removeValue(forKey: key); return }
        Self.checkpoints[key] = HistoryCheckpoint(fingerprint: Data(SHA256.hash(data: bytes)), protectedIDs: protectedIDs,
            undo: undoStack.map { HistoryAction($0.kind, rows: $0.rows) },
            redo: redoStack.map { HistoryAction($0.kind, rows: $0.rows) }, aliases: aliases,
            createdAt: Date(), byteCount: size)
        while Self.checkpoints.count > 24 || Self.checkpoints.values.reduce(0, { $0 + $1.byteCount }) > 20 * 1024 * 1024 {
            guard let oldest = Self.checkpoints.min(by: { $0.value.createdAt < $1.value.createdAt })?.key else { break }
            Self.checkpoints.removeValue(forKey: oldest)
        }
    }
    func restoreHistory(root: URL) {
        let saved = Self.checkpoints.removeValue(forKey: historyKey(root: root))
        guard let saved, undoStack.isEmpty, redoStack.isEmpty, pendingCount == 0,
              let bytes = try? historyContent(ids: saved.protectedIDs), Data(SHA256.hash(data: bytes)) == saved.fingerprint else { return }
        undoStack = saved.undo; redoStack = saved.redo; aliases = saved.aliases
    }
    func invalidateHistory(root: URL) { Self.checkpoints.removeValue(forKey: historyKey(root: root)) }
    private func historyKey(root: URL) -> String {
        root.standardizedFileURL.path + "\u{0}" + courseID + "\u{0}" + relativePath + "\u{0}" + documentRevision + "\u{0}" + instanceID
    }
    private func historyContent(ids: Set<String>) throws -> Data {
        func sorted(_ rows: [[String: Any]]) -> [[String: Any]] { rows.filter { ids.contains($0["id"] as? String ?? "") }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") } }
        return try JSONSerialization.data(withJSONObject: ["drawings": sorted(rows), "annotations": sorted(annotations)], options: [.sortedKeys])
    }
    let courseID: String, relativePath: String, documentRevision: String
    private let backend: Invoke, host: Invoke
    private let recovery: NativePDFEditRecovery?
    private let coordinator: NativePDFFileCoordinator?
    private let instanceID: String
    var onPeerChanged: ((Set<String>) -> Void)?
    private var peerEditRejected = false
    private var uncertainStroke = false
    private var peerDrawingVersion = 0, peerAnnotationVersion = 0
    var hasUnsettledEdits: Bool { pendingHistory?.action.recovery != nil || !eraseRecords.isEmpty || uncertainStroke }
    var onRowsChanged: (() async throws -> Void)?
    private(set) var rows: [[String: Any]] = []
    private(set) var annotations: [[String: Any]] = []
    var onAnnotationsChanged: (() async throws -> Void)?
    private var mutations: [String: String] = [:]
    private var completedMutations: Set<String> = []
    private var recordedMutations: Set<String> = []
    private var eraseRecords: [String: [String: Any]] = [:]
    private var eraseHistoryRecorded: Set<String> = []
    private var aliases: [String: String] = [:]
    private var undoStack: [HistoryAction] = [], redoStack: [HistoryAction] = []
    private var pendingHistory: PendingHistory?
    private var operations: [Int: [String: Any]] = [:]
    private var operationFingerprints: [Int: Data] = [:]
    private(set) var completedSequence = 0
    private var draining: Task<Void, Error>?
    private var historyFlight: Task<Void, Error>?
    private struct CreationFlight { let input: [String: Any]; let task: Task<[String: Any], Error> }
    private var creationFlights: [String: CreationFlight] = [:]
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var pendingCount: Int { operations.count + (pendingHistory == nil ? 0 : 1) }

    init(courseID: String, relativePath: String, documentRevision: String,
         recovery: NativePDFEditRecovery? = nil, coordinator: NativePDFFileCoordinator? = nil, instanceID: String = "",
         backend: @escaping Invoke, host: @escaping Invoke) {
        self.courseID = courseID; self.relativePath = relativePath; self.documentRevision = documentRevision
        self.recovery = recovery; self.coordinator = coordinator; self.instanceID = instanceID
        self.backend = backend; self.host = host
        coordinator?.register(self)
    }
    private func serial<T>(_ action: () async throws -> T) async throws -> T {
        if let coordinator { return try await coordinator.perform(owner: self, action) }
        return try await action()
    }
    /// Peer writes do not become this pane's undo actions. Only history that
    /// touches a changed object is invalidated; unrelated local strokes remain.
    func receivePeerSnapshot(drawings: [[String: Any]]?, annotations incomingAnnotations: [[String: Any]]?) {
        func changed(_ before: [[String: Any]], _ after: [[String: Any]]) -> Set<String> {
            let old = Dictionary(before.compactMap { row in (row["id"] as? String).map { ($0, row) } }, uniquingKeysWith: { _, new in new })
            let new = Dictionary(after.compactMap { row in (row["id"] as? String).map { ($0, row) } }, uniquingKeysWith: { _, new in new })
            return Set(old.keys).union(new.keys).filter { id in
                guard let a = old[id], let b = new[id] else { return true }
                return !(a as NSDictionary).isEqual(to: b)
            }
        }
        let drawingIDs = drawings.map { changed(rows, $0) } ?? []
        let annotationIDs = incomingAnnotations.map { changed(annotations, $0) } ?? []
        func conflicts(_ action: HistoryAction) -> Bool {
            let affected = action.kind.hasPrefix("annotation") ? annotationIDs : drawingIDs
            return action.rows.contains { ($0["id"] as? String).map { affected.contains(resolve($0)) } == true }
        }
        undoStack.removeAll(where: conflicts); redoStack.removeAll(where: conflicts)
        if let pending = pendingHistory, pending.action.recovery == nil, conflicts(pending.action) {
            pendingHistory = nil; peerEditRejected = true
        }
        if let drawings { peerDrawingVersion += 1; rows = drawings }
        if let incomingAnnotations { peerAnnotationVersion += 1; annotations = incomingAnnotations }
        onPeerChanged?(drawingIDs.union(annotationIDs))
    }
    func reload() async throws {
        let version = peerDrawingVersion
        guard let value = try await backend("drawings:listForFile", identity) as? [[String: Any]] else {
            throw NativePDFError.invalid("PDF 필기 목록을 확인하지 못했습니다.")
        }
        if version == peerDrawingVersion { rows = value }
    }
    func reloadAnnotations() async throws {
        let version = peerAnnotationVersion
        guard let value = try await backend("annotations:listForFile", identity) as? [[String: Any]] else {
            throw NativePDFError.invalid("PDF 주석 목록을 확인하지 못했습니다.")
        }
        if version == peerAnnotationVersion { annotations = value }
    }
    /// Called before exposing a reopened surface. Each create keeps its UUID
    /// across uncertain replies; delete recovery checks the current live IDs.
    func recoverEdits() async throws {
        try await serial { try await self.recoverEditsUnlocked() }
    }
    private func recoverEditsUnlocked() async throws {
        let records = try recovery?.records() ?? []
        for record in records {
            try validateRecovery(record)
            _ = try await applyRecovery(record)
            try recovery?.remove(record)
        }
        try await reload()
        if coordinator != nil, records.contains(where: { ($0["kind"] as? String)?.hasPrefix("annotation") == true }) {
            try await reloadAnnotations(); coordinator?.publish(from: self, annotations: annotations)
        }
        coordinator?.publish(from: self, drawings: rows)
    }
    func recoverStrokes(_ values: [[String: Any]]) async throws {
        for input in values { try await commitStroke(input) }
    }
    /// Host journal completion can arrive after a later erase. Sequence gaps
    /// are retained until the earlier durable completion is supplied by flush.
    func accept(_ value: [String: Any], type: String) throws {
        guard let sequence = value["operationSequence"] as? Int, sequence > 0,
              ["stroke", "eraseCommit"].contains(type), value["documentRevision"] as? String == documentRevision else {
            throw NativePDFError.invalid("PDF 편집 작업의 순서를 확인하지 못했습니다.")
        }
        var payload = value; payload["type"] = type
        let fingerprint = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])))
        if let old = operationFingerprints[sequence], old != fingerprint {
            throw NativePDFError.invalid("같은 PDF 편집 순서에 다른 내용이 있습니다.")
        }
        operationFingerprints[sequence] = fingerprint
        if sequence > completedSequence { operations[sequence] = payload }
    }
    func drain(through sequence: Int? = nil) async throws {
        while draining != nil || operations[completedSequence + 1] != nil {
            let task: Task<Void, Error>
            if let draining { task = draining }
            else {
                task = Task { @MainActor in
                    defer { self.draining = nil }
                    while let input = self.operations[self.completedSequence + 1] {
                        if input["type"] as? String == "stroke" { try await self.commitStroke(input) }
                        else { try await self.commitErase(input) }
                        self.completedSequence += 1
                        self.operations.removeValue(forKey: self.completedSequence)
                    }
                }
                draining = task
            }
            try await task.value
        }
        if let sequence, completedSequence < sequence {
            throw NativePDFError.invalid("앞선 PDF 편집의 저장을 기다리고 있습니다. 다시 저장해 주세요.")
        }
        if pendingHistory != nil { try await finishPendingHistory() }
    }
    func undo() async throws { try await runHistory(undo: true) }
    func redo() async throws { try await runHistory(undo: false) }
    /// Shape/text/selection edits enter the same durable owner as native ink.
    /// Creating an object uses a stable receipt; updating multiple selected
    /// objects keeps their pre-edit values until the whole action completes.
    func createObjects(_ values: [[String: Any]]) async throws { try await edit("restore", values) }
    /// One UI creation owns one receipt token, even when another pane creates
    /// an identical textbox. Retries never infer ownership from row contents.
    func createObject(_ value: [String: Any], mutationID: String) async throws -> [String: Any] {
        guard UUID(uuidString: mutationID) != nil else { throw NativePDFError.invalid("개체 생성 식별자를 확인하지 못했습니다.") }
        if let course = value["courseId"] as? String, course != courseID { throw NativePDFError.invalid("다른 문서의 개체를 생성할 수 없습니다.") }
        if let path = value["relPath"] as? String, path != relativePath { throw NativePDFError.invalid("다른 문서의 개체를 생성할 수 없습니다.") }
        var input = identity
        for key in ["page", "kind", "data", "style"] { input[key] = value[key] }
        input["clientMutationId"] = mutationID; input["documentRevision"] = documentRevision
        if let flight = creationFlights[mutationID] {
            guard (flight.input as NSDictionary).isEqual(to: input) else { throw NativePDFError.invalid("같은 개체 생성에 다른 내용이 있습니다.") }
            return try await flight.task.value
        }
        let task = Task { @MainActor in
            try await self.drain()
            func status() async throws -> [String: Any] {
                guard let result = try await self.backend("drawings:mutationStatus", input) as? [String: Any] else {
                    throw NativePDFError.invalid("개체의 저장 영수증을 확인하지 못했습니다.")
                }
                return result
            }
            var result = try await status()
            if result["status"] as? String == "missing" {
                try await self.edit("restore", [value], creationMutationIDs: [mutationID])
                result = try await status()
            }
            guard result["status"] as? String == "live", let row = result["drawing"] as? [String: Any],
                  row["id"] as? String == result["drawingId"] as? String,
                  row["courseId"] as? String == self.courseID, row["relPath"] as? String == self.relativePath else {
                throw NativePDFError.invalid("이 개체는 이미 변경되거나 삭제되었습니다. 최신 문서를 확인해 주세요.")
            }
            return row
        }
        creationFlights[mutationID] = CreationFlight(input: input, task: task)
        defer { creationFlights.removeValue(forKey: mutationID) }
        return try await task.value
    }
    func updateObjects(_ values: [[String: Any]], expected: [[String: Any]]? = nil) async throws { try await edit("update", values, expected: expected) }
    func deleteObjects(ids: Set<String>) async throws {
        try await reload()
        try await edit("delete", rows.filter { ids.contains($0["id"] as? String ?? "") })
    }
    func createAnnotation(_ value: [String: Any]) async throws { try await edit("annotationRestore", [value]) }
    func updateAnnotation(_ value: [String: Any], expected: [String: Any]? = nil) async throws { try await edit("annotationUpdate", [value], expected: expected.map { [$0] }) }
    func deleteAnnotation(id: String) async throws {
        try await reloadAnnotations()
        try await edit("annotationDelete", annotations.filter { $0["id"] as? String == id })
    }
    private func edit(_ kind: String, _ values: [[String: Any]], expected original: [[String: Any]]? = nil, creationMutationIDs: [String]? = nil) async throws {
        let ids = Set(values.compactMap { $0["id"] as? String })
        let expected = (kind.hasPrefix("annotation") ? annotations : rows).filter { ids.contains($0["id"] as? String ?? "") }
        try await drain()
        guard pendingHistory == nil, !values.isEmpty else { return }
        for value in values {
            if let course = value["courseId"] as? String, course != courseID { throw NativePDFError.invalid("다른 문서의 개체를 편집할 수 없습니다.") }
            if let path = value["relPath"] as? String, path != relativePath { throw NativePDFError.invalid("다른 문서의 개체를 편집할 수 없습니다.") }
        }
        let action = HistoryAction(kind, rows: values)
        action.creationMutationIDs = creationMutationIDs
        if ["update", "annotationUpdate", "delete", "annotationDelete"].contains(kind) { action.expected = original ?? expected }
        pendingHistory = PendingHistory(action: action, direction: 0)
        try await finishPendingHistory()
    }
    private var identity: [String: Any] { ["courseId": courseID, "relPath": relativePath] }
    private func resolve(_ id: String) -> String {
        var value = id, visited = Set<String>()
        while let next = aliases[value], visited.insert(value).inserted { value = next }
        return value
    }
    /// Splices a receipt row into `rows` in listDrawings order (page ASC,
    /// created_at ASC; equal keys append). False when the row cannot be placed,
    /// so the caller re-reads the document instead.
    private func upsertRow(_ row: [String: Any]) -> Bool {
        guard let id = row["id"] as? String, let page = (row["page"] as? NSNumber)?.intValue, let created = row["createdAt"] as? String else { return false }
        rows.removeAll { $0["id"] as? String == id }
        // ponytail: O(document) scan over two keys with no I/O; bisect if rows exceed ~10k.
        let index = rows.firstIndex { other in
            let otherPage = (other["page"] as? NSNumber)?.intValue ?? Int.max
            return otherPage > page || (otherPage == page && (other["createdAt"] as? String ?? "") > created)
        } ?? rows.endIndex
        rows.insert(row, at: index); return true
    }
    private func commitStroke(_ raw: [String: Any]) async throws {
        try await serial { try await self.commitStrokeUnlocked(raw) }
    }
    private func commitStrokeUnlocked(_ raw: [String: Any]) async throws {
        var input = raw; input.removeValue(forKey: "type"); input.removeValue(forKey: "operationSequence")
        let heldShape = try input.removeValue(forKey: "heldShape").map { value in
            let shape = try JSONDecoder().decode(NativePDFHeldShape.self, from: JSONSerialization.data(withJSONObject: value))
            guard shape.isValid else { throw NativePDFError.invalid("보정할 도형을 확인하지 못했습니다.") }
            return shape
        }
        guard input["courseId"] as? String == courseID, input["relPath"] as? String == relativePath,
              input["documentRevision"] as? String == documentRevision,
              let mutation = input["clientMutationId"] as? String, UUID(uuidString: mutation) != nil else {
            throw NativePDFError.invalid("다른 문서의 필기를 저장할 수 없습니다.")
        }
        var needsReload = true
        if !completedMutations.contains(mutation) {
            uncertainStroke = true
            let peerVersion = peerDrawingVersion
            let result = try await host("mutationStatus", ["input": input]) as? [String: Any]
            let id: String
            var undoRow: [String: Any]?
            var shapeUndoRow: [String: Any]?
            var isLive = true
            if result?["status"] as? String == "missing" {
                guard let created = try await backend("drawings:create", input) as? [String: Any],
                      let createdID = created["id"] as? String else { throw NativePDFError.invalid("필기가 저장되지 않았습니다.") }
                id = createdID
                undoRow = created
                // The receipt is the canonical row: splice it in instead of
                // re-reading and re-parsing every stroke of the document.
                needsReload = !(peerVersion == peerDrawingVersion && upsertRow(created))
            } else if ["live", "deleted"].contains(result?["status"] as? String ?? ""), let saved = result?["drawingId"] as? String {
                id = saved
                isLive = result?["status"] as? String == "live"
                if result?["status"] as? String == "live", !recordedMutations.contains(mutation) {
                    // The database may have committed before its response was
                    // lost. That retry still contributes exactly one undo step.
                    try await reload()
                    undoRow = rows.first { $0["id"] as? String == saved }
                }
            } else { throw NativePDFError.invalid("필기의 저장 영수증을 확인하지 못했습니다.") }
            if let heldShape, isLive {
                var replacement = identity
                let fit = input["kind"] as? String == "highlighter" ? heldShape.inkPayload : heldShape.payload
                replacement.merge(["id": id, "operationId": mutation, "documentRevision": documentRevision,
                    "expected": input, "kind": input["kind"] as? String == "highlighter" ? "highlighter" : fit["kind"]!,
                    "data": fit["data"]!, "style": heldShape.shapeStyle(input["style"] as? [String: Any] ?? [:])]) { _, new in new }
                guard let result = try await backend("drawings:replace", replacement) as? [String: Any],
                      let before = result["before"] as? [String: Any], let after = result["after"] as? [String: Any] else {
                    throw NativePDFError.invalid("도형 보정의 저장 영수증을 확인하지 못했습니다.")
                }
                // Receipt replay proves that the correction committed, not
                // that this old edit still owns the current canonical row.
                // Sync can update a closed document before its journal opens.
                if !needsReload, let created = undoRow, (before as NSDictionary).isEqual(to: created), upsertRow(after) {
                    // The replace receipt proves it acted on the row just inserted.
                    undoRow = before; shapeUndoRow = before
                } else {
                    needsReload = true
                    try await reload()
                    if let current = rows.first(where: { $0["id"] as? String == id }), (current as NSDictionary).isEqual(to: after) {
                        undoRow = before; shapeUndoRow = before
                    } else {
                        undoRow = nil; shapeUndoRow = nil
                        func touchesCurrent(_ action: HistoryAction) -> Bool {
                            !action.kind.hasPrefix("annotation") && action.rows.contains { ($0["id"] as? String).map(resolve) == id }
                        }
                        undoStack.removeAll(where: touchesCurrent); redoStack.removeAll(where: touchesCurrent)
                    }
                }
            }
            if let undoRow, recordedMutations.insert(mutation).inserted {
                undoStack.append(HistoryAction("delete", rows: [undoRow]))
                if let shapeUndoRow { undoStack.append(HistoryAction("replace", rows: [shapeUndoRow])) }
                redoStack.removeAll()
            }
            mutations[mutation] = id
            _ = try await host("ack", ["clientMutationId": mutation, "drawingId": id])
            completedMutations.insert(mutation)
        }
        if needsReload { try await reload() }
        uncertainStroke = false
        coordinator?.publish(from: self, drawings: rows); try await onRowsChanged?()
    }
    private func commitErase(_ input: [String: Any]) async throws {
        try await serial { try await self.commitEraseUnlocked(input) }
    }
    private func commitEraseUnlocked(_ input: [String: Any]) async throws {
        guard let operationID = input["operationId"] as? String,
              let targets = input["targets"] as? [[String: Any]], !targets.isEmpty else {
            throw NativePDFError.invalid("지울 필기를 확인하지 못했습니다.")
        }
        var resolved: [[String: Any]] = []
        for target in targets {
            var value = target
            if let mutation = target["clientMutationId"] as? String {
                guard let id = mutations[mutation], target["drawingId"] == nil || target["drawingId"] as? String == id else {
                    throw NativePDFError.invalid("앞선 필기 저장 후 지우기를 다시 시도해 주세요.")
                }
                value["drawingId"] = id
            }
            guard value["drawingId"] is String else { throw NativePDFError.invalid("지울 필기 식별자가 없습니다.") }
            resolved.append(value)
        }
        if eraseRecords[operationID] == nil {
            try await reload()
            let ids = Set(resolved.compactMap { $0["drawingId"] as? String }.map(resolve))
            let removed = rows.filter { ($0["id"] as? String).map(ids.contains) == true }
            let record = makeRecovery(kind: "delete", rows: removed)
            eraseRecords[operationID] = record
        }
        let record = eraseRecords[operationID]!
        try recovery?.save(record)
        _ = try await applyRecovery(record)
        if eraseHistoryRecorded.insert(operationID).inserted, let removed = record["rows"] as? [[String: Any]], !removed.isEmpty {
            undoStack.append(HistoryAction("restore", rows: removed)); redoStack.removeAll()
        }
        var proof = input; proof.removeValue(forKey: "type"); proof.removeValue(forKey: "targets")
        proof["outcome"] = "committed"; proof["resolvedTargets"] = resolved
        let reply = try await host("eraseResult", proof) as? [String: Any]
        guard reply?["operationId"] as? String == operationID, reply?["outcome"] as? String == "committed" else {
            throw NativePDFError.invalid("지우기 저장 완료를 확인하지 못했습니다.")
        }
        try await reload(); try await onRowsChanged?()
        try recovery?.remove(record); eraseRecords.removeValue(forKey: operationID)
        coordinator?.publish(from: self, drawings: rows)
    }
    private func runHistory(undo: Bool) async throws {
        try await drain()
        guard pendingHistory == nil, let action = (undo ? undoStack : redoStack).last else { return }
        pendingHistory = PendingHistory(action: action, direction: undo ? -1 : 1)
        try await finishPendingHistory()
    }
    private func finishPendingHistory() async throws {
        if let historyFlight { try await historyFlight.value; return }
        let task = Task { @MainActor in try await self.applyPendingHistory() }
        historyFlight = task
        do { try await task.value; historyFlight = nil }
        catch { historyFlight = nil; throw error }
    }
    private func applyPendingHistory() async throws {
        try await serial { try await self.applyPendingHistoryUnlocked() }
    }
    private func applyPendingHistoryUnlocked() async throws {
        if peerEditRejected { peerEditRejected = false; throw NativePDFError.invalid("다른 PDF 창에서 이 개체를 변경했습니다. 최신 내용을 확인하고 다시 편집해 주세요.") }
        guard let pending = pendingHistory else { return }
        let action = pending.action
        if action.recovery == nil {
            if action.kind.hasPrefix("annotation") { try await reloadAnnotations() } else { try await reload() }
            let sourceRows = action.kind.hasPrefix("annotation") ? annotations : rows
            if let expected = action.expected {
                let ids = Set(action.rows.compactMap { $0["id"] as? String }.map(resolve))
                let actual = sourceRows.filter { ids.contains($0["id"] as? String ?? "") }
                guard actual.count == expected.count, expected.allSatisfy({ old in
                    actual.contains { current in (old as NSDictionary).isEqual(to: current) }
                }) else {
                    pendingHistory = nil
                    throw NativePDFError.invalid("다른 PDF 창에서 이 개체를 변경했습니다. 최신 내용을 확인하고 다시 편집해 주세요.")
                }
            }
            let selected: [[String: Any]]
            if ["delete", "annotationDelete"].contains(action.kind) {
                let ids = Set(action.rows.compactMap { $0["id"] as? String }.map(resolve))
                selected = sourceRows.filter { ($0["id"] as? String).map(ids.contains) == true }
            } else if ["update", "replace", "annotationUpdate"].contains(action.kind) {
                selected = action.rows.map { row in
                    var value = row
                    if let id = row["id"] as? String { value["id"] = resolve(id) }
                    return value
                }
            } else { selected = action.rows }
            let record = makeRecovery(kind: action.kind, rows: selected, creationMutationIDs: action.creationMutationIDs)
            action.recovery = record
        }
        let record = action.recovery!
        try recovery?.save(record)
        let changed = try await applyRecovery(record)
        if action.kind.hasPrefix("annotation") { try await reloadAnnotations(); try await onAnnotationsChanged?() }
        else { try await reload(); try await onRowsChanged?() }
        try recovery?.remove(record)
        let inverseKind = ["replace": "replace", "update": "update", "delete": "restore", "restore": "delete", "annotationUpdate": "annotationUpdate", "annotationDelete": "annotationRestore", "annotationRestore": "annotationDelete"][action.kind]!
        let inverse = HistoryAction(inverseKind, rows: changed)
        if pending.direction == -1 { undoStack.removeLast(); redoStack.append(inverse) }
        else if pending.direction == 1 { redoStack.removeLast(); undoStack.append(inverse) }
        else { undoStack.append(inverse); redoStack.removeAll() }
        pendingHistory = nil
        if action.kind.hasPrefix("annotation") { coordinator?.publish(from: self, annotations: annotations) }
        else { coordinator?.publish(from: self, drawings: rows) }
    }
    private func makeRecovery(kind: String, rows: [[String: Any]], creationMutationIDs: [String]? = nil) -> [String: Any] {
        var result: [String: Any] = ["version": 1, "recoveryId": UUID().uuidString,
            "courseId": courseID, "relPath": relativePath, "documentRevision": documentRevision, "kind": kind, "rows": rows]
        if ["restore", "annotationRestore"].contains(kind) {
            result["inputs"] = rows.enumerated().map { index, row -> [String: Any] in
                var input = identity
                for key in kind == "annotationRestore" ? ["page", "color", "rects", "anchor", "comment"] : ["page", "kind", "data", "style"] { input[key] = row[key] }
                input["clientMutationId"] = creationMutationIDs?[index] ?? UUID().uuidString; input["documentRevision"] = documentRevision
                return input
            }
        } else if ["update", "replace", "annotationUpdate"].contains(kind) {
            let ids = Set(rows.compactMap { $0["id"] as? String })
            result["before"] = (kind == "annotationUpdate" ? annotations : self.rows).filter { ids.contains($0["id"] as? String ?? "") }
            if kind == "replace" { result["replacementIDs"] = rows.map { _ in UUID().uuidString } }
        }
        return result
    }
    private func validateRecovery(_ record: [String: Any]) throws {
        guard record["version"] as? Int == 1, record["courseId"] as? String == courseID,
              record["relPath"] as? String == relativePath, record["documentRevision"] as? String == documentRevision,
              ["delete", "restore", "update", "replace", "annotationDelete", "annotationRestore", "annotationUpdate"].contains(record["kind"] as? String ?? ""), record["rows"] is [[String: Any]] else {
            throw NativePDFError.invalid("PDF 원본이 바뀌어 이전 편집 작업을 보존했습니다. 원본을 복구한 후 다시 열어 주세요.")
        }
    }
    private func applyRecovery(_ record: [String: Any]) async throws -> [[String: Any]] {
        try validateRecovery(record)
        let original = record["rows"] as! [[String: Any]]
        if (record["kind"] as? String)?.hasPrefix("annotation") == true { return try await applyAnnotationRecovery(record, rows: original) }
        if record["kind"] as? String == "replace" {
            guard let before = record["before"] as? [[String: Any]], let operations = record["replacementIDs"] as? [String],
                  before.count == original.count, operations.count == original.count else {
                throw NativePDFError.invalid("도형 보정의 원본 복구 기록을 확인하지 못했습니다.")
            }
            for (target, operation) in zip(original, operations) {
                guard let id = target["id"] as? String, let expected = before.first(where: { $0["id"] as? String == id }),
                      let kind = target["kind"], let data = target["data"], let style = target["style"] else {
                    throw NativePDFError.invalid("도형 보정의 복구 대상을 확인하지 못했습니다.")
                }
                var request = identity
                request.merge(["id": id, "operationId": operation, "documentRevision": documentRevision,
                    "expected": expected, "kind": kind, "data": data, "style": style]) { _, new in new }
                _ = try await backend("drawings:replace", request)
            }
            return before
        }
        if record["kind"] as? String == "update" {
            guard let before = record["before"] as? [[String: Any]], before.count == original.count,
                  Set(before.compactMap { $0["id"] as? String }) == Set(original.compactMap { $0["id"] as? String }) else {
                throw NativePDFError.invalid("개체 편집의 원본 복구 기록을 확인하지 못했습니다.")
            }
            for value in original {
                guard let id = value["id"] as? String, let data = value["data"], let style = value["style"] else { throw NativePDFError.invalid("PDF 개체 편집이 올바르지 않습니다.") }
                _ = try await backend("drawings:update", ["id": id, "data": data, "style": style])
            }
            return before
        }
        if record["kind"] as? String == "delete" {
            try await reload()
            let live = Set(rows.compactMap { $0["id"] as? String })
            let ids = original.compactMap { $0["id"] as? String }.filter(live.contains)
            if !ids.isEmpty {
                do { _ = try await backend("drawings:delete", ["ids": ids]) }
                catch {
                    let failure = error
                    try await reload()
                    let remaining = Set(rows.compactMap { $0["id"] as? String })
                    if ids.contains(where: remaining.contains) { throw failure }
                }
            }
            return original
        }
        guard let inputs = record["inputs"] as? [[String: Any]], inputs.count == original.count else {
            throw NativePDFError.invalid("되돌릴 필기의 복구 기록을 확인하지 못했습니다.")
        }
        var restored: [[String: Any]] = []
        for (row, input) in zip(original, inputs) {
            guard let value = try await backend("drawings:create", input) as? [String: Any], let id = value["id"] as? String else {
                throw NativePDFError.invalid("필기를 복원하지 못했습니다.")
            }
            if let previous = row["id"] as? String { aliases[previous] = id }
            restored.append(value)
        }
        return restored
    }
    private func applyAnnotationRecovery(_ record: [String: Any], rows: [[String: Any]]) async throws -> [[String: Any]] {
        switch record["kind"] as? String {
        case "annotationUpdate":
            guard let before = record["before"] as? [[String: Any]], before.count == rows.count,
                  Set(before.compactMap { $0["id"] as? String }) == Set(rows.compactMap { $0["id"] as? String }) else {
                throw NativePDFError.invalid("PDF 주석의 복구 기록을 확인하지 못했습니다.")
            }
            for value in rows {
                guard let id = value["id"] as? String, let color = value["color"] else { throw NativePDFError.invalid("PDF 주석을 확인하지 못했습니다.") }
                _ = try await backend("annotations:update", ["id": id, "color": color, "comment": value["comment"] ?? NSNull()])
            }
            return before
        case "annotationDelete":
            try await reloadAnnotations()
            let live = Set(annotations.compactMap { $0["id"] as? String })
            for id in rows.compactMap({ $0["id"] as? String }) where live.contains(id) {
                do { _ = try await backend("annotations:delete", ["id": id]) }
                catch {
                    let failure = error; try await reloadAnnotations()
                    if annotations.contains(where: { $0["id"] as? String == id }) { throw failure }
                }
            }
            return rows
        case "annotationRestore":
            guard let inputs = record["inputs"] as? [[String: Any]], inputs.count == rows.count else { throw NativePDFError.invalid("PDF 주석 복원을 확인하지 못했습니다.") }
            var restored: [[String: Any]] = []
            for (old, input) in zip(rows, inputs) {
                guard let row = try await backend("annotations:create", input) as? [String: Any], let id = row["id"] as? String else { throw NativePDFError.invalid("PDF 주석을 저장하지 못했습니다.") }
                if let oldID = old["id"] as? String { aliases[oldID] = id }
                restored.append(row)
            }
            return restored
        default: throw NativePDFError.invalid("PDF 주석 작업을 확인하지 못했습니다.")
        }
    }

}
