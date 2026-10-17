import Foundation

struct NativeSidebarCourse: Decodable, Identifiable {
    let id: String
    let name: String
    let color: String
    let workspaceKind: String?
    let groupId: String?
    let missing: Bool?
}

struct NativeSidebarCourseGroup: Decodable, Identifiable {
    let id: String
    let name: String
}

struct NativeSidebarFavorite: Identifiable {
    let id: String
    let courseID: String?
    let label: String
    let descriptor: [String: Any]
    var kind: String { descriptor["kind"] as? String ?? "file" }
    var payload: [String: Any] { descriptor["payload"] as? [String: Any] ?? [:] }
    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, let label = row["label"] as? String,
              let descriptor = row["descriptor"] as? [String: Any], descriptor["kind"] is String else { return nil }
        self.id = id; self.label = label; self.descriptor = descriptor; courseID = row["courseId"] as? String
    }
}

enum NativeSidebarDescriptor {
    static func materialKind(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "pdf": "pdf"
        case "md", "markdown": "note"
        case "mp4", "mov", "m4v": "video"
        case "mp3", "m4a", "wav", "aac": "audio"
        case "png", "jpg", "jpeg", "gif", "webp": "image"
        default: "file"
        }
    }
    static func document(_ document: NativeDocumentReference, browserURL: String? = nil, conversationID: String? = nil, recordingID: String? = nil) -> [String: Any]? {
        var kind = document.kind
        var payload: [String: Any] = ["courseId": document.courseID, "relPath": document.relativePath]
        switch kind {
        case "browser":
            guard let browserURL, let url = URL(string: browserURL), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            payload = ["tabId": document.relativePath, "initialUrl": browserURL]
        case "assistant": kind = "chat"; payload = ["courseId": document.courseID]; if let conversationID { payload["conversationId"] = conversationID }
        case "planner": kind = "board"; payload = [:]
        case "recordings": kind = "recording"; payload = ["courseId": document.courseID]; if let recordingID { payload["recordingId"] = recordingID }
        case "whiteboard": payload = ["courseId": document.courseID, "boardId": document.relativePath]
        case "learning-home": kind = "learning"; payload = ["courseId": document.courseID]
        case "learning": payload = ["courseId": document.courseID, "rootRelPath": document.relativePath]
        case "pdf", "note", "image": break
        default: kind = "file"
        }
        return ["kind": kind, "payload": payload]
    }
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "browser": "globe"
        case "pdf": "doc.richtext"
        case "note": "doc.text"
        case "whiteboard": "rectangle.and.pencil.and.ellipsis"
        case "learning": "book"
        case "chat", "assistant": "sparkle"
        case "recording", "recordings": "waveform"
        case "board", "planner": "rectangle.split.3x1"
        default: "doc"
        }
    }
}

struct NativeAIWebShortcut: Identifiable {
    let id: String
    let title: String
    let url: String
    let hosts: Set<String>
    let symbol: String
    static let all: [Self] = [
        .init(id: "chatgpt", title: "ChatGPT", url: "https://chatgpt.com/", hosts: ["chatgpt.com", "chat.openai.com"], symbol: "circle.hexagongrid"),
        .init(id: "gemini", title: "Gemini", url: "https://gemini.google.com/app", hosts: ["gemini.google.com"], symbol: "sparkles"),
        .init(id: "claude", title: "Claude", url: "https://claude.ai/new", hosts: ["claude.ai"], symbol: "sun.max")
    ]
}
