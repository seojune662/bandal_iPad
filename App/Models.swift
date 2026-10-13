import Foundation
import CryptoKit

struct Course: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var color: String = "green"
}
struct MaterialFolder: Codable, Identifiable, Equatable {
    var recordType = "material-folder"
    var id = UUID().uuidString
    var courseID: String
    var title: String
}
struct MaterialReadingPosition: Codable {
    var recordType = "reading-position"
    var courseID: String
    var materialID: String
    var documentRevision: String
    var page: Int
}

enum MaterialKind: String, Codable { case pdf, note, whiteboard, image, file }

struct Material: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var courseID: String
    var title: String
    var fileName: String
    var revision: String
    var kind: MaterialKind
    var createdAt = Date()
    var byteCount: Int64?
    var folderID: String?
    var sourceMaterialID: String?
    var sourcePage: Int?
    var sourceRevision: String?
    var legacyRelativePath: String { "Materials/\(id)/\(fileName)" }
    /// Binary files are immutable. Keeping the revision in the path prevents a
    /// metadata refresh from presenting the previous PDF beneath new ink.
    var relativePath: String {
        guard kind != .note && kind != .whiteboard else { return legacyRelativePath }
        let version = SHA256.hash(data: Data(revision.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Materials/\(id)/\(version)/\(fileName)"
    }
    var hasSafePath: Bool {
        UUID(uuidString: id) != nil && !["", ".", ".."].contains(fileName) && fileName == (fileName as NSString).lastPathComponent && !fileName.contains("\\")
    }
}

enum TabKind: String, Codable, CaseIterable {
    case pdf, note, browser, chat, board, whiteboard, file, recording, learning, calendar
    var title: String {
        switch self {
        case .pdf: "PDF"; case .note: "노트"; case .browser: "브라우저"; case .chat: "AI 튜터"
        case .board: "학업 보드"; case .whiteboard: "화이트보드"; case .file: "자료"
        case .recording: "강의 녹음"; case .learning: "학습과 복습"; case .calendar: "캘린더"
        }
    }
    var icon: String {
        switch self {
        case .pdf: "doc.richtext"; case .note: "note.text"; case .browser: "globe"; case .chat: "sparkles"
        case .board: "checklist"; case .whiteboard: "scribble.variable"; case .file: "doc"
        case .recording: "waveform"; case .learning: "rectangle.on.rectangle"; case .calendar: "calendar"
        }
    }
}

struct WorkspaceTab: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var courseID: String
    var kind: TabKind
    var title: String
    var materialID: String?
    var url: String?
    var isPrivate = false
}

struct WorkspaceState: Codable {
    var selectedCourseID: String?
    var tabs: [WorkspaceTab] = []
    var primaryID: String?
    var secondaryID: String?
    var focusedPane = 0
    var splitEnabled = false
}

struct NoteContent: Codable { var materialID: String; var markdown: String }

struct StudyTask: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var courseID: String
    var title: String
    var due: Date?
    var completed = false
    var calendarID: String?
}

struct Flashcard: Codable, Identifiable {
    var id = UUID().uuidString
    var courseID: String
    var front: String
    var back: String
    var due = Date()
    var interval = 0
    var reviews = 0
}

struct VocabularyEntry: Codable, Identifiable {
    var id = UUID().uuidString
    var courseID: String
    var word: String
    var meaning: String
    var context: String
    var createdAt = Date()
}

struct LearningEvent: Codable, Identifiable {
    var id = UUID().uuidString
    var courseID: String
    var objectID: String
    var action: String
    var value: String
    var createdAt = Date()
}

struct Conversation: Codable, Identifiable {
    var id: String
    var courseID: String
    var messages: [ChatMessage] = []
}

struct ChatMessage: Codable, Identifiable {
    var id = UUID().uuidString
    var role: String
    var text: String
    var createdAt = Date()
}

struct InkPageRecord: Codable {
    var materialID: String
    var documentRevision: String
    var page: Int
    var data: Data
}

struct RecordingMetadata: Codable, Identifiable {
    var id = UUID().uuidString
    var courseID: String
    var title: String
    var fileName: String
    var createdAt = Date()
    var duration: TimeInterval = 0
    var state = "recording"
    var segments: [TranscriptSegment] = []
    var anchors: [RecordingAnchor] = []
    var assetRevision: String?
    var byteCount: Int64?
    var hasSafePath: Bool { UUID(uuidString: id) != nil && fileName == "Recordings/\(id).wav" }
}
struct TranscriptSegment: Codable, Identifiable { var id = UUID().uuidString; var time: TimeInterval; var text: String }
struct RecordingAnchor: Codable, Identifiable { var id = UUID().uuidString; var time: TimeInterval; var materialID: String; var page: Int? }
