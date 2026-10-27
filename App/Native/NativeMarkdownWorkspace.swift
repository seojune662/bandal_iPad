import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct NativeMarkdownWorkspace: View {
    let document: NativeDocumentReference
    @ObservedObject private var annotation: NativeAnnotationCoordinator
    @ObservedObject var store: NativeWorkspaceStore
    @StateObject private var session: NativeMarkdownSession
    @State private var registration: UUID?
    @State private var confirmReload = false
    @State private var copyMessage: String?
    @State private var copying = false
    @AppStorage private var pageIndex: Int
    @AppStorage private var pageNoteSync: Bool
    @State private var pageSourceCourseID: String?
    @State private var pageSourceRelativePath: String?
    @State private var showAppendix = false
    @State private var sourceMode = false
    @State private var activeFormats = Set<String>()
    @State private var activeCodeLanguage: String?
    @AppStorage("native.noteFontScale") private var noteFontScale = 1.0
    @State private var linkPrompt = false
    @State private var linkAddress = "https://"
    @State private var editingLink = false
    @State private var imagePicker = false
    @State private var imageImportTask: Task<Void, Never>?
    @State private var imageImportGeneration: UUID?
    @State private var formulaPrompt = false
    @State private var formula = ""
    @State private var wikiPicker = false
    @State private var wikiQuery = ""
    @State private var wikiMaterials: [NativeMaterial] = []
    @AppStorage("native.fontScale") private var fontScale = 1.0
    @AppStorage("native.editorFont") private var editorFont = "sans"
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.nativeWorkspaceChromeMode) private var chromeMode
    @Environment(\.nativeWorkspaceControlInset) private var controlInset
    @Environment(\.nativeWorkspaceTopInset) private var topInset
    @Environment(\.nativeWorkspaceTarget) private var workspaceTarget

    init(document: NativeDocumentReference, store: NativeWorkspaceStore) {
        self.document = document; self.store = store
        _annotation = ObservedObject(wrappedValue: store.annotation)
        let pageKey = "native.pageNotePage." + document.id, syncKey = "native.pageNoteSync." + document.id
        if let sourceID = store.documentDuplicateSourceIDs[document.id] {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: pageKey) == nil { defaults.set(defaults.integer(forKey: "native.pageNotePage." + sourceID), forKey: pageKey) }
            if defaults.object(forKey: syncKey) == nil { defaults.set(defaults.object(forKey: "native.pageNoteSync." + sourceID) as? Bool ?? true, forKey: syncKey) }
        }
        _pageIndex = AppStorage(wrappedValue: 0, pageKey)
        _pageNoteSync = AppStorage(wrappedValue: true, syncKey)
        _session = StateObject(wrappedValue: NativeMarkdownSession(courseID: document.courseID, relativePath: document.relativePath,
            draftFile: NativeMarkdownDraftFile(documentID: document.storageID, directory: store.root.appendingPathComponent("NativeMarkdownDrafts", isDirectory: true)), sharedKey: store.root.standardizedFileURL.path + ":" + document.storageID, paneID: document.id, invoke: { [weak store] channel, request in
                guard let store else { throw DesktopRuntimeError("저장소 연결이 닫혔습니다.") }
                return try await store.invoke(channel, request)
            }))
    }

    var body: some View {
        VStack(spacing: 0) {
            if annotation.request?.documentID == document.id {
                NativeAnnotationToolbar(coordinator: annotation, regionMode: $annotation.regionMode, attachText: attachAnnotatedText)
                    .padding(.trailing, controlInset).padding(.top, topInset)
            } else if chromeMode != .toolsHidden {
                formattingToolbar.padding(.trailing, controlInset).padding(.top, topInset)
            }
            if let error = session.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                    ViewThatFits(in: .horizontal) {
                        HStack { errorRecoveryActions }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading) { errorRecoveryActions }
                    }.buttonStyle(.bordered)
                }
                .foregroundStyle(.red).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.06))
                .accessibilityIdentifier("native-markdown-error")
            } else if session.recoveredDraft {
                Label("저장하지 못했던 내용을 복구했어요.", systemImage: "arrow.counterclockwise")
                    .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.07))
            }
            if session.loading {
                ProgressView("노트를 불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.canEdit {
                if let note = NativePDFPageNoteDocument(session.text) {
                    NativePagedMarkdownEditor(document: document, store: store, session: session, note: note,
                        pageIndex: $pageIndex, showAppendix: $showAppendix,
                        sourceMode: sourceMode, fontScale: fontScale * noteFontScale, editorFont: editorFont,
                        loadImage: loadImage, openLink: openLink, requestInsertion: requestInsertion,
                        importMedia: importMedia, mediaError: { copyMessage = $0 },
                        selectionChanged: { store.documentSelections[document.id] = $0.isEmpty ? nil : $0 },
                        formatsChanged: { activeFormats = $0 }, codeLanguageChanged: { activeCodeLanguage = $0 }, pageActivated: selectPage)
                } else {
                    NativeAnnotatableTextEditor(editor: NativeRichTextEditor(session: session, pageIndex: nil, appendix: false,
                        sourceMode: sourceMode, fontScale: fontScale * noteFontScale, editorFont: editorFont, loadImage: loadImage, openLink: openLink, requestInsertion: requestInsertion, importMedia: importMedia, mediaError: { copyMessage = $0 }, selectionChanged: { store.documentSelections[document.id] = $0.isEmpty ? nil : $0 }, formatsChanged: { activeFormats = $0 }, codeLanguageChanged: { activeCodeLanguage = $0 }), document: document, page: nil,
                        editorAccessibilityID: "native-markdown-editor", coordinator: annotation)
                }
            } else {
                ContentUnavailableView("노트를 열지 못했어요", systemImage: "doc.badge.ellipsis", description: Text("저장된 파일은 그대로 보관되어 있습니다."))
            }
        }
        .padding(.top, chromeMode == .toolsHidden && annotation.request?.documentID != document.id ? (controlInset > 0 ? topInset + 44 : topInset) : 0)
        .background(NativeDesktopTheme.bgApp)
        .task {
            session.onContentChanged = { [weak store] in store?.markDocumentChanged() }
            if registration == nil {
                registration = store.registerDocumentFlush(id: document.id, document: document,
                    freeze: { [session] in session.freezeForMaterialMutation() },
                    suspendWrites: { [session] in session.suspendWritesForMaterialMutation() },
                    resume: { [session] in session.cancelMaterialMutation() },
                    retire: { [session] in session.retireAfterMaterialMutation() },
                    flush: { [session] in try await session.flush() })
            }
            await store.waitForExternalMutation()
            guard !session.retired, !Task.isCancelled else { return }
            await session.load()
            if let note = NativePDFPageNoteDocument(session.text) {
                let source = try? await store.invokePrivate("nativePDF:pageNoteSource", ["courseId": document.courseID, "relPath": document.relativePath]) as? [String: Any]
                guard !session.retired, !Task.isCancelled else { return }
                let sourceCourse = source?["courseId"] as? String ?? document.courseID
                let sourcePath = source?["relPath"] as? String ?? note.source
                pageSourceCourseID = sourceCourse
                pageSourceRelativePath = sourcePath
                if pageNoteSync, !session.dirty {
                    let page: Int?
                    if let sourceID = store.pageNoteSourceTabIDs[document.id] {
                        page = NativePDFWorkspacePreferences.load(root: store.root, documentID: sourceID).viewport?.page
                    } else {
                        let saved = try? await store.invoke("pdf:getViewState", ["courseId": sourceCourse, "relPath": sourcePath]) as? [String: Any]
                        page = saved?["page"] as? Int
                    }
                    if let page, note.pages.indices.contains(page - 1) { session.prepareForFlush?(); pageIndex = page - 1 }
                }
            }
        }
        .onDisappear {
            imageImportTask?.cancel(); imageImportTask = nil; imageImportGeneration = nil
            guard let token = registration else { return }
            registration = nil
            if session.retired { store.unregisterDocumentFlush(token); return }
            Task { @MainActor [session, store] in
                do { try await session.flush(); store.unregisterDocumentFlush(token) }
                catch { /* Keep this session registered so closing cannot report a false save. */ }
            }
        }
        .onReceive(store.events) { event in
            if pageNoteSync, event.channel == "nativeWorkspace:pdfPageChanged", let value = event.payload as? [String: Any],
               (store.pageNoteSourceTabIDs[document.id] == nil || store.pageNoteSourceTabIDs[document.id] == value["tabID"] as? String),
               value["courseId"] as? String == (pageSourceCourseID ?? document.courseID), let note = NativePDFPageNoteDocument(session.text),
               value["relPath"] as? String == (pageSourceRelativePath ?? note.source), let page = value["page"] as? Int, note.pages.indices.contains(page - 1), (pageIndex != page - 1 || showAppendix) {
                session.prepareForFlush?(); pageIndex = page - 1; showAppendix = false
                return
            }
            guard let value = event.payload as? [String: Any], value["courseId"] as? String == document.courseID,
                  let path = (value["fromRelPath"] ?? value["relPath"]) as? String,
                  document.relativePath == path || (value["isDirectory"] as? Bool == true && document.relativePath.hasPrefix(path + "/")) else { return }
            switch event.channel {
            case "nativeWorkspace:materialWillMutate": session.freezeForMaterialMutation()
            case "nativeWorkspace:materialMutationCancelled": session.cancelMaterialMutation()
            case "nativeWorkspace:materialRenamed", "nativeWorkspace:materialDeleted", "nativeWorkspace:materialReplaced": session.retireAfterMaterialMutation()
            default: break
            }
        }
        .onChange(of: session.text) { _, text in
            if let note = NativePDFPageNoteDocument(text), pageIndex >= note.pages.count || pageIndex < 0 { pageIndex = max(0, min(pageIndex, note.pages.count - 1)) }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { save() } }
        .confirmationDialog("파일을 다시 읽을까요?", isPresented: $confirmReload, titleVisibility: .visible) {
            Button("파일 내용으로 되돌리기", role: .destructive) {
                Task { do { try await session.reloadDiscardingDraft() } catch { copyMessage = error.localizedDescription } }
            }
            Button("취소", role: .cancel) {}
        } message: { Text("저장하지 않은 편집 내용과 임시 저장본을 지우고 파일을 다시 읽습니다. 먼저 사본으로 보관할 수 있어요.") }
        .sheet(isPresented: $wikiPicker) {
            NavigationStack {
                List(wikiMaterials.filter { wikiQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(wikiQuery) }) { material in
                    Button {
                        session.applyFormat?("insert:[[" + (material.relPath as NSString).deletingPathExtension + "]]")
                        wikiPicker = false
                    } label: { Label(material.relPath, systemImage: "doc.text") }
                }.searchable(text: $wikiQuery, prompt: "노트 이름 검색")
                    .navigationTitle("노트 연결")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { wikiPicker = false } } }
                    .task {
                        if let value = try? await store.invoke("materials:tree", ["courseId": document.courseID]), let data = try? JSONSerialization.data(withJSONObject: value), let nodes = try? JSONDecoder().decode([NativeMaterial].self, from: data) {
                            wikiMaterials = NativeLibraryIndex.flatten(nodes).filter { $0.kind == "note" && $0.relPath != document.relativePath }
                        }
                    }
            }.presentationDetents([.medium, .large])
        }
        .fileImporter(isPresented: $imagePicker, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importImages(urls) }
            else if case .failure(let error) = result { copyMessage = error.localizedDescription }
        }
        .alert("수식 편집", isPresented: $formulaPrompt) {
            TextField("LaTeX", text: $formula).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("적용") { session.applyFormat?("replace-math:" + formula) }
            Button("취소", role: .cancel) {}
        }
        .alert("링크 주소", isPresented: $linkPrompt) {
            TextField("https://example.com", text: $linkAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(editingLink ? "적용" : "삽입") { session.applyFormat?("link:" + linkAddress) }.disabled(linkAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("취소", role: .cancel) {}
        }
        .alert("텍스트 노트", isPresented: Binding(get: { copyMessage != nil }, set: { if !$0 { copyMessage = nil } })) {
            Button("확인", role: .cancel) { copyMessage = nil }
        } message: { Text(copyMessage ?? "") }
    }

    private func attachAnnotatedText() {
        guard let request = annotation.request, request.documentID == document.id else { return }
        guard let text = store.documentSelections[document.id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            annotation.fail("먼저 노트의 텍스트를 선택해 주세요.", requestID: request.id); return
        }
        annotation.complete(.init(title: document.title, text: text, courseID: document.courseID,
            relativePath: document.relativePath, page: NativePDFPageNoteDocument(session.text) == nil || showAppendix ? nil : pageIndex + 1,
            revision: UUID().uuidString), requestID: request.id)
    }

    @ViewBuilder private var errorRecoveryActions: some View {
        Button(session.canEdit ? "다시 저장" : "다시 불러오기") {
            if session.canEdit { save() } else { Task { await session.load() } }
        }
        Button("사본으로 보관") { keepCopy() }.disabled(copying || !session.canEdit)
        Button("파일 다시 읽기") { confirmReload = true }
            .accessibilityIdentifier("native-markdown-reload-after-error")
    }

    private var formattingToolbar: some View {
        HStack(spacing: 0) {
            if let note = NativePDFPageNoteDocument(session.text) {
                pageControls(note).fixedSize(horizontal: true, vertical: false).padding(.leading, 8)
                NativeDesktopTheme.border.frame(width: 1, height: 20).padding(.horizontal, 4)
            }
            GeometryReader { geometry in
              HStack(spacing: 2) {
                ForEach([("본문", "paragraph"), ("제목 1", "h1"), ("제목 2", "h2"), ("제목 3", "h3"), ("굵게", "bold"), ("기울임", "italic"), ("취소선", "strike"), ("글머리 목록", "bullet"), ("번호 목록", "number"), ("할 일 목록", "task"), ("인용", "quote"), ("링크", "link"), ("이미지", "image"), ("인라인 코드", "code"), ("코드 블록", "codeblock")].prefix(max(0, Int((geometry.size.width - 12) / 42))), id: \.1) { item in
                    Button { session.applyFormat?(item.1) } label: {
                        Group {
                            if item.1.hasPrefix("h") { Text(item.1.uppercased()).font(.system(size: 13, weight: .medium)) }
                            else { Image(systemName: formatSymbol(item.1)).font(.system(size: 14)) }
                        }.frame(width: 40, height: 44).contentShape(Rectangle())
                            .background(activeFormats.contains(item.1) ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).accessibilityAddTraits(activeFormats.contains(item.1) ? [.isSelected] : []).accessibilityLabel(item.1 == "link" && activeFormats.contains("link") ? "링크 해제" : item.0).accessibilityIdentifier("native-markdown-format-" + item.1)
                }
              }.padding(.leading, 8).padding(.trailing, 4).frame(maxWidth: .infinity, alignment: .leading)
            }
                Menu {
                    Menu("글자 서식") {
                        ForEach([("본문", "paragraph"), ("굵게", "bold"), ("기울임", "italic"), ("취소선", "strike"), ("인라인 코드", "code")], id: \.1) { item in
                            Button { session.applyFormat?(item.1) } label: {
                                if activeFormats.contains(item.1) { Label(item.0, systemImage: "checkmark") } else { Text(item.0) }
                            }
                        }
                    }
                    ForEach(NativeRichTextCommands.insertions, id: \.id) { item in Button(item.id == "link" && activeFormats.contains("link") ? "링크 해제" : item.title) { session.applyFormat?(item.id) } }
                    if activeFormats.contains("link") { Button("링크 주소 편집") { session.applyFormat?("edit-link") }.accessibilityIdentifier("native-markdown-edit-link") }
                    Menu("코드 블록 언어") {
                        ForEach(NativeRichTextCommands.codeLanguages, id: \.id) { language in
                            Button { session.applyFormat?("code-language:" + language.id) } label: {
                                if activeCodeLanguage == language.id { Label(language.title, systemImage: "checkmark") } else { Text(language.title) }
                            }
                        }
                    }.disabled(activeCodeLanguage == nil).accessibilityIdentifier("native-markdown-code-language")
                    Divider()
                    Menu("표 편집") {
                        Button("위에 행 추가") { session.applyFormat?("table-row-before") }
                        Button("아래에 행 추가") { session.applyFormat?("table-row-after") }
                        Button("행 삭제") { session.applyFormat?("table-row-delete") }
                        Button("오른쪽에 열 추가") { session.applyFormat?("table-column-after") }
                        Button("열 삭제") { session.applyFormat?("table-column-delete") }
                        Button("다음 셀") { session.applyFormat?("table-next") }
                        Button("이전 셀") { session.applyFormat?("table-previous") }
                    }
                    Button("들여쓰기") { session.applyFormat?("indent") }
                    Button("내어쓰기") { session.applyFormat?("outdent") }
                    Divider()
                    Menu("편집기 확대/축소") {
                        ForEach(NativeNoteFontScale.values, id: \.self) { value in
                            Button { noteFontScale = value } label: { if abs(noteFontScale - value) < 0.001 { Label("\(Int((value * 100).rounded()))%", systemImage: "checkmark") } else { Text("\(Int((value * 100).rounded()))%") } }
                        }
                    }
                    Divider()
                    Button("지금 저장", systemImage: "checkmark.circle") { save() }
                    Button("사본으로 저장", systemImage: "doc.on.doc") { keepCopy() }.disabled(copying)
                    ShareLink(item: session.text) { Label("텍스트 공유", systemImage: "square.and.arrow.up") }
                    Button("파일 다시 읽기", systemImage: "arrow.clockwise") { confirmReload = true }
                    Button(sourceMode ? "서식 편집" : "Markdown 원문") { session.prepareForFlush?(); sourceMode.toggle() }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("서식과 노트 작업").accessibilityIdentifier("native-markdown-more")
                    .accessibilityValue(session.saving || session.dirty ? "저장 중" : "저장됨")
                Button { session.prepareForFlush?(); sourceMode.toggle() } label: { Image(systemName: sourceMode ? "textformat" : "chevron.left.forwardslash.chevron.right").frame(width: 44, height: 44) }
                    .accessibilityLabel(sourceMode ? "서식 편집" : "Markdown 원문").accessibilityIdentifier("native-markdown-source-toggle")
        }.frame(height: 44).accessibilityElement(children: .contain).accessibilityIdentifier("native-markdown-toolbar").foregroundStyle(NativeDesktopTheme.secondary).background(NativeDesktopTheme.surface)
            .overlay(alignment: .bottom) { NativeDesktopTheme.border.frame(height: 1) }
            .disabled(!session.canEdit || session.frozen)
    }
    private func formatSymbol(_ format: String) -> String {
        switch format { case "paragraph": "text.alignleft"; case "bold": "bold"; case "italic": "italic"; case "strike": "strikethrough"; case "bullet": "list.bullet"; case "number": "list.number"; case "task": "checklist"; case "quote": "text.quote"; case "link": "link"; case "image": "photo"; case "codeblock": "curlybraces"; default: "chevron.left.forwardslash.chevron.right" }
    }
    private func selectPage(_ index: Int) {
        session.prepareForFlush?(); pageIndex = index; showAppendix = false
        if pageNoteSync, let note = NativePDFPageNoteDocument(session.text) {
            var payload: [String: Any] = ["courseId": pageSourceCourseID ?? document.courseID, "relPath": pageSourceRelativePath ?? note.source, "page": index + 1]
            if let sourceTabID = store.pageNoteSourceTabIDs[document.id] { payload["tabID"] = sourceTabID }
            store.events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:goToPage", payload: payload))
        }
    }

    private func pageControls(_ note: NativePDFPageNoteDocument) -> some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(note.pages.indices, id: \.self) { index in
                    Button("\(index + 1) 페이지 필기") { selectPage(index) }
                        .accessibilityIdentifier("native-markdown-page-choice-\(index + 1)")
                }
                if !note.appendix.isEmpty { Button("연결 제외된 필기") { session.prepareForFlush?(); showAppendix = true } }
            } label: { Text("\(pageIndex + 1) / \(note.pages.count)").font(.system(size: 11, design: .monospaced)).fixedSize().frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("페이지 필기 이동").accessibilityIdentifier("native-markdown-page-picker")
            NativeChromeButton(title: "나란히 열기", symbol: "rectangle.split.2x1") { openPageSource(note) }
                .accessibilityIdentifier("native-markdown-page-open-source")
            NativeChromeButton(title: pageNoteSync ? "스크롤 연결됨" : "스크롤 독립", symbol: pageNoteSync ? "link" : "link.badge.plus", selected: pageNoteSync) {
                pageNoteSync.toggle()
                if pageNoteSync { selectPage(pageIndex) }
            }.accessibilityAddTraits(pageNoteSync ? .isSelected : [])
                .accessibilityIdentifier("native-markdown-page-sync")
        }
    }

    private func openPageSource(_ note: NativePDFPageNoteDocument) {
        let path = pageSourceRelativePath ?? note.source
        var payload: [String: Any] = ["courseId": pageSourceCourseID ?? document.courseID, "relPath": path,
            "title": (path as NSString).lastPathComponent, "kind": "pdf", "page": pageIndex + 1, "besideTabID": document.id]
        if let tabID = store.pageNoteSourceTabIDs[document.id] { payload["targetTabID"] = tabID }
        store.events.send(.init(channel: "nativeWorkspace:openDocument", payload: openingPayload(payload, target: workspaceTarget)))
    }

    private func requestInsertion(_ kind: String) {
        if kind.hasPrefix("math:") { formula = String(kind.dropFirst(5)); formulaPrompt = true }
        else if kind == "page" { createLinkedPage() }
        else if kind == "wikilink" { wikiQuery = ""; wikiPicker = true }
        else if kind == "image" { imagePicker = true }
        else { editingLink = kind.hasPrefix("link:"); linkAddress = editingLink ? String(kind.dropFirst(5)) : "https://"; linkPrompt = true }
    }
    private func createLinkedPage() {
        let destination = workspaceTarget
        Task { @MainActor in
            do {
                guard session.canEdit, !session.frozen, !session.retired else { return }
                let folder = (document.relativePath as NSString).deletingLastPathComponent
                let created = try await store.createMarkdown(title: "새 페이지", courseID: document.courseID, parentPath: folder)
                guard !session.frozen, !session.retired else { return }
                let target = (created.relativePath as NSString).deletingPathExtension
                session.applyFormat?("insert:[[" + target + "]]")
                try await session.flush()
                store.events.send(.init(channel: "nativeWorkspace:openDocument", payload: openingPayload(["courseId": created.courseID, "relPath": created.relativePath, "title": created.title, "kind": created.kind], target: destination)))
            } catch { copyMessage = error.localizedDescription }
        }
    }
    private func importImages(_ urls: [URL]) {
        imageImportTask?.cancel()
        let generation = UUID(); imageImportGeneration = generation
        imageImportTask = Task { @MainActor in
            defer { if imageImportGeneration == generation { imageImportTask = nil } }
            do {
                for url in urls {
                    guard imageImportGeneration == generation, !session.retired, !session.frozen, !Task.isCancelled else { return }
                    let encoded = try await NativeEditorMediaImport.fileBase64(url)
                    guard imageImportGeneration == generation, !session.retired, !session.frozen, !Task.isCancelled else { return }
                    let value = try await store.invoke("materials:writeFile", ["courseId": document.courseID, "dirRelPath": "assets", "createDirIfMissing": true,
                        "fileName": url.lastPathComponent, "encoding": "base64", "data": encoded])
                    guard let path = (value as? [String: Any])?["relPath"] as? String,
                          imageImportGeneration == generation, !session.retired, !session.frozen, !Task.isCancelled else { return }
                    session.applyFormat?("image:" + path)
                }
            } catch is CancellationError { /* A closed or replaced editor must not receive an insertion. */ }
            catch { if imageImportGeneration == generation, !Task.isCancelled { copyMessage = error.localizedDescription } }
        }
    }
    private func importMedia(_ items: [NativeDroppedMedia]) async throws -> String {
        guard session.canEdit, !session.retired, !session.frozen else { throw DesktopRuntimeError("문서를 편집할 수 없는 상태입니다.") }
        return try await NativeEditorMediaImport.markdown(items, courseID: document.courseID, store: store)
    }
    private func loadImage(_ raw: String) async -> UIImage? {
        guard !session.retired, !Task.isCancelled else { return nil }
        let path = raw.removingPercentEncoding ?? raw
        let image: UIImage?
        if let url = URL(string: path), ["https", "http"].contains(url.scheme ?? "") {
            var request = URLRequest(url: url); request.timeoutInterval = 20
            guard let response = try? await URLSession.shared.data(for: request), !Task.isCancelled,
                  response.0.count <= NativeEditorMediaImport.maximumBytes else { return nil }
            image = await NativeEditorMediaImport.previewImage(data: response.0)
        } else {
            guard let value = try? await store.invokePrivate("nativeMaterial:path", ["courseId": document.courseID, "relPath": path]),
                  let file = value as? String, !Task.isCancelled else { return nil }
            image = await NativeEditorMediaImport.previewImage(fileURL: URL(fileURLWithPath: file))
        }
        return session.retired || Task.isCancelled ? nil : image
    }
    private func openLink(_ raw: String) {
        let destination = workspaceTarget
        if raw.hasPrefix("bandal-wiki:") {
            let target = String(raw.dropFirst(12)).removingPercentEncoding ?? String(raw.dropFirst(12))
            let name = target.components(separatedBy: "#").first ?? target
            Task {
                if let value = try? await store.invoke("materials:tree", ["courseId": document.courseID]),
                   let data = try? JSONSerialization.data(withJSONObject: value),
                   let nodes = try? JSONDecoder().decode([NativeMaterial].self, from: data),
                   let match = NativeLibraryIndex.flatten(nodes).first(where: { $0.relPath == name || ($0.relPath as NSString).deletingPathExtension == name || ($0.name as NSString).deletingPathExtension == name }) {
                    store.events.send(.init(channel: "nativeWorkspace:openDocument", payload: openingPayload(["courseId": document.courseID, "relPath": match.relPath, "title": match.name, "kind": match.kind], target: destination)))
                } else { copyMessage = "연결된 노트를 찾지 못했습니다: " + name }
            }
        } else if let url = URL(string: raw), url.scheme == nil {
            let path = raw.removingPercentEncoding ?? raw
            Task { @MainActor in
                do {
                    let value = try await store.invoke("materials:tree", ["courseId": document.courseID])
                    let nodes = try JSONDecoder().decode([NativeMaterial].self, from: JSONSerialization.data(withJSONObject: value))
                    guard let material = NativeLibraryIndex.flatten(nodes).first(where: { $0.relPath == path && !$0.isDirectory }) else {
                        throw DesktopRuntimeError("첨부 파일을 찾지 못했습니다.")
                    }
                    store.events.send(.init(channel: "nativeWorkspace:openDocument", payload: openingPayload(["courseId": document.courseID,
                        "relPath": material.relPath, "title": material.name, "kind": material.kind], target: destination)))
                } catch { copyMessage = error.localizedDescription }
            }
        } else if let url = URL(string: raw) {
            if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                store.events.send(.init(channel: "nativeWorkspace:openBrowserURL", payload: openingPayload(["url": url.absoluteString], target: destination)))
            } else if ["mailto", "tel"].contains(url.scheme?.lowercased() ?? "") { UIApplication.shared.open(url) }
        }
    }
    private func openingPayload(_ values: [String: Any], target: NativeWorkspaceTarget?) -> [String: Any] {
        var payload = values
        payload["sourcePanelID"] = document.id
        if let target { payload["nativeWorkspaceTarget"] = target }
        return payload
    }

    private func save() { Task { do { try await session.flush() } catch { /* Session owns visible errors. */ } } }
    private func keepCopy() {
        guard !copying else { return }
        copying = true
        Task { @MainActor in
            defer { copying = false }
            do {
                try await session.keepCopy {
                    let parent = (document.relativePath as NSString).deletingLastPathComponent
                    return try await store.createMarkdown(title: (document.title as NSString).deletingPathExtension + " 사본", courseID: document.courseID, parentPath: parent)
                }
                copyMessage = "편집 내용을 새 마크다운로 보관했어요. 자료 목록에서 열 수 있습니다."
            } catch { copyMessage = error.localizedDescription }
        }
    }
}
