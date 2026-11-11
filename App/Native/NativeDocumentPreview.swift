import PDFKit
import SwiftUI

/// The document 미리보기 is showing. One per app; each workspace window shows only its own store's.
@MainActor @Observable final class NativeDocumentPreviewCenter {
    struct Item { let document: NativeDocumentReference; let pdf: PDFDocument; let page: Int; let store: ObjectIdentifier }
    static let shared = NativeDocumentPreviewCenter()
    var item: Item?

    /// The pages come from the export compositor, so the preview is the file 공유 will hand out.
    func open(_ document: NativeDocumentReference, page: Int, store: NativeWorkspaceStore) async throws {
        guard let output = try await store.invokePrivate("nativePDF:exportBytes", ["courseId": document.courseID, "relPath": document.relativePath]) as? [String: Any],
              let encoded = output["data"] as? String, let bytes = Data(base64Encoded: encoded), let pdf = PDFDocument(data: bytes), pdf.pageCount > 0 else { throw DesktopRuntimeError("미리보기를 준비하지 못했습니다.") }
        withAnimation(.easeOut(duration: 0.18)) { item = Item(document: document, pdf: pdf, page: min(max(0, page - 1), pdf.pageCount - 1), store: ObjectIdentifier(store)) }
    }
}

struct NativeDocumentPreviewLayer: View {
    var store: NativeWorkspaceStore
    var body: some View {
        if let item = NativeDocumentPreviewCenter.shared.item, item.store == ObjectIdentifier(store) {
            NativeDocumentPreview(item: item, store: store) { withAnimation(.easeOut(duration: 0.18)) { NativeDocumentPreviewCenter.shared.item = nil } }
                .transition(.opacity)
        }
    }
}

/// Figma 130:4297: a 56-point bar (닫기 · title and "1 / 3" · 공유), the page, a strip of 72 × 98 thumbnails.
struct NativeDocumentPreview: View {
    let item: NativeDocumentPreviewCenter.Item
    var store: NativeWorkspaceStore
    let close: () -> Void
    @State private var page: Int

    init(item: NativeDocumentPreviewCenter.Item, store: NativeWorkspaceStore, close: @escaping () -> Void) {
        self.item = item; self.store = store; self.close = close
        _page = State(initialValue: item.page)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Text((item.document.title as NSString).deletingPathExtension).font(.system(size: 17, weight: .semibold)).foregroundStyle(NativeDesktopTheme.text).lineLimit(1)
                    Text("\(page + 1) / \(item.pdf.pageCount)").font(.system(size: 15)).foregroundStyle(NativeDesktopTheme.secondary).monospacedDigit()
                        .accessibilityIdentifier("native-document-preview-count")
                }.padding(.horizontal, 120)
                HStack {
                    Button(action: close) {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark").font(.system(size: 17))
                            Text("닫기").font(.system(size: 16, weight: .medium))
                        }.foregroundStyle(NativeDesktopTheme.text).frame(height: 44).contentShape(Rectangle())
                    }.keyboardShortcut(.cancelAction).accessibilityLabel("미리보기 닫기").accessibilityIdentifier("native-document-preview-close")
                    Spacer()
                    Menu { NativeDockShareControls(document: item.document, store: store, includesPreview: false).menuItems } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 15))
                            Text("공유").font(.system(size: 15, weight: .semibold))
                        }.foregroundStyle(NativeDesktopTheme.onAccent).padding(.horizontal, 14).frame(height: 34)
                            .background(NativeDesktopTheme.accent, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                    }.accessibilityLabel("미리보기에서 공유").accessibilityIdentifier("native-document-preview-share")
                }
            }.buttonStyle(.plain).padding(.horizontal, 20).frame(height: 56).background(NativeDesktopTheme.bgApp.ignoresSafeArea(edges: .top))
            NativeGlass.separator.frame(height: 1)
            TabView(selection: $page) {
                ForEach(0..<item.pdf.pageCount, id: \.self) { index in
                    NativeDocumentPreviewPage(pdf: item.pdf, index: index, size: CGSize(width: 1120, height: 1520))
                        .clipShape(RoundedRectangle(cornerRadius: 4)).shadow(color: .black.opacity(0.12), radius: 14, y: 8)
                        // Inside the pager, which clips: the room the shadow needs is the design's own margin.
                        .padding(.top, 31).padding(.bottom, 36).padding(.horizontal, 20).tag(index)
                        .accessibilityLabel("\(item.pdf.pageCount)쪽 중 \(index + 1)쪽").accessibilityIdentifier("native-document-preview-page")
                }
            }.tabViewStyle(.page(indexDisplayMode: .never))
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 16) {
                            ForEach(0..<item.pdf.pageCount, id: \.self) { index in
                                let shape = RoundedRectangle(cornerRadius: 4)
                                Button { withAnimation { page = index } } label: {
                                    NativeDocumentPreviewPage(pdf: item.pdf, index: index, size: CGSize(width: 144, height: 196))
                                        .frame(width: 72, height: 98).background(NativeDesktopTheme.bgApp).clipShape(shape)
                                        .overlay { shape.strokeBorder(index == page ? NativeDesktopTheme.accent : NativeDesktopTheme.border, lineWidth: index == page ? 2 : 1) }
                                }.buttonStyle(.plain).id(index).accessibilityLabel("\(index + 1)쪽 열기").accessibilityAddTraits(index == page ? .isSelected : [])
                                    .accessibilityIdentifier("native-document-preview-thumbnail-\(index + 1)")
                            }
                        }.padding(.horizontal, 20).frame(minWidth: geometry.size.width)
                    }.onChange(of: page) { _, value in withAnimation { proxy.scrollTo(value, anchor: .center) } }
                        .onAppear { proxy.scrollTo(page, anchor: .center) }
                }
            }.frame(height: 98).padding(.bottom, 42)
        }
        // The design measures from the screen's edges: 42 under the strip, home indicator included.
        .ignoresSafeArea(edges: .bottom)
        .background(NativeDesktopTheme.surface.ignoresSafeArea())
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal).accessibilityIdentifier("native-document-preview")
    }
}

/// One exported page, drawn when it first comes on screen.
private struct NativeDocumentPreviewPage: View {
    let pdf: PDFDocument
    let index: Int
    /// Pixels to fit the page into.
    let size: CGSize
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { NativeDesktopTheme.bgApp.aspectRatio(560 / 760, contentMode: .fit) }
        }
        // ponytail: drawn on the main actor, one page at a time; move to a detached task if a heavy page stutters the swipe.
        .task { if image == nil { image = pdf.page(at: index)?.thumbnail(of: size, for: .mediaBox) } }
    }
}
