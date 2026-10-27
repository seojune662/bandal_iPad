import Foundation

struct NativeCourse: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var color: String
    var workspaceKind: String? = nil
    var groupId: String? = nil
    var missing: Bool? = nil
}

struct NativeMaterial: Codable, Hashable, Identifiable {
    var relPath: String
    var name: String
    var kind: String
    var children: [NativeMaterial]?
    var size: Int?
    var mtime: Double?
    var learningTarget: NativeLearningDocumentTarget? = nil

    var id: String { learningTarget?.id ?? relPath }
    var isDirectory: Bool { kind == "dir" }

    func document(in courseID: String) -> NativeDocumentReference {
        if let learningTarget { return learningTarget.document(title: name) }
        return NativeDocumentReference(courseID: courseID, relativePath: relPath, title: name, kind: kind)
    }
}

struct NativeDocumentReference: Codable, Hashable, Identifiable {
    var courseID: String
    var relativePath: String
    var title: String
    var kind: String
    /// A tab instance is optional so older workspaces keep their original IDs.
    /// Storage calls must use the canonical course/path, never this identifier.
    var instanceID: String? = nil
    var learningTarget: NativeLearningDocumentTarget? = nil

    var storageID: String { learningTarget?.id ?? courseID + ":" + relativePath }
    var id: String { instanceID.map { "instance:" + $0 } ?? storageID }
    /// Each supported renderer separates shared resource data from panel state.
    /// A file extension on a project root is never used to infer its renderer.
    var supportsDuplicate: Bool {
        if learningTarget != nil { return true }
        if ["pdf", "note", "whiteboard", "learning", "browser", "recordings", "planner", "audio", "video"].contains(kind) { return true }
        return ["md", "markdown", "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac"].contains((relativePath as NSString).pathExtension.lowercased())
    }
    func duplicated() -> NativeDocumentReference {
        var copy = self; copy.instanceID = UUID().uuidString.lowercased()
        // Tool scopes are sessions, not files. Reusing a browser scope would
        // attach two independent panels to the same live WKWebView.
        if isWorkspaceTool { copy.relativePath = UUID().uuidString.lowercased() }
        return copy
    }
}

/// The repository event payload is deliberately retained. PDF and note editors
/// subscribe to the same durable repositories as the library, without a web view.
struct NativeWorkspaceEvent {
    let channel: String
    let payload: Any
}
