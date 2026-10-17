import Foundation
import UIKit
import UniformTypeIdentifiers
import BandalCore

struct DesktopSyncIdentity: Equatable, Sendable {
    let userID: String
    let projectURL: URL
    let publishableKey: String
}

typealias DesktopSyncTransport = SyncTransport & AssetTransport

@MainActor
struct DesktopSyncEnvironment {
    var transport: (DesktopSyncIdentity, @escaping @Sendable () async throws -> String) throws -> any DesktopSyncTransport = { identity, token in
        try SupabaseSyncTransport(projectURL: identity.projectURL, publishableKey: identity.publishableKey, userID: identity.userID, accessToken: token)
    }
    /// Failure injection also exercises the actual durable cursor/record store,
    /// rather than replacing the materialization stage with an in-memory mock.
    var checkpoint: (String) async throws -> Void = { _ in }
}

/// The desktop repositories stay authoritative. Their canonical projection is
/// committed to a durable operation queue before any network request. Assets
/// are immutable snapshots, uploaded before records can refer to their hashes.
@MainActor
final class DesktopSyncService {
    var emit: ((String, Any) -> Void)?
    var flushOpenDocuments: (() async throws -> Void)?
    var mutateOpenDocuments: ((@escaping @MainActor () async throws -> Any) async throws -> Any)?
    private let runtime: DesktopRuntime
    private let account: DesktopAccountService
    private let environment: DesktopSyncEnvironment
    private let store: RecordStore
    private let assets: AssetStore
    private let directory: URL
    private var active: Task<Void, Error>?
    private var activeID: UUID?
    private var timer: Timer?
    private var foreground: NSObjectProtocol?
    private var generation = 0
    private var restoring = false
    private var uploaded = Set<String>()
    private var state: [String: Any] = ["phase": "idle", "conflicts": 0]

