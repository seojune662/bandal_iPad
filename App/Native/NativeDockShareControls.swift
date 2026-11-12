import PDFKit
import SwiftUI

/// 공유, the first of the window buttons at the top right: the active tab's page link for a web tab,
/// the file itself for anything else, with the exports a note or PDF has.
struct NativeDockShareControls: View {
    let document: NativeDocumentReference
    var store: NativeWorkspaceStore
    /// Off inside the preview itself, whose 공유 lists the same actions.
    var includesPreview = true
    /// The windows overview draws no group: the cell stays, unseen.
    var hidden = false
    /// The page each open PDF tab is showing, so "이미지로 내보내기" exports the one on screen.
    @MainActor static var visiblePage: [String: Int] = [:]
    static func supports(_ document: NativeDocumentReference) -> Bool { !document.isWorkspaceTool && (["pdf", "note"].contains(document.kind) || ["md", "markdown"].contains((document.relativePath as NSString).pathExtension.lowercased())) }
    /// A file in a course or project, which `materials:share` hands to the system sheet.
    static func isFile(_ document: NativeDocumentReference) -> Bool { !document.isWorkspaceTool && document.learningTarget == nil && !document.relativePath.isEmpty }
    private var isPDF: Bool { document.kind == "pdf" }
    private var request: [String: Any] { ["courseId": document.courseID, "relPath": document.relativePath] }

    @State private var sharing = false
    @State private var anchor = CGRect.zero
    private struct Item: Identifiable { let id: String, title: String, detail: String, symbol: String, action: () -> Void }
    /// 미리보기 · PDF · 이미지 · 다른 앱 (Figma 130:4009). The two exports are for PDFs, which handwritten notes are.
    private var items: [Item] {
        (includesPreview ? [Item(id: "native-dock-share-preview", title: "미리보기", detail: "페이지 넘겨 보기 · 인쇄", symbol: "doc") { preview() }] : [])
        + (isPDF ? [Item(id: "native-dock-export-pdf", title: "PDF로 내보내기", detail: "필기 그대로 PDF 파일", symbol: "square.and.arrow.up") { run { _ = try await store.invoke("pdf:exportAnnotated", request) } },
                    Item(id: "native-dock-export-image", title: "이미지로 내보내기", detail: "지금 보는 페이지를 PNG로", symbol: "photo") { run { try await exportImage() } }] : [])
        + [Item(id: "native-dock-share-apps", title: "다른 앱으로 보내기", detail: "메시지 · 메일 · 파일 앱", symbol: "envelope") { run { _ = try await store.invoke("materials:share", request) } }]
    }

    private var cell: some View {
        Image(systemName: "square.and.arrow.up").font(.system(size: 16)).foregroundStyle(NativeGlass.panelIcon)
            .frame(width: 36, height: 40).opacity(hidden ? 0 : 1).contentShape(Rectangle())
    }
    var body: some View {
        Group {
            if document.kind == "browser" {
                Button { shareLink() } label: { cell }.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor = $0 }
            } else if Self.supports(document) {
                Button { sharing.toggle() } label: { cell }
                    .bandalPopover(isPresented: $sharing, at: .bottom, offset: CGSize(width: 0, height: 3), width: 280, radius: 14, padding: 8) {
                        VStack(spacing: 2) {
                            // Which document this acts on: with panes side by side it is the one last touched.
                            HStack(spacing: 8) {
                                Image(systemName: isPDF ? "doc.richtext" : "doc.text").font(.system(size: 13)).foregroundStyle(NativeGlass.accent)
                                Text(verbatim: document.title).font(.system(size: 13, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 12).frame(height: 32).accessibilityIdentifier("native-dock-share-target")
                            ForEach(items) { item in
                                Button { sharing = false; item.action() } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: item.symbol).font(.system(size: 17)).foregroundStyle(NativeGlass.accent).frame(width: 24, height: 24)
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
            } else {
                Button { run { _ = try await store.invoke("materials:share", request) } } label: { cell }.disabled(!Self.isFile(document))
            }
        }.accessibilityLabel("공유").accessibilityIdentifier("native-dock-share")
    }
    /// The page the web tab shows now, read when the button is pressed: the tab navigates without this view hearing of it.
    private func shareLink() {
        guard let page = NativeBrowserSession.currentPage(workspaceID: document.relativePath, store: store), let link = URL(string: page.url),
              ["http", "https"].contains(link.scheme?.lowercased() ?? "") else { store.errorMessage = "공유할 링크가 없어요."; return }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first, var presenter = window.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        let sheet = UIActivityViewController(activityItems: [link], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = window; sheet.popoverPresentationController?.sourceRect = anchor
        presenter.present(sheet, animated: true)
    }
    /// Also reachable from a tab's long-press menu, where a split pane's strip has no room for the buttons.
    @ViewBuilder var menuItems: some View {
        ForEach(items) { item in Button(action: item.action) { Label(item.title, systemImage: item.symbol); Text(item.detail) }.accessibilityIdentifier(item.id) }
    }

    /// A PDF (handwritten notes are PDFs) opens the in-app preview; Markdown has no paged export, so it stays with Quick Look.
    private func preview() {
        run {
            if isPDF { try await NativeDocumentPreviewCenter.shared.open(document, page: Self.visiblePage[document.id] ?? 1, store: store) }
            else { _ = try await store.invoke("materials:preview", request.merging(["annotated": true]) { $1 }) }
        }
    }
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
