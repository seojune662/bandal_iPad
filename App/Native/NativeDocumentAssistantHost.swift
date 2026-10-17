import SwiftUI

/// Per-document assistant state follows the desktop controller contract. Opening
/// the rail action reveals this document's conversation without replacing it.
struct NativeDocumentAssistantHost<Content: View>: View {
    @ObservedObject var store: NativeWorkspaceStore
    let document: NativeDocumentReference
    @ViewBuilder var content: () -> Content
    private var visible: Bool { store.assistantDocumentIDs.contains(document.id) }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
                if visible && geometry.size.width >= 640 {
                    NativeDesktopTheme.border.frame(width: 1)
                    panel.frame(width: min(380, geometry.size.width * 0.46))
                }
            }
            .overlay(alignment: .trailing) {
                if visible && geometry.size.width < 640 {
                    ZStack(alignment: .trailing) {
                        Color.black.opacity(0.12).onTapGesture { store.assistantDocumentIDs.remove(document.id) }
                        panel.frame(width: min(360, geometry.size.width))
                            .shadow(color: .black.opacity(0.12), radius: 12, x: -4)
                    }
                }
            }
        }
    }
    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                Text("AI").fontWeight(.semibold)
                Spacer()
                NativeChromeButton(title: "AI 닫기", symbol: "xmark") { store.assistantDocumentIDs.remove(document.id) }
                    .accessibilityIdentifier("native-document-assistant-close")
            }.padding(.leading, 14).frame(height: 44)
            VStack(alignment: .leading, spacing: 6) {
                Label(document.title, systemImage: "doc.text").lineLimit(1)
                if let selected = store.documentSelections[document.id], !selected.isEmpty {
                    Text(selected).lineLimit(3).foregroundStyle(NativeDesktopTheme.secondary)
                    Button("선택한 글 제외", systemImage: "xmark") { store.documentSelections[document.id] = nil }.font(.caption)
                }
            }.font(NativeDesktopTheme.font(12)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(NativeDesktopTheme.raised).accessibilityIdentifier("native-document-assistant-context")
            NativeAssistantWorkspace(store: store, workspaceID: "document-assistant-" + document.id, courseID: document.courseID, sourceDocument: document)
        }.background(NativeDesktopTheme.surface).accessibilityElement(children: .contain).accessibilityIdentifier("native-document-assistant")
    }
}
