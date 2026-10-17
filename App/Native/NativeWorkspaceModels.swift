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

    var id: String { relPath }
    var isDirectory: Bool { kind == "dir" }

    func document(in courseID: String) -> NativeDocumentReference {
        NativeDocumentReference(courseID: courseID, relativePath: relPath, title: name, kind: kind)
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

    var storageID: String { courseID + ":" + relativePath }
    var id: String { instanceID.map { "instance:" + $0 } ?? storageID }
    var supportsDuplicate: Bool { kind == "pdf" || kind == "note" || ["md", "markdown"].contains((relativePath as NSString).pathExtension.lowercased()) }
    func duplicated() -> NativeDocumentReference {
        var copy = self; copy.instanceID = UUID().uuidString.lowercased(); return copy
    }
}

/// The repository event payload is deliberately retained. PDF and note editors
/// subscribe to the same durable repositories as the library, without a web view.
struct NativeWorkspaceEvent {
    let channel: String
    let payload: Any
}
