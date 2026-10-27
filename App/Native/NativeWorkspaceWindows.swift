import Foundation

enum NativeWorkspaceChromeMode: String, Codable, CaseIterable, Identifiable {
    case all, tabsHidden, toolsHidden
    var id: String { rawValue }
    var showsTabs: Bool { self == .all }
    var showsTools: Bool { self != .toolsHidden }
    var title: String {
        switch self {
        case .all: "모두 표시"
        case .tabsHidden: "탭 줄만 숨기기"
        case .toolsHidden: "탭·일반 도구 숨김"
        }
    }
}

/// A workspace owns resources and AI; a window owns only their presentation.
struct NativeWorkspaceWindowRef: Codable, Hashable, Identifiable {
    let workspaceID: String
    let windowID: String
    var id: String { workspaceID + ":" + windowID }
}

/// Capture before awaiting a resource operation. Resolving a missing target
/// must never create a window or redirect the result to the visible window.
struct NativeWorkspaceTarget: Codable, Hashable {
    let ref: NativeWorkspaceWindowRef
    let groupID: String?
    init(ref: NativeWorkspaceWindowRef, groupID: String? = nil) { self.ref = ref; self.groupID = groupID }
}

struct NativeWorkspaceWindow: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString.lowercased()
    var name: String
    var chromeMode: NativeWorkspaceChromeMode = .all
    var layout: NativeDockLayout = NativeDockLayout()
}

struct NativeWorkspaceWindowCollection: Codable, Equatable {
    var activeWindowID: String
    var windows: [NativeWorkspaceWindow]
    /// Names are not recycled after closing a window or manually renaming one.
    var nextWindowNumber: Int

    init(layout: NativeDockLayout = NativeDockLayout()) {
        let first = NativeWorkspaceWindow(name: "윈도우 1", layout: layout)
        activeWindowID = first.id; windows = [first]; nextWindowNumber = 2
    }
    var active: NativeWorkspaceWindow? { windows.first { $0.id == activeWindowID } ?? windows.first }
}

struct NativeWorkspaceWindowClosePlan {
    let ref: NativeWorkspaceWindowRef
    let documents: [NativeDocumentReference]
    var documentIDs: [String] { documents.map(\.id) }
    fileprivate let revision: Int

    init(ref: NativeWorkspaceWindowRef, documents: [NativeDocumentReference], revision: Int) {
        self.ref = ref; self.documents = documents; self.revision = revision
    }
    func matches(revision: Int) -> Bool { self.revision == revision }
}