    init(runtime: DesktopRuntime, account: DesktopAccountService, environment: DesktopSyncEnvironment? = nil) throws {
        self.runtime = runtime; self.account = account
        self.environment = environment ?? DesktopSyncEnvironment()
        directory = runtime.root.appendingPathComponent("CommonSync", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try RecordStore(url: directory.appendingPathComponent("bandal.sqlite"))
        assets = try AssetStore(directory: directory.appendingPathComponent("Assets", isDirectory: true))
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestSync() }
        }
        foreground = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestSync() }
        }
        requestSync()
    }

    func stop() async {
        timer?.invalidate(); timer = nil
        if let foreground { NotificationCenter.default.removeObserver(foreground); self.foreground = nil }
        generation += 1
        let previous = active; previous?.cancel()
        _ = try? await previous?.value
    }

    func accountChanged(_ event: [String: Any]) {
        if event["phase"] as? String == "signed-in" { requestSync(); return }
        // Keep the cancelled task until it has drained. A returning account
        // must not race an old engine's final durable acknowledgement/import.
        generation += 1; active?.cancel(); uploaded.removeAll()
        publish(["phase": "idle", "conflicts": state["conflicts"] ?? 0])
    }

    func requestSync() {
        guard active == nil, !restoring else { return }
        Task { [weak self] in try? await self?.synchronizeNow() }
    }

    func synchronizeNow() async throws {
        guard !restoring else { throw DesktopRuntimeError("충돌 사본을 적용하는 동안 동기화를 기다립니다.") }
        if let active { return try await active.value }
        let expected = generation
        let identifier = UUID(); activeID = identifier
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.activeID == identifier { self.active = nil; self.activeID = nil } }
            do { try await self.synchronize(expected: expected) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if expected == self.generation {
                    self.publish(["phase": "waiting", "error": error.localizedDescription, "conflicts": self.state["conflicts"] ?? 0])
                }
                throw error
            }
        }
        active = task
        try await task.value
    }

    private func publish(_ next: [String: Any]) {
        state = next; emit?("runtime:syncChanged", next)
    }

    func status() async throws -> [String: Any] {
        var current = state
        current["conflicts"] = try await conflicts().count
        current["pending"] = try await store.pendingOperations(limit: 1000).count
        return current
    }

    func conflicts() async throws -> [[String: Any]] {
        guard let values = try await runtime.invokePrivate("nativeSync:conflicts") as? [[String: Any]] else {
            throw DesktopRuntimeError("동기화 충돌 사본을 읽지 못했습니다.")
        }
        return values
    }

    func exportConflict(_ id: String) async throws -> [String: Any] {
        guard let conflict = try await conflicts().first(where: { $0["id"] as? String == id }) else {
            throw DesktopRuntimeError("동기화 충돌 사본을 찾지 못했습니다.")
        }
        let data = try JSONSerialization.data(withJSONObject: conflict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return ["suggestedName": "반달 동기화 충돌.json", "data": data.base64EncodedString()]
    }

    /// Stop the current exchange before resolving. The projector retains both
    /// versions and any edits made while the conflict was being reviewed.
    func restoreConflict(_ id: String, variant: String) async throws -> [String: Any] {
        guard !restoring, ["local", "remote"].contains(variant) else { throw DesktopRuntimeError("적용할 충돌 사본을 확인해 주세요.") }
        restoring = true
        generation += 1
        let previous = active; previous?.cancel()
        _ = try? await previous?.value
        defer { restoring = false; requestSync() }
        try await flushOpenDocuments?()
        guard let conflict = try await conflicts().first(where: { $0["id"] as? String == id }),
              let selected = conflict[variant] as? [String: Any] else {
            throw DesktopRuntimeError("적용할 충돌 사본을 찾지 못했습니다.")
        }
        // The exchange downloads conflict assets before publishing them. An
        // offline restore is possible only after validating every local byte.
        let record = try Self.record(selected)
        var localAssets: [[String: Any]] = []
        for revision in try Self.references(record) {
            var url = try await assets.url(for: revision)
            if !FileManager.default.fileExists(atPath: url.path),
               let preserved = (conflict["assets"] as? [[String: Any]])?.first(where: { $0["sha256"] as? String == revision.sha256 }),
               let path = preserved["path"] as? String {
                let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                let expected = runtime.root.appendingPathComponent("SyncConflictAssets").standardizedFileURL.resolvingSymlinksInPath()
                guard candidate.path.hasPrefix(expected.path + "/") else { throw CoreError.assetIntegrity }
                url = candidate
            }
            try AssetHasher.verify(revision, file: url)
            _ = try await assets.importFile(at: url, matching: revision)
            localAssets.append(["sha256": revision.sha256, "path": url.path])
        }
        // Persist the explicit choice before changing the projector baseline.
        // Otherwise a pending-import replay could undo this choice on restart.
        let reviewed = try ["local", "remote"].compactMap { conflict[$0] as? [String: Any] }.map(Self.record)
        if let preserved = try await store.queueConflictResolution(record, reviewedVariants: reviewed) {
            _ = try await runtime.invokePrivate("nativeSync:import", request: ["records": [], "assets": localAssets,
                "conflicts": [["id": preserved.id, "local": try Self.envelope(preserved.local), "remote": try Self.envelope(preserved.remote)]]])
        }
        let result = try await applyToWorkspace { [self] in
            try await runtime.invokePrivate("nativeSync:restoreConflict", request: ["conflictID": id, "variant": variant, "assets": localAssets])
        } as? [String: Any] ?? [:]
        guard (result["applied"] as? NSNumber)?.intValue == 1 else { throw DesktopRuntimeError("선택한 사본을 적용하지 못했습니다. 충돌 사본은 보관되어 있습니다.") }
        try await environment.checkpoint("afterConflictMaterialization")
        let next = try await status()
        publish(next.merging(["phase": "idle"]) { _, new in new })
        return ["ok": true]
    }

    private func check(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == generation else { throw CancellationError() }
    }

    private func synchronize(expected: Int) async throws {
        let identity = try await account.syncIdentity()
        try check(expected)
        try await store.bindSyncAccount(userID: identity.userID)
        try await store.prepareProjectionRecovery()
        try check(expected)
        publish(["phase": "syncing", "conflicts": state["conflicts"] ?? 0])
        let transport = try environment.transport(identity) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.token(identity: identity, expected: expected)
        }
        // An interrupted exchange may already have advanced the durable cursor
        // while the authoritative desktop documents still show the old bytes.
        // Recover BEFORE export updates the projector's comparison baseline.
        if try await store.projectionRecoveryPending() {
            try await materialize(transport: transport, expected: expected)
        }
        try await flushOpenDocuments?()
        try check(expected)
        let snapshot = try await runtime.invokePrivate("nativeSync:export") as? [String: Any] ?? [:]
        guard let rawRecords = snapshot["records"] as? [[String: Any]], let rawAssets = snapshot["assets"] as? [[String: Any]] else {
            throw DesktopRuntimeError("동기화할 자료 목록을 확인하지 못했습니다.")
        }
        // Copy mutable source files before queueing references. An edit during
        // copying fails integrity verification and is retried on the next run.
        for entry in rawAssets {
            try check(expected)
            let revision = try Self.asset(entry)
            guard let path = entry["path"] as? String else { throw DesktopRuntimeError("동기화 원본 경로가 없습니다.") }
            let source = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let root = runtime.root.standardizedFileURL.resolvingSymlinksInPath()
            guard source.path.hasPrefix(root.path + "/") || DesktopFileAccess.shared(root: runtime.root).allows(source) else {
                throw DesktopRuntimeError("동기화 원본 경로에 접근할 수 없습니다.")
            }
            let copy = try await assets.importFile(at: source, matching: revision)
            guard copy.sha256 == revision.sha256, copy.byteCount == revision.byteCount else { throw CoreError.assetIntegrity }
        }
        var changed: [StoredRecord] = []
        for raw in rawRecords {
            let record = try Self.record(raw)
            let current = try await store.get(id: record.id)
            if let current, current.kind == record.kind, current.deleted == record.deleted,
               current.formatVersion == record.formatVersion,
               try Self.canonical(current.payload) == Self.canonical(record.payload) { continue }
            changed.append(record)
        }
        try check(expected)
        if !changed.isEmpty { _ = try await store.importLocalRecords(changed) }
        // Refreshes and sign-out are checked before every request by the token
        // supplier. The transport also checks the JWT subject against userID.
        var required: [String: AssetRevision] = [:]
        for operation in try await store.pendingOperations(limit: 1000) {
            for revision in try Self.references(operation.record) { required[revision.sha256] = revision }
        }
        for revision in required.values where !uploaded.contains(revision.sha256) {
            try check(expected)
            try await assets.upload(revision, transport: transport)
            try check(expected); uploaded.insert(revision.sha256)
        }
        try await store.beginProjectionRecovery()
        try check(expected)
        let engine = SyncEngine(store: store, transport: transport)
        let report = try await withTaskCancellationHandler(operation: { try await engine.synchronize() }, onCancel: { Task { await engine.cancel() } })
        try check(expected)
        try await environment.checkpoint("afterExchange")
        try await materialize(transport: transport, expected: expected)
        let conflictCount = try await self.conflicts().count
        publish(["phase": "idle", "conflicts": conflictCount, "pushed": report.pushed, "pulled": report.pulled,
                 "lastSyncedAt": ISO8601DateFormatter().string(from: Date())])
    }

    private func materialize(transport: any AssetTransport, expected: Int) async throws {
        try check(expected)
        let records = try await store.list(includeDeleted: true)
        let conflicts = try await store.conflicts()
        var downloaded: [String: String] = [:]
        for record in records + conflicts.flatMap({ [$0.local, $0.remote] }) {
            for revision in try Self.references(record) where downloaded[revision.sha256] == nil {
                try check(expected)
                let url = try await assets.ensureAvailable(revision, transport: transport)
                try check(expected); downloaded[revision.sha256] = url.path
            }
        }
        let result = try await applyToWorkspace { [self] in
            try check(expected)
            return try await runtime.invokePrivate("nativeSync:import", request: [
                "records": try records.map(Self.envelope),
                "assets": downloaded.map { ["sha256": $0.key, "path": $0.value] },
                "conflicts": try conflicts.map { ["id": $0.id, "local": try Self.envelope($0.local), "remote": try Self.envelope($0.remote)] }
            ])
        } as? [String: Any]
        guard let applied = result?["applied"] as? Int, let conflicts = result?["conflicts"] as? [Any],
              applied + conflicts.count == records.count else {
            throw DesktopRuntimeError("동기화 자료의 적용 결과를 확인하지 못했습니다. 복구 기록을 유지합니다.")
        }
        try check(expected)
        try await environment.checkpoint("afterMaterialization")
        try check(expected)
        try await store.completeProjectionRecovery()
    }

    private func applyToWorkspace(_ action: @escaping @MainActor () async throws -> Any) async throws -> Any {
        if let mutateOpenDocuments { return try await mutateOpenDocuments(action) }
        try await flushOpenDocuments?()
        return try await action()
    }

    private func token(identity: DesktopSyncIdentity, expected: Int) async throws -> String {
        try check(expected)
        guard try await account.syncIdentity() == identity else { throw CancellationError() }
        let token = try await account.accessToken()
        try check(expected)
        return token
    }

    static func canonical(_ data: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func record(_ raw: [String: Any]) throws -> StoredRecord {
        guard let id = raw["id"] as? String, let kind = raw["kind"] as? String,
              SyncPolicy.allowedKinds.contains(kind), let payload = raw["payload"] as? [String: Any] else {
            throw DesktopRuntimeError("동기화 기록 형식을 확인할 수 없습니다.")
        }
        return StoredRecord(id: id, kind: kind, payload: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
                            revision: raw["revision"] as? Int ?? 1, deleted: raw["deleted"] as? Bool ?? false, formatVersion: raw["formatVersion"] as? Int ?? 1)
    }

    static func envelope(_ value: StoredRecord) throws -> [String: Any] {
        ["id": value.id, "kind": value.kind, "payload": try JSONSerialization.jsonObject(with: value.payload),
         "revision": value.revision, "deleted": value.deleted, "formatVersion": value.formatVersion]
    }

    static func asset(_ raw: [String: Any]) throws -> AssetRevision {
        guard let hash = raw["sha256"] as? String, hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }),
              let count = raw["byteCount"] as? NSNumber, count.int64Value >= 0,
              let name = raw["originalName"] as? String, let contentType = raw["contentType"] as? String else { throw CoreError.assetIntegrity }
        return AssetRevision(sha256: hash, byteCount: count.int64Value, originalName: name, contentType: contentType)
    }

    static func reference(_ record: StoredRecord) throws -> AssetRevision? {
        guard !record.deleted, ["material", "recording", "artifact"].contains(record.kind),
              let value = try JSONSerialization.jsonObject(with: record.payload) as? [String: Any] else { return nil }
        if record.kind == "artifact", value["recordType"] as? String != "desktop-learning-file" { return nil }
        if record.kind == "material", value["kind"] as? String == "whiteboard" { return nil }
        guard let hash = value[record.kind == "material" ? "revision" : "assetRevision"] as? String else { return nil }
        guard let count = value["byteCount"] as? NSNumber, let name = value["fileName"] as? String else {
            throw DesktopRuntimeError("자료의 동기화 파일 크기 정보가 없습니다.")
        }
        let type = record.kind == "artifact" ? "application/json" : record.kind == "recording" ? "audio/wav" : UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return try asset(["sha256": hash, "byteCount": count, "originalName": name, "contentType": type])
    }

    static func references(_ record: StoredRecord) throws -> [AssetRevision] {
        if let single = try reference(record) {
            guard record.kind == "material", let value = try JSONSerialization.jsonObject(with: record.payload) as? [String: Any],
                  let desktop = value["desktop"] as? [String: Any], let raw = desktop["pageLineageAssets"] else { return [single] }
            guard value["kind"] as? String == "pdf", let ancestors = raw as? [[String: Any]] else { throw CoreError.assetIntegrity }
            var result = [single], seen = [single.sha256: single.byteCount]
            for input in ancestors {
                let ancestor = try asset(input)
                if let count = seen[ancestor.sha256] {
                    guard count == ancestor.byteCount else { throw CoreError.assetIntegrity }
                } else { seen[ancestor.sha256] = ancestor.byteCount; result.append(ancestor) }
            }
            return result
        }
        guard !record.deleted, record.kind == "artifact",
              let value = try JSONSerialization.jsonObject(with: record.payload) as? [String: Any],
              value["recordType"] as? String == "desktop-learning-project" else { return [] }
        guard let files = value["files"] as? [[String: Any]] else { throw CoreError.assetIntegrity }
        return try files.map { file in
            guard let hash = file["assetRevision"] as? String, let path = file["relPath"] as? String,
                  let count = file["byteCount"] as? NSNumber else { throw CoreError.assetIntegrity }
            return try asset(["sha256": hash, "byteCount": count, "originalName": (path as NSString).lastPathComponent, "contentType": "application/json"])
        }
    }

    deinit {
        timer?.invalidate(); active?.cancel()
        if let foreground { NotificationCenter.default.removeObserver(foreground) }
    }
}
