import PDFKit
import SwiftUI

/// End of the tab strip on a note or markdown tab: 미리보기 (paper) and 공유, always visible.
struct NativeDockShareControls: View {
    let document: NativeDocumentReference
    var store: NativeWorkspaceStore
    /// Two 34-point buttons and the 6 between them (Figma 155:7551, 155:7553).
    static let width: CGFloat = 74
    /// The page each open PDF tab is showing, so "이미지로 내보내기" exports the one on screen.
    @MainActor static var visiblePage: [String: Int] = [:]
    static func supports(_ document: NativeDocumentReference) -> Bool { !document.isWorkspaceTool && (["pdf", "note"].contains(document.kind) || ["md", "markdown"].contains((document.relativePath as NSString).pathExtension.lowercased())) }
    private var isPDF: Bool { document.kind == "pdf" }
    private var request: [String: Any] { ["courseId": document.courseID, "relPath": document.relativePath] }

    var body: some View {
        HStack(spacing: 6) {
            Button { preview() } label: { Image(systemName: "doc").font(.system(size: 17)).foregroundStyle(NativeDesktopTheme.text) }
                .buttonStyle(NativeDockIconButtonStyle()).accessibilityLabel("미리보기").accessibilityIdentifier("native-dock-preview")
            Menu { menuItems } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 17)).foregroundStyle(NativeDesktopTheme.accent)
                    .frame(width: 34, height: 34).contentShape(Rectangle())
            }.accessibilityLabel("공유").accessibilityIdentifier("native-dock-share")
        }
    }
    /// Also reachable from a tab's long-press menu, where a split pane's strip has no room for the buttons.
    @ViewBuilder var menuItems: some View {
        Button { preview() } label: { Label("미리보기", systemImage: "doc"); Text("페이지 넘겨 보기 · 인쇄") }
        if isPDF {
            Button { run { _ = try await store.invoke("pdf:exportAnnotated", request) } } label: { Label("PDF로 내보내기", systemImage: "square.and.arrow.up"); Text("필기 그대로 PDF 파일") }
                .accessibilityIdentifier("native-dock-export-pdf")
            Button { run { try await exportImage() } } label: { Label("이미지로 내보내기", systemImage: "photo"); Text("지금 보는 페이지를 PNG로") }
                .accessibilityIdentifier("native-dock-export-image")
        }
        Button { run { _ = try await store.invoke("materials:share", request) } } label: { Label("다른 앱으로 보내기", systemImage: "envelope"); Text("메시지 · 메일 · 파일 앱") }
            .accessibilityIdentifier("native-dock-share-apps")
    }

    private func preview() { run { _ = try await store.invoke("materials:preview", request.merging(["annotated": true]) { $1 }) } }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await store.flushDocuments(); try await action() } catch { store.errorMessage = error.localizedDescription } }
    }
    private func exportImage() async throws {
        guard let output = try await store.invokePrivate("nativePDF:exportBytes", request) as? [String: Any], let encoded = output["data"] as? String,
              let bytes = Data(base64Encoded: encoded), let pdf = PDFDocument(data: bytes),
              let page = pdf.page(at: min(max(0, (Self.visiblePage[document.id] ?? 1) - 1), pdf.pageCount - 1)) else { throw DesktopRuntimeError("이미지로 내보낼 페이지를 준비하지 못했습니다.") }
        let bounds = page.bounds(for: .mediaBox)
        let image = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
        guard let png = image.pngData() else { throw DesktopRuntimeError("이미지를 만들지 못했습니다.") }
        let name = ((document.title as NSString).deletingPathExtension) + "-\(Self.visiblePage[document.id] ?? 1).png"
        _ = try await store.invokePrivate("native:saveFile", ["suggestedName": name.replacingOccurrences(of: "/", with: "-"), "data": png.base64EncodedString()])
    }
}

/// Strip icon button: 34×34 r8, filled while pressed.
struct NativeDockIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 34, height: 34)
            .background(configuration.isPressed ? NativeGlass.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}
