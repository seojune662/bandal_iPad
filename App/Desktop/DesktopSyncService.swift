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
    var now: () -> Date = Date.init
    var access: (DesktopSyncIdentity, @escaping @Sendable () async throws -> String) async throws -> SyncAccessStatus = { identity, token in
        try await SupabaseSyncTransport(projectURL: identity.projectURL, publishableKey: identity.publishableKey, userID: identity.userID, accessToken: token).syncStatus()
    }
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
    private var failures = 0
    private var suspended = false
    private let scope = SyncScope.personalContentV1
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
        // The first export walks and hashes every course; let the first screen
        // and any restored document open first.
        Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(5)); self?.requestSync() }
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
        generation += 1; active?.cancel()
        publish(["phase": "idle", "conflicts": state["conflicts"] ?? 0])
    }

    func requestSync(force: Bool = false) {
        guard active == nil, !restoring, !suspended, force || !runtime.isForegroundBusy else { return }
        Task { [weak self] in try? await self?.synchronizeNow(force: force) }
    }

    func suspendForProfileOperation() async {
        suspended = true; generation += 1
        let previous = active; previous?.cancel(); _ = try? await previous?.value
    }
    func resumeAfterProfileOperation() { suspended = false; requestSync() }

    func setEnabled(_ enabled: Bool) async throws -> [String: Any] {
        if enabled { _ = try await account.syncIdentity() }
        try await store.setPreference("syncEnabled", value: enabled ? "true" : "false")
        if !enabled {
            generation += 1; active?.cancel()
            _ = try? await active?.value
            publish(["phase": "disabled", "conflicts": state["conflicts"] ?? 0, "enabled": false])
        } else { requestSync(force: true) }
        return try await status()
    }

    func synchronizeNow(force: Bool = false) async throws {
        guard !suspended else { return }
        guard try await store.preference("syncEnabled") == "true" else {
            publish(["phase": "disabled", "conflicts": state["conflicts"] ?? 0, "enabled": false]); return
        }
        if !force, let raw = try await store.preference("retryAt"), let time = Double(raw), time > environment.now().timeIntervalSince1970 { return }
        guard !restoring else { throw DesktopRuntimeError("충돌 사본을 적용하는 동안 동기화를 기다립니다.") }
        if let active { return try await active.value }
        let expected = generation
        let identifier = UUID(); activeID = identifier
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.activeID == identifier { self.active = nil; self.activeID = nil } }
            do { try await self.synchronize(expected: expected, force: force) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if expected == self.generation {
                    self.failures += 1
                    let delay = (error as? SyncRequestFailure)?.retryAfter ?? min(900, 15 * pow(2, Double(min(self.failures, 6))))
                    let retry = self.environment.now().addingTimeInterval(delay)
                    try? await self.store.setPreference("retryAt", value: String(retry.timeIntervalSince1970))
                    self.publish(["phase": "waiting", "error": error.localizedDescription, "blockedReason": (error as? SyncRequestFailure)?.code.rawValue ?? "network", "retryAt": ISO8601DateFormatter().string(from: retry), "conflicts": self.state["conflicts"] ?? 0])
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
        current["conflicts"] = try await conflictSummaries().count
        current["pending"] = try await store.pendingOperations(limit: 1000, scope: scope).count
        current["enabled"] = try await store.preference("syncEnabled") == "true"
        return current
    }

    /// UI receives bounded previews instead of the complete retained wire records.
    func conflictSummaries() async throws -> [[String: Any]] {
        guard let values = try await runtime.invokePrivate("nativeSync:conflicts", request: ["scope": scope.rawValue, "summary": true]) as? [[String: Any]] else {
            throw DesktopRuntimeError("동기화 충돌 사본을 읽지 못했습니다.")
        }
        return values
    }

    func conflicts() async throws -> [[String: Any]] {
        guard let values = try await runtime.invokePrivate("nativeSync:conflicts", request: ["scope": scope.rawValue]) as? [[String: Any]] else {
            throw DesktopRuntimeError("동기화 충돌 사본을 읽지 못했습니다.")
        }
        return values.filter { value in
            if value["kind"] as? String == "pending-ink" { return true }
            guard let raw = (value["remote"] ?? value["local"]) as? [String: Any], let record = try? Self.record(raw) else { return false }
            return scope.includes(record)
        }
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
        guard let conflict = try await conflicts().first(where: { $0["id"] as? String == id }) else {
            throw DesktopRuntimeError("적용할 충돌 사본을 찾지 못했습니다.")
        }
        if conflict["kind"] as? String == "pending-ink" {
            let result = try await runtime.invokePrivate("nativeSync:restoreConflict", request: ["conflictID": id, "variant": variant, "assets": [], "scope": scope.rawValue]) as? [String: Any] ?? [:]
            guard (result["applied"] as? NSNumber)?.intValue == 1 else { throw DesktopRuntimeError("필기 복구를 완료하지 못했습니다. 원본은 보관되어 있습니다.") }
            return ["ok": true]
        }
        guard let selected = conflict[variant] as? [String: Any] else {
            throw DesktopRuntimeError("적용할 충돌 사본을 찾지 못했습니다.")
        }
        // The exchange downloads conflict assets before publishing them. An
        // offline restore is possible only after validating every local byte.
        let record = try Self.record(selected)
        let related = conflict["related"] as? [String: [[String: Any]]] ?? [:]
        let pageChoices = try (related[variant] ?? []).map(Self.record)
        guard pageChoices.allSatisfy({ scope.includes($0) && ["drawing", "annotation"].contains($0.kind) }) else { throw DesktopRuntimeError("페이지 충돌 사본 형식을 확인하지 못했습니다.") }
        var localAssets: [[String: Any]] = []
        for revision in try ([record] + pageChoices).flatMap(Self.references) {
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
        let relatedReviewed = try ((related["local"] ?? []) + (related["remote"] ?? [])).map(Self.record)
        let choices = [(selected: record, reviewed: reviewed)] + pageChoices.map { page in
            (selected: page, reviewed: relatedReviewed.filter { $0.id == page.id })
        }
        for preserved in try await store.queueConflictResolutions(choices) {
            _ = try await runtime.invokePrivate("nativeSync:import", request: ["records": [], "assets": localAssets,
                "conflicts": [["id": preserved.id, "local": try Self.envelope(preserved.local), "remote": try Self.envelope(preserved.remote)]]])
        }
        let result = try await applyToWorkspace { [self] in
            try await runtime.invokePrivate("nativeSync:restoreConflict", request: ["conflictID": id, "variant": variant, "assets": localAssets, "scope": scope.rawValue])
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

    private func synchronize(expected: Int, force: Bool) async throws {
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
        struct CachedAccess: Codable { let userID: String; let status: SyncAccessStatus; let blocked: SyncFailureCode; let until: Date }
        let cached = try await store.preference("blockedAccess").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(CachedAccess.self, from: $0) }
        let access: SyncAccessStatus
        var blocked: SyncFailureCode?
        if !force, let cached, cached.userID == identity.userID, cached.until > environment.now() {
            access = cached.status; blocked = cached.blocked
        } else {
            access = try await environment.access(identity) { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.token(identity: identity, expected: expected)
            }
            blocked = !access.writeAllowed ? .subscriptionRequired : access.quotaExceeded ? .storageLimitExceeded : nil
        }
        try check(expected)
        // An interrupted exchange may already have advanced the durable cursor
        // while the authoritative desktop documents still show the old bytes.
        // Recover BEFORE export updates the projector's comparison baseline.
        if try await store.projectionRecoveryPending() {
            try await materialize(transport: transport, expected: expected)
        }
        if blocked == nil {
        try await flushOpenDocuments?()
        try check(expected)
        let snapshot = try await runtime.invokePrivate("nativeSync:export", request: ["scope": scope.rawValue]) as? [String: Any] ?? [:]
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
            guard scope.includes(record) else { continue }
            let current = try await store.get(id: record.id)
            if let current, current.kind == record.kind, current.deleted == record.deleted,
               current.formatVersion == record.formatVersion,
               try Self.canonical(current.payload) == Self.canonical(record.payload) { continue }
            changed.append(record)
        }
        try check(expected)
        if !changed.isEmpty { _ = try await store.importLocalRecords(changed) }
        }
        // Refreshes and sign-out are checked before every request by the token
        // supplier. The transport also checks the JWT subject against userID.
        var required: [String: AssetRevision] = [:]
        for operation in try await store.pendingOperations(limit: 1000, scope: scope) {
            for revision in try Self.references(operation.record) { required[revision.sha256] = revision }
        }
        let engine = SyncEngine(store: store, transport: transport)
        var report: SyncReport
        try await store.beginProjectionRecovery()
        do {
            if blocked == nil {
                for revision in required.values {
                    if try await store.assetWasUploaded(revision) { continue }
                    try check(expected)
                    try await assets.upload(revision, transport: transport)
                    try check(expected)
                    try await store.recordUploadedAsset(revision)
                }
            }
            report = try await withTaskCancellationHandler(operation: { try await engine.synchronize(pushAllowed: blocked == nil, scope: scope) }, onCancel: { Task { await engine.cancel() } })
        } catch let error as SyncRequestFailure where error.blocksWrites {
            // A subscription/quota can change after the preflight. Retain every
            // pending operation and still receive the user's existing content.
            blocked = error.code
            report = try await engine.synchronize(pushAllowed: false, scope: scope)
        }
        try check(expected)
        try await environment.checkpoint("afterExchange")
        // Nothing pulled, merged or conflicting: every open editor stays untouched
        // (materialize freezes and reloads them all). The marker set above is cleared.
        if report.pulled > 0 || report.merged > 0 || report.conflicts > 0 {
            try await materialize(transport: transport, expected: expected)
        } else { try await store.completeProjectionRecovery() }
        let conflictCount = try await self.conflicts().count
        failures = 0
        let retry = environment.now().addingTimeInterval(blocked == nil ? 0 : 300)
        try await store.setPreference("retryAt", value: "0")
        if let blocked {
            let nextCheck = !force && cached?.blocked == blocked && cached!.until > environment.now() ? cached!.until : retry
            let saved = CachedAccess(userID: identity.userID, status: access, blocked: blocked, until: nextCheck)
            try await store.setPreference("blockedAccess", value: String(decoding: JSONEncoder().encode(saved), as: UTF8.self))
        } else { try await store.setPreference("blockedAccess", value: "") }
        publish(["phase": blocked == nil ? "idle" : "paused", "conflicts": conflictCount, "pushed": report.pushed, "pulled": report.pulled,
                 "writeAllowed": blocked == nil, "blockedReason": blocked?.rawValue as Any? ?? NSNull(),
                 "storageUsedBytes": access.storageUsedBytes, "storageLimitBytes": access.storageLimitBytes,
                 "retryAt": NSNull(),
                 "lastSyncedAt": ISO8601DateFormatter().string(from: environment.now())])
    }

    private func materialize(transport: any AssetTransport, expected: Int) async throws {
        try check(expected)
        let records = try await store.list(includeDeleted: true).filter { scope.includes($0) }
        let conflicts = try await store.conflicts().filter { scope.includes($0.remote) }
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
                "scope": scope.rawValue,
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
              let count = raw["byteCount"] as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(), count.doubleValue.isFinite, count.int64Value >= 0, Double(count.int64Value) == count.doubleValue,
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
                  let raw = value["pdfLineageAssets"] else { return [single] }
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
        if !record.deleted, record.kind == "chat", let payload = try JSONSerialization.jsonObject(with:record.payload) as? [String: Any],
           payload["recordType"] as? String == "desktop-chat-message" {
            var references: [String: AssetRevision] = [:]
            for block in payload["blocks"] as? [[String: Any]] ?? [] where block["kind"] as? String == "attachment" {
                guard let capture = block["payload"] as? [String: Any], let raw = capture["imageAsset"] as? [String: Any] else { continue }
                let revision = try asset(raw)
                guard references[revision.sha256] == nil || references[revision.sha256]?.byteCount == revision.byteCount else { throw CoreError.assetIntegrity }
                references[revision.sha256] = revision
            }
            return references.values.sorted { $0.sha256 < $1.sha256 }
        }
        if !record.deleted, ["drawing", "annotation"].contains(record.kind),
           let payload = try JSONSerialization.jsonObject(with: record.payload) as? [String: Any], let encoded = payload["data"] as? String {
            guard let bytes = Data(base64Encoded: encoded), let page = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw CoreError.assetIntegrity }
            var references: [String: AssetRevision] = [:]
            for object in page["objects"] as? [[String: Any]] ?? [] {
                guard let data = object["data"] as? [String: Any], let clip = data["clip"] as? [String: Any], let hash = clip["documentRevision"] as? String else { continue }
                guard let count = clip["documentByteCount"] as? NSNumber else { throw CoreError.assetIntegrity }
                let value = try asset(["sha256": hash, "byteCount": count, "originalName": hash + ".pdf", "contentType": "application/pdf"])
                guard references[hash] == nil || references[hash]?.byteCount == value.byteCount else { throw CoreError.assetIntegrity }
                references[hash] = value
            }
            return references.values.sorted { $0.sha256 < $1.sha256 }
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
