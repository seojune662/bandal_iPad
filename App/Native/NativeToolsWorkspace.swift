import SwiftUI

enum NativeWorkspaceSection: String, CaseIterable, Identifiable {
    case library, browser, assistant, recordings, planner, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: "자료실"
        case .browser: "브라우저"
        case .assistant: "AI"
        case .recordings: "녹음"
        case .planner: "할 일"
        case .settings: "설정"
        }
    }
    var systemImage: String {
        switch self {
        case .library: "books.vertical"
        case .browser: "globe"
        case .assistant: "bubble.left.and.bubble.right"
        case .recordings: "waveform"
        case .planner: "checklist"
        case .settings: "gearshape"
        }
    }
}

struct NativeToolsWorkspace: View {
    let section: NativeWorkspaceSection
    @ObservedObject var store: NativeWorkspaceStore
    @ObservedObject var services: NativePlatformServices
    @StateObject private var librarySources = NativeLibrarySourceTrayModel()
    var workspaceID: String? = nil
    var courseID: String? = nil

    var body: some View {
        Group {
            switch section {
            case .library:
                NativeLibraryView(store: store, sourceTrayModel: librarySources) { document in
                    Task {
                        do { _ = try await store.invoke("materials:preview", ["courseId": document.courseID, "relPath": document.relativePath]) }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                }
            case .browser: NativeBrowserWorkspace(store: store, host: services.browser, workspaceID: workspaceID, courseID: courseID)
            case .assistant: NativeAssistantWorkspace(store: store, workspaceID: workspaceID, courseID: courseID)
            case .recordings: NativeRecordingWorkspace(store: store, workspaceID: workspaceID, courseID: courseID)
            case .planner: NativePlannerWorkspace(store: store, courseID: courseID)
            case .settings: NativeSettingsWorkspace(store: store)
            }
        }
    }
}

struct NativeToolError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding().background(Color.red.opacity(0.06))
            .accessibilityIdentifier("native-tool-error")
    }
}

enum NativeToolJSON {
    static func decode<T: Decodable>(_ value: Any, as type: T.Type = T.self) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(type, from: data)
    }
}

enum NativeAIProvider: String, CaseIterable, Identifiable {
    case openAI = "codex", anthropic = "claude-code", google = "gemini"
    var id: String { rawValue }
    var title: String {
        switch self { case .openAI: "OpenAI"; case .anthropic: "Anthropic"; case .google: "Google" }
    }
}
