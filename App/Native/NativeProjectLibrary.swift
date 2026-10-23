import SwiftUI

@MainActor
final class NativeProjectLibrary: ObservableObject {
    @Published private(set) var results: [NativeMaterial] = []
    @Published private(set) var scopeID: String?
    private var revision = 0
    func reload(store: NativeWorkspaceStore, scope: NativeWorkspaceContext?) async {
        revision += 1; let request = revision
        if scopeID != scope?.id { results = []; scopeID = scope?.id }
        guard let scope else { results = []; return }
        do {
            if let binding = scope.binding {
                let snapshot = try await store.invoke("learning:get", ["binding": binding.request]) as? [String: Any] ?? [:]
                guard revision == request, !Task.isCancelled else { return }
                results = Self.materials(snapshot: snapshot, scope: scope)
            } else {
                let value = try await store.invoke("learning:list", ["courseId": scope.courseID]) as? [String: Any] ?? [:]
                let projects: [NativeLearningSummary] = try NativeToolJSON.decode(value["projects"] ?? [])
                var output: [NativeMaterial] = []
                for project in projects where project.deletedAt == nil && project.purpose == "course-review" && (project.linkedCourseId ?? project.binding.courseID) == scope.courseID {
                    let snapshot = try await store.invoke("learning:get", ["binding": project.binding.request]) as? [String: Any] ?? [:]
                    guard revision == request, !Task.isCancelled else { return }
                    output += Self.materials(snapshot: snapshot, scope: .project(project, courses: store.courses))
                }
                guard revision == request, !Task.isCancelled else { return }
                results = output
            }
        } catch {
            if revision == request {
                results = []
                // Deleting the selected project triggers a library refresh just
                // before the shell selects its fallback. That is not a failure.
                if (error as? DesktopRuntimeError)?.code != "NOT_FOUND" { store.errorMessage = error.localizedDescription }
            }
        }
    }
    nonisolated static func materials(snapshot: [String: Any], scope: NativeWorkspaceContext) -> [NativeMaterial] {
        guard let binding = scope.binding else { return [] }
        let projectID = scope.projectID ?? snapshot["projectId"] as? String ?? binding.id
        var materials = [("articles", NativeLearningDocumentTarget.Kind.article), ("artifacts", .artifact)].flatMap { key, kind in
            (snapshot[key] as? [[String: Any]] ?? []).compactMap { row -> NativeMaterial? in
                guard let id = row["id"] as? String else { return nil }
                let target = NativeLearningDocumentTarget(projectID: projectID, binding: binding, kind: kind, entityID: id)
                let path = row["relPath"] as? String ?? ".bandal-learning/\(key)/\(id).json"
                let materialKind = kind == .article ? "learning-article" : row["generationMode"] as? String == "expected-exam" ? "learning-exam" : "learning-" + (row["kind"] as? String ?? "summary")
                return NativeMaterial(relPath: binding.rootRelPath.isEmpty ? path : binding.rootRelPath + "/" + path,
                                      name: row["title"] as? String ?? "학습 자료", kind: materialKind, children: nil, size: nil, mtime: nil, learningTarget: target)
            }
        }
        if !(snapshot["words"] as? [Any] ?? []).isEmpty || !(snapshot["history"] as? [Any] ?? []).isEmpty {
            let target = NativeLearningDocumentTarget(projectID: projectID, binding: binding, kind: .overview, entityID: "history")
            materials.append(.init(relPath: binding.rootRelPath, name: "표현·학습 기록", kind: "learning-overview", learningTarget: target))
        }
        return materials
    }
}

struct NativeLibraryBrowsingState: Codable, Equatable {
    var folder: String
    var query: String
    var expanded: Set<String>
    static func load(scopeID: String, root: String, defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "native.library.scope." + scopeID),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              root.isEmpty || value.folder == root || value.folder.hasPrefix(root + "/") else { return .init(folder: root, query: "", expanded: []) }
        return value
    }
    func save(scopeID: String, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "native.library.scope." + scopeID) }
    }
}

struct NativeScopedMaterialMovePicker: View {
    let material: NativeMaterial
    let scope: NativeWorkspaceContext
    @ObservedObject var store: NativeWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    private var folders: [NativeMaterial] {
        NativeLibraryIndex.flatten(store.materials).filter { $0.isDirectory && scope.contains(path: $0.relPath) && $0.relPath != scope.rootRelPath && $0.relPath != material.relPath && !$0.relPath.hasPrefix(material.relPath + "/") }
    }
    var body: some View {
        NavigationStack {
            List {
                if let error { NativeToolError(message: error) }
                Button(scope.title, systemImage: "folder") { move(scope.rootRelPath) }
                ForEach(folders) { folder in Button(folder.name, systemImage: "folder") { move(folder.relPath) } }
            }.disabled(busy).navigationTitle("이동할 폴더").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(busy) } }
        }
    }
    private func move(_ folder: String) {
        guard scope.contains(path: folder), store.selectedCourseID == scope.courseID else { return }
        busy = true
        Task { defer { busy = false }; do { try await store.move(material, to: folder); dismiss() } catch { self.error = error.localizedDescription } }
    }
}
