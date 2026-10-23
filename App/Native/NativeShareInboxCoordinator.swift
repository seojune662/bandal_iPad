import Foundation

@MainActor
final class NativeShareInboxCoordinator {
    struct Report {
        var importedCount = 0
        var failures: [String] = []
    }
    private var synchronizing = false
    private var publishing = false
    private var catalogNeedsRefresh = false

    /// Call after store.start() and whenever the scene becomes active. A failed
    /// batch remains intact for retry, including files already imported safely.
    func synchronize(using store: NativeWorkspaceStore) async -> Report {
        guard store.isReady, !synchronizing, let inbox = BandalShareInbox.connected() else { return Report() }
        synchronizing = true
        defer { synchronizing = false }
        var report = Report()
        do {
            let workspaceID = try Self.workspaceID(root: store.root)
            let batches = try await Task.detached(priority: .utility) { try inbox.batches() }.value
            for batch in batches where batch.workspaceID == workspaceID {
                do {
                    for item in batch.items {
                        let source = try inbox.payloadURL(item, batchID: batch.id)
                        let value = try await store.invoke("materials:importShared", ["courseId": batch.courseID,
                            "dirRelPath": batch.folderPath, "sourcePath": source.path, "fileName": item.fileName, "shareID": item.id])
                        guard let result = value as? [String: Any], result["relPath"] is String else {
                            throw BandalShareInbox.Failure(message: "공유 자료 가져오기 결과를 확인하지 못했습니다.")
                        }
                        if result["alreadyImported"] as? Bool != true { report.importedCount += 1 }
                    }
                    try await Task.detached(priority: .utility) { try inbox.removeCompleted(batch) }.value
                } catch {
                    report.failures.append("공유 자료를 가져오지 못했습니다. 원본은 공유 보관함에 남아 있습니다: \(error.localizedDescription)")
                }
            }
            if report.importedCount > 0 { await store.refreshMaterials() }
            try await publishCatalog(using: store)
        } catch { report.failures.append(error.localizedDescription) }
        return report
    }

    /// Refresh when courses/folders change. No main-app folder paths are exposed
    /// to the extension, and profile switches receive a distinct workspace ID.
    func publishCatalog(using store: NativeWorkspaceStore) async throws {
        guard store.isReady, let inbox = BandalShareInbox.connected() else { return }
        if publishing { catalogNeedsRefresh = true; return }
        publishing = true
        defer { publishing = false }
        repeat {
            catalogNeedsRefresh = false
            let workspaceID = try Self.workspaceID(root: store.root)
            let courses: [NativeCourse] = try Self.decode(try await store.invoke("courses:list"))
            var destinations: [BandalShareCatalog.Course] = []
            for course in courses where course.missing != true {
                guard let folders = try await store.invokePrivate("nativeMaterial:folders", ["courseId": course.id]) as? [String],
                      folders.allSatisfy(BandalShareInbox.validRelativeFolder) else {
                    throw BandalShareInbox.Failure(message: "공유할 폴더 목록을 읽지 못했습니다.")
                }
                destinations.append(.init(id: course.id, name: course.name, folders: folders))
            }
            let catalog = BandalShareCatalog(workspaceID: workspaceID, courses: destinations, updatedAt: Date())
            try await Task.detached(priority: .utility) { try inbox.publishCatalog(catalog) }.value
        } while catalogNeedsRefresh && store.isReady
    }

    private static func decode<T: Decodable>(_ value: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private static func workspaceID(root: URL) throws -> String {
        let path = root.appendingPathComponent("share-workspace-id.txt")
        if FileManager.default.fileExists(atPath: path.path) {
            let saved = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: saved) != nil else { throw BandalShareInbox.Failure(message: "공유 보관함의 작업 공간 식별자가 잘못되었습니다.") }
            return saved
        }
        let id = UUID().uuidString.lowercased()
        try Data(id.utf8).write(to: path, options: .atomic)
        return id
    }
}
