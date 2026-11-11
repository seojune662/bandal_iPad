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

    @State private var sharing = false
    private struct Item: Identifiable { let id: String, title: String, detail: String, symbol: String, action: () -> Void }
    /// 미리보기 · PDF · 이미지 · 다른 앱 (Figma 130:4009). The two exports are for PDFs, which handwritten notes are.
    private var items: [Item] {
        [Item(id: "native-dock-share-preview", title: "미리보기", detail: "페이지 넘겨 보기 · 인쇄", symbol: "doc") { preview() }]
        + (isPDF ? [Item(id: "native-dock-export-pdf", title: "PDF로 내보내기", detail: "필기 그대로 PDF 파일", symbol: "square.and.arrow.up") { run { _ = try await store.invoke("pdf:exportAnnotated", request) } },
                    Item(id: "native-dock-export-image", title: "이미지로 내보내기", detail: "지금 보는 페이지를 PNG로", symbol: "photo") { run { try await exportImage() } }] : [])
        + [Item(id: "native-dock-share-apps", title: "다른 앱으로 보내기", detail: "메시지 · 메일 · 파일 앱", symbol: "envelope") { run { _ = try await store.invoke("materials:share", request) } }]
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { preview() } label: { Image(systemName: "doc").font(.system(size: 17)).foregroundStyle(NativeDesktopTheme.text) }
                .buttonStyle(NativeDockIconButtonStyle()).accessibilityLabel("미리보기").accessibilityIdentifier("native-dock-preview")
            Button { sharing.toggle() } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 17)).foregroundStyle(NativeDesktopTheme.accent) }
                .buttonStyle(NativeDockIconButtonStyle()).accessibilityLabel("공유").accessibilityIdentifier("native-dock-share")
                // The card's right edge on the button's, its top 9 below it: the bottom of the tab strip.
                .bandalPopover(isPresented: $sharing, at: .bottomTrailing, offset: CGSize(width: -140, height: 3), width: 280, radius: 14, padding: 8) {
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            Button { sharing = false; item.action() } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.symbol).font(.system(size: 17)).foregroundStyle(NativeDesktopTheme.accent).frame(width: 24, height: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        BandalText(item.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(NativeDesktopTheme.text)
                                        BandalText(item.detail).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
                                    }.lineLimit(1)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 12).frame(height: 57).contentShape(Rectangle())
                            }.buttonStyle(BandalRowStyle(radius: 10)).accessibilityIdentifier(item.id)
                        }
                    }
                }
        }
    }
    /// Also reachable from a tab's long-press menu, where a split pane's strip has no room for the buttons.
    @ViewBuilder var menuItems: some View {
        ForEach(items) { item in Button(action: item.action) { Label(item.title, systemImage: item.symbol); Text(item.detail) }.accessibilityIdentifier(item.id) }
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
