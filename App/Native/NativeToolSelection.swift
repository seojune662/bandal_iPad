import Foundation

/// A dock tab identifies a workspace; its current conversation or recording is
/// separate state. Favorites must capture that content identity, not the tab UUID.
enum NativeToolSelection {
    static func conversationURL(workspaceID: String, root: URL) -> URL {
        let scope = Data(workspaceID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return root.appendingPathComponent("NativeToolState/assistant-\(scope).json")
    }

    static func conversationID(workspaceID: String, root: URL) -> String? {
        guard let data = try? Data(contentsOf: conversationURL(workspaceID: workspaceID, root: root)),
              let id = try? JSONDecoder().decode(String.self, from: data), !id.isEmpty else { return nil }
        return id
    }

    static func restoreConversation(_ id: String, workspaceID: String, root: URL) throws {
        let url = conversationURL(workspaceID: workspaceID, root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(id).write(to: url, options: .atomic)
    }

    static func recordingKey(workspaceID: String?, courseID: String?) -> String {
        "native.recording.selection." + (workspaceID ?? "global") + "." + (courseID ?? "none")
    }

    static func recordingID(workspaceID: String, courseID: String, defaults: UserDefaults = .standard) -> String? {
        guard let id = defaults.string(forKey: recordingKey(workspaceID: workspaceID, courseID: courseID)), !id.isEmpty else { return nil }
        return id
    }

    static func restoreRecording(_ id: String, workspaceID: String, courseID: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: recordingKey(workspaceID: workspaceID, courseID: courseID))
    }
}
