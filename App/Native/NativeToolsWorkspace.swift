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
    var store: NativeWorkspaceStore
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

/// A problem in a tool: an orange mark and the message on the panel's glass, with 닫기 when the caller can clear it.
struct NativeToolError: View {
    let message: String
    var onDismiss: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            BandalText(message).foregroundStyle(NativeDesktopTheme.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 44, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.secondary).accessibilityLabel("닫기")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(NativeGlass.selection, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .accessibilityElement(children: .combine).accessibilityIdentifier("native-tool-error")
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
