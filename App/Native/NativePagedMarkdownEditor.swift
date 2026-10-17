import SwiftUI
import UIKit

/// Every paper uses its source PDF's aspect ratio. Visible pages have separate
/// editor callbacks and share the document writer, so a page change cannot
/// discard composition or replace another page's pending edit.
struct NativePagedMarkdownEditor: View {
    let document: NativeDocumentReference
    @ObservedObject var store: NativeWorkspaceStore
    @ObservedObject var session: NativeMarkdownSession
    let note: NativePDFPageNoteDocument
    @Binding var pageIndex: Int
    @Binding var showAppendix: Bool
    let sourceMode: Bool
    let fontScale: Double
    let editorFont: String
    let loadImage: (String) async -> UIImage?
    let openLink: (String) -> Void
    let requestInsertion: (String) -> Void
    let selectionChanged: (String) -> Void
    let formatsChanged: (Set<String>) -> Void
    let codeLanguageChanged: (String?) -> Void
    let pageActivated: (Int) -> Void
    @StateObject private var editors = NativePageEditorSessions()
    @State private var scrollPage: Int?
    @State private var userScrolling = false
    @State private var measuredHeights: [Int: CGFloat] = [:]

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, min(600, geometry.size.width - 16))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(note.pages.indices, id: \.self) { index in
                            let size = note.manifest.pages[index]
                            paper(index, width: width, height: width * size.height / size.width)
                                .id(index)
                        }
                        if !note.appendix.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("연결 제외된 페이지").fontWeight(.semibold)
                                Text("PDF에서 사라진 페이지의 필기를 보존했습니다.")
                                    .font(.caption).foregroundStyle(NativeDesktopTheme.secondary)
                                pageEditor(-1, height: max(320, measuredHeights[-1] ?? 320))
                                    .frame(height: max(320, measuredHeights[-1] ?? 320))
                            }.padding(16).frame(width: width)
                                .background(NativeDesktopTheme.surface).id(-1)
                        }
                    }.scrollTargetLayout().padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 16)
                        .frame(maxWidth: .infinity)
                }
                .scrollPosition(id: $scrollPage, anchor: .top)
                .scrollDismissesKeyboard(.interactively)
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                }
                .onChange(of: scrollPage) { _, index in
                    guard userScrolling, let index else { return }
                    if index < 0 { session.prepareForFlush?(); showAppendix = true }
                    else if index != pageIndex || showAppendix { pageActivated(index) }
                }
                .onChange(of: pageIndex) { _, index in
                    editors.activePage = index
                    if !userScrolling { proxy.scrollTo(index, anchor: .top) }
                }
                .onChange(of: showAppendix) { _, appendix in
                    editors.activePage = appendix ? -1 : pageIndex
                    if !userScrolling { proxy.scrollTo(appendix ? -1 : pageIndex, anchor: .top) }
                }
                .onAppear {
                    editors.installToolbar(on: session)
                    scrollPage = showAppendix ? -1 : pageIndex
                    editors.activePage = showAppendix ? -1 : pageIndex
                }
                .onDisappear { session.applyFormat = nil; session.prepareForFlush = nil }
                .accessibilityElement(children: .contain).accessibilityIdentifier("native-markdown-pages-scroll")
            }
        }.background(NativeDesktopTheme.bgApp)
    }

    private func paper(_ index: Int, width: CGFloat, height: CGFloat) -> some View {
        pageEditor(index, height: height)
            .frame(width: width, height: height)
            .background(NativeDesktopTheme.surface)
            .overlay(alignment: .topTrailing) {
                Text(String(index + 1)).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NativeDesktopTheme.muted).frame(minWidth: 28, minHeight: 28)
                    .background(NativeDesktopTheme.surface.opacity(0.9), in: Capsule())
                    .overlay { Capsule().stroke(NativeDesktopTheme.border, lineWidth: 1) }
                    .padding(12).allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).stroke(index == pageIndex && !showAppendix ? NativeDesktopTheme.accent.opacity(0.55) : NativeDesktopTheme.border, lineWidth: 1) }
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(index + 1) 페이지 필기")
            .accessibilityIdentifier("native-markdown-paper-\(index + 1)")
    }

    private func pageEditor(_ index: Int, height: CGFloat) -> some View {
        let pane = editors.editor(index, document: document, store: store)
        return NativeRichTextEditor(session: pane, pageIndex: max(0, index), appendix: index < 0,
            sourceMode: sourceMode, fontScale: fontScale, editorFont: editorFont,
            loadImage: loadImage, openLink: openLink, requestInsertion: requestInsertion,
            selectionChanged: { if editors.activePage == index { selectionChanged($0) } },
            formatsChanged: { if editors.activePage == index { formatsChanged($0) } },
            codeLanguageChanged: { if editors.activePage == index { codeLanguageChanged($0) } },
            scrollsInternally: (measuredHeights[index] ?? 0) > height + 1,
            compactPaperLayout: true,
            contentHeightChanged: { value in
                if abs(value - (measuredHeights[index] ?? 0)) > 1 { measuredHeights[index] = value }
            },
            focusChanged: { focused in
                guard focused else { return }
                editors.activePage = index
                if index < 0 { showAppendix = true }
                else if pageIndex != index || showAppendix { pageActivated(index) }
            })
            .disabled(!pane.canEdit)
            .accessibilityIdentifier("native-markdown-page-editor-\(index + 1)")
            .task { await pane.load(); await Task.yield(); editors.editorMounted(index) }
    }
}

@MainActor
private final class NativePageEditorSessions: ObservableObject {
    private var pages: [Int: NativeMarkdownSession] = [:]
    private var pendingCommand: (page: Int, command: String)?
    var activePage = 0
    func editor(_ index: Int, document: NativeDocumentReference, store: NativeWorkspaceStore) -> NativeMarkdownSession {
        if let existing = pages[index] { return existing }
        let pane = NativeMarkdownSession(courseID: document.courseID, relativePath: document.relativePath,
            draftFile: NativeMarkdownDraftFile(documentID: document.storageID, directory: store.root.appendingPathComponent("NativeMarkdownDrafts", isDirectory: true)),
            sharedKey: store.root.standardizedFileURL.path + ":" + document.storageID,
            paneID: document.id + ":page:\(index)", invoke: { [weak store] channel, request in
                guard let store else { throw DesktopRuntimeError("저장소 연결이 닫혔습니다.") }
                return try await store.invoke(channel, request)
            })
        pane.onContentChanged = { [weak store] in store?.markDocumentChanged() }
        pages[index] = pane
        return pane
    }
    func installToolbar(on parent: NativeMarkdownSession) {
        parent.applyFormat = { [weak self] command in
            guard let self else { return }
            if let apply = pages[activePage]?.applyFormat { apply(command) }
            else { pendingCommand = (activePage, command) }
        }
        parent.prepareForFlush = { [weak self] in
            guard let self else { return }; pages[activePage]?.prepareForFlush?()
        }
    }
    func editorMounted(_ index: Int) {
        guard let pending = pendingCommand, pending.page == index, let apply = pages[index]?.applyFormat else { return }
        pendingCommand = nil
        if activePage == index { apply(pending.command) }
    }
}
