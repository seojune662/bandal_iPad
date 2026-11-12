import SwiftUI
import UniformTypeIdentifiers

struct NativeLibraryView: View {
    @ObservedObject var store: NativeWorkspaceStore
    @ObservedObject var sourceTrayModel: NativeLibrarySourceTrayModel
    var scope: NativeWorkspaceContext? = nil
    var isExpanded = false
    var onToggleExpanded: (() -> Void)? = nil
    var onOpenAI: (() -> Void)? = nil
    var selectedDocumentID: String? = nil
    @StateObject private var projectLibrary = NativeProjectLibrary()
    @State private var loadedScopeID: String?
    var onClose: (() -> Void)? = nil
    var captureOpen: (() -> (NativeDocumentReference) -> Void)? = nil
    var onOpen: (NativeDocumentReference) -> Void
    @State private var importDestination: MaterialDestination?
    @AppStorage("native.library.displayMode") private var storedDisplayMode = NativeLibraryDisplayMode.list.rawValue
    @AppStorage("native.library.sortOrder") private var storedSortOrder = NativeLibrarySortOrder.name.rawValue
    @State private var gallerySelection: String?
    @State private var materialURLs: [String: URL] = [:]
    @State private var query = ""
    @State private var folderPath = ""
    @State private var expandedFolders = Set<String>()
    @State private var filesExpanded = true
    @State private var importing = false
    @State private var creation: CreationRequest?
    @State private var renaming: NativeMaterial?
    @State private var moving: NativeMaterial?
    @State private var deleting: NativeMaterial?
    @State private var operationError: String?
    @State private var working = false
    @State private var contentHits: [NativeContentHit] = []
    @State private var searchRevision = 0
    @State private var searching = false
    @State private var contentError: String?
    @State private var markdownTitlePrefix = "새 마크다운"

    private enum Creation { case ink, markdown, folder }
    private struct MaterialDestination { let courseID: String; let folder: String }
    /// The presented item owns every captured value. Separate sheet state can
    /// otherwise be read from the presenter before SwiftUI applies its update.
    private struct CreationRequest: Identifiable {
        let id = UUID()
        let kind: Creation
        let destination: MaterialDestination
        let markdownTitle: String
        let open: (NativeDocumentReference) -> Void
    }
    private var courseID: String? { scope?.courseID ?? store.selectedCourseID }
    private var scopeID: String { scope?.id ?? "course:" + (courseID ?? "") }
    private var rootPath: String { scope?.rootRelPath ?? "" }
    private var scopedMaterials: [NativeMaterial] {
        guard courseID == store.selectedCourseID else { return [] }
        return NativeLibraryIndex.contents(in: rootPath, materials: store.materials) + (projectLibrary.scopeID == scope?.id ? projectLibrary.results : [])
    }
    private var materialColumns: [NativeLibraryColumn] {
        let root = NativeLibraryColumn(path: rootPath, title: scope?.title ?? "전체 자료", materials: NativeLibraryPresentation.sorted(scopedMaterials))
        let descendants = NativeLibraryPresentation.columns(folder: folderPath, materials: store.materials).filter { $0.path != rootPath && (rootPath.isEmpty ? !$0.path.isEmpty : $0.path.hasPrefix(rootPath + "/")) }
        return [root] + descendants
    }
    private var displayMode: NativeLibraryDisplayMode { NativeLibraryDisplayMode(rawValue: storedDisplayMode) ?? .list }
    private var sortOrder: NativeLibrarySortOrder { NativeLibrarySortOrder(rawValue: storedSortOrder) ?? .name }
    private var folderTitle: String { folderPath == rootPath ? (scope?.title ?? store.courses.first { $0.id == courseID }?.name ?? "자료") : (folderPath as NSString).lastPathComponent }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var visibleContentHits: [NativeContentHit] {
        contentHits.filter { folderPath.isEmpty || $0.relPath.hasPrefix(folderPath + "/") }
    }
    private var galleryMaterial: NativeMaterial? { items.first { $0.relPath == gallerySelection && !$0.isDirectory } ?? items.first { !$0.isDirectory } }
    private var currentItems: [NativeMaterial] {
        folderPath == rootPath ? scopedMaterials : NativeLibraryIndex.contents(in: folderPath, materials: scopedMaterials)
    }
    private var items: [NativeMaterial] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = search.isEmpty ? currentItems : NativeLibraryIndex.flatten(scopedMaterials).filter {
            (folderPath.isEmpty || $0.relPath.hasPrefix(folderPath + "/") || folderPath == rootPath && $0.learningTarget != nil) &&
                ($0.name.localizedStandardContains(search) || $0.relPath.localizedStandardContains(search))
        }
        return NativeLibraryPresentation.sorted(source, order: sortOrder)
    }

    private var configuredContent: some View {
        VStack(spacing: 0) {
            libraryHeader
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(NativeDesktopTheme.font(14))
                TextField("자료 검색", text: $query, prompt: NativeDesktopTheme.prompt("자료 검색")).font(NativeDesktopTheme.font(14)).textFieldStyle(.plain)
                    .accessibilityIdentifier("native-library-search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 32, height: 44) }
                        .accessibilityLabel("검색 지우기")
                }
            }.foregroundStyle(NativeDesktopTheme.muted).padding(.horizontal, 12).frame(minHeight: 44)
                .background(NativeDesktopTheme.raised.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16).padding(.bottom, 4)
            libraryToolbar
            if displayMode != .compact || isSearching { breadcrumbs }
            libraryContent.frame(maxHeight: .infinity)
            NativeLibrarySourceTray(store: store, folderPath: folderPath, model: sourceTrayModel)
        }
        .background(NativeDesktopTheme.surface)
        .buttonStyle(.plain)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            let destination = importDestination
            importDestination = nil
            switch result {
            case .success(let urls):
                guard let destination else { operationError = "자료를 가져올 공간을 확인해 주세요."; return }
                perform { try await store.importFiles(urls, courseID: destination.courseID, parentPath: destination.folder) }
            case .failure(let error): operationError = error.localizedDescription
            }
        }
    }

    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Text("자료").font(NativeDesktopTheme.font(12, weight: .medium)).foregroundStyle(NativeDesktopTheme.muted)
                Text(folderTitle).font(NativeDesktopTheme.font(isExpanded ? 26 : 22, weight: .bold))
                    .foregroundStyle(NativeDesktopTheme.text).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if working { ProgressView().scaleEffect(0.7).frame(width: 20) }
            if let onToggleExpanded {
                Button(action: onToggleExpanded) {
                    Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel(isExpanded ? "자료 줄여 보기" : "자료 넓게 보기")
                    .accessibilityIdentifier("native-library-expand")
            }
            if isExpanded, let onClose {
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("자료 닫기").accessibilityIdentifier("native-library-close")
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 14)
    }

    private var libraryToolbar: some View {
        HStack(spacing: 0) {
            if displayMode == .compact && !isSearching {
                Button { filesExpanded.toggle() } label: {
                    Image(systemName: filesExpanded ? "chevron.down" : "chevron.right").frame(width: 28, height: 44)
                }.accessibilityLabel(filesExpanded ? "파일 목록 접기" : "파일 목록 펼치기")
            }
            Text(isSearching ? "파일 \(items.count) · 본문 \(visibleContentHits.count)" : "\(displayMode == .compact ? treeRows.count : items.count)개")
                .font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Menu {
                Picker("정렬", selection: $storedSortOrder) {
                    ForEach(NativeLibrarySortOrder.allCases) { order in Text(order.title).tag(order.rawValue) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                    if isExpanded { Text(sortOrder.title).font(NativeDesktopTheme.font(13)) }
                }.padding(.horizontal, isExpanded ? 10 : 0).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
                .accessibilityLabel("자료 정렬: " + sortOrder.title).accessibilityIdentifier("native-library-sort-menu")
            viewPicker
            Button { beginImport() } label: {
                Image(systemName: "tray.and.arrow.down").frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("파일 가져오기").disabled(courseID == nil || working).accessibilityIdentifier("native-library-import")
            Menu {
                Button("새 노트", systemImage: "pencil.tip.crop.circle.badge.plus") { beginCreation(.ink) }
                Button("새 마크다운", systemImage: "doc.badge.plus") { beginCreation(.markdown) }
                Button("새 폴더", systemImage: "folder.badge.plus") { beginCreation(.folder) }
                if let onOpenAI { Divider(); Button("AI로 만들기", systemImage: "sparkles", action: onOpenAI) }
            } label: { Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .disabled(courseID == nil || working).accessibilityLabel("추가").accessibilityIdentifier("native-library-create")
        }.padding(.horizontal, 16)
    }

    private var viewPicker: some View {
        Menu {
            Picker("보기 방식", selection: $storedDisplayMode) {
                ForEach(NativeLibraryDisplayMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode.rawValue)
                        .accessibilityIdentifier("native-library-view-" + mode.rawValue)
                }
            }
            Divider()
            Button("자료 새로고침", systemImage: "arrow.clockwise") {
                Task { await store.refreshMaterials(); await projectLibrary.reload(store: store, scope: scope) }
            }.accessibilityIdentifier("native-library-refresh")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: displayMode.symbol)
                if isExpanded { Text(displayMode.title).font(NativeDesktopTheme.font(13)) }
            }.padding(.horizontal, isExpanded ? 10 : 0).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
            .accessibilityLabel("자료 보기 방식: " + displayMode.title).accessibilityIdentifier("native-library-view-menu")
    }
    private func beginCreation(_ kind: Creation) {
        guard let courseID else { return }
        creation = .init(kind: kind, destination: .init(courseID: courseID, folder: folderPath),
                         markdownTitle: markdownTitlePrefix, open: captureOpen?() ?? onOpen)
    }
    private func beginImport() {
        guard let courseID else { return }
        importDestination = .init(courseID: courseID, folder: folderPath)
        importing = true
    }

    private var presentedContent: some View {
        configuredContent
        .sheet(item: $creation) { creationSheet($0) }
        .sheet(item: $moving) { material in
            if let scope, scope.kind == .project { NativeScopedMaterialMovePicker(material: material, scope: scope, store: store) }
            else { NativeMaterialMovePicker(material: material, store: store) }
        }
        .sheet(item: $renaming) { material in
            NativeNameSheet(title: "이름 변경", prompt: "새 이름", initialValue: material.name, actionTitle: "저장") { name in
                try await store.rename(material, to: name)
            }
        }
        .confirmationDialog("\(deleting?.name ?? "자료") 삭제", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let material = deleting {
                Button("삭제", role: .destructive) {
                    perform { try await store.delete(material) }
                    deleting = nil
                }
            }
            Button("취소", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting?.kind == "dir" ? "폴더 안의 모든 자료도 함께 삭제됩니다." : "이 자료를 삭제할까요?")
        }
        .alert("처리하지 못했어요", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("확인", role: .cancel) { operationError = nil }
        } message: { Text(operationError ?? "") }
    }

    var body: some View {
        presentedContent
        .task(id: scopeID + ":" + rootPath) {
            let restored = NativeLibraryBrowsingState.load(scopeID: scopeID, root: rootPath)
            folderPath = restored.folder; query = restored.query; expandedFolders = restored.expanded
            gallerySelection = nil; materialURLs = [:]; loadedScopeID = scopeID
            await projectLibrary.reload(store: store, scope: scope)
        }
        .onChange(of: folderPath) { _, _ in saveBrowsing() }
        .onChange(of: query) { _, _ in saveBrowsing() }
        .onChange(of: expandedFolders) { _, _ in saveBrowsing() }
        .onChange(of: storedDisplayMode) { _, _ in
            if displayMode == .compact { revealFolderInList() }
        }
        .task(id:searchTaskID) { await searchContent() }
        .task(id:store.isReady) {
            if store.isReady, let settings = try? await store.invoke("settings:get") as? [String:Any] { updatePreferences(settings) }
        }
        .onReceive(store.events,perform:receive)
        .onChange(of: store.materials) { _, materials in
            if !folderPath.isEmpty && !NativeLibraryIndex.flatten(materials).contains(where: { $0.relPath == folderPath && $0.kind == "dir" }) { folderPath = rootPath }
        }
    }

    private var searchTaskID: String { "\(scopeID):\(query):\(searchRevision)" }
    private func saveBrowsing() {
        guard loadedScopeID == scopeID else { return }
        NativeLibraryBrowsingState(folder: folderPath, query: query, expanded: expandedFolders).save(scopeID: scopeID)
    }
    private func receive(_ event: NativeWorkspaceEvent) {
        if event.channel == "learning:changed" { Task { await projectLibrary.reload(store: store, scope: scope) }; return }
        if event.channel == "settings:changed", let payload = event.payload as? [String:Any], let settings = payload["settings"] as? [String:Any] { updatePreferences(settings); return }
        guard let payload = event.payload as? [String:Any], payload["courseId"] as? String == courseID else { return }
        if ["search:changed","materials:changed"].contains(event.channel) { searchRevision += 1 }
    }

    private func updatePreferences(_ settings: [String:Any]) {
        markdownTitlePrefix = (settings["tabs"] as? [String:Any])?["markdownTitlePrefix"] as? String ?? "새 마크다운"
    }

    @ViewBuilder private func creationSheet(_ request: CreationRequest) -> some View {
        let destination = request.destination
        switch request.kind {
        case .ink:
            NativeNewNoteSheet(store: store, courseID: destination.courseID, parentPath: destination.folder, onCreated: request.open)
        case .markdown:
            NativeNameSheet(title: "새 마크다운", prompt: request.markdownTitle, defaultValue: request.markdownTitle) { name in
                let document = try await store.createMarkdown(title: name, courseID: destination.courseID, parentPath: destination.folder)
                request.open(document)
            }
        case .folder:
            NativeNameSheet(title: "새 폴더", prompt: "폴더 이름") { name in
                try await store.createFolder(name: name, courseID: destination.courseID, parentPath: destination.folder)
            }
        }
    }

    private struct TreeEntry: Identifiable {
        let material: NativeMaterial
        let depth: Int
        var id: String { material.id }
    }
    private var treeRows: [TreeEntry] {
        func descend(_ materials: [NativeMaterial], depth: Int) -> [TreeEntry] {
            NativeLibraryPresentation.sorted(materials, order: sortOrder).flatMap { material in
                [TreeEntry(material: material, depth: depth)] + (expandedFolders.contains(material.relPath) ? descend(material.children ?? [], depth: depth + 1) : [])
            }
        }
        return descend(scopedMaterials, depth: 0)
    }
    @ViewBuilder private var libraryContent: some View {
        if displayMode == .columns && !isSearching { columnsContent }
        else {
            ScrollView {
                if isSearching || displayMode == .list { listContent }
                else if displayMode == .compact { compactListContent }
                else if displayMode == .icons { iconsContent }
                else { galleryContent }
            }.refreshable { await store.refreshMaterials() }
        }
    }
    private var listContent: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(NativeDesktopTheme.font(13)).foregroundStyle(.red).padding(12)
            }
            if store.isLoading && scopedMaterials.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            } else if items.isEmpty && !isSearching { emptyFolder }
            ForEach(items) { material in materialRow(material) }
            if isSearching {
                contentSearchSection.padding(.horizontal, 10)
                if items.isEmpty && visibleContentHits.isEmpty && !searching {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(NativeDesktopTheme.font(24, weight: .light))
                        Text("검색 결과가 없습니다").font(NativeDesktopTheme.font(14, weight: .medium))
                        Text("다른 검색어를 입력하거나 상위 폴더에서 찾아보세요.")
                            .font(NativeDesktopTheme.font(12)).multilineTextAlignment(.center)
                    }.foregroundStyle(NativeDesktopTheme.muted).frame(maxWidth: .infinity).padding(24)
                }
            }
        }.padding(.horizontal, 8).padding(.bottom, 16)
            .accessibilityElement(children: .contain).accessibilityIdentifier("native-library-list")
    }

    private func materialRow(_ material: NativeMaterial) -> some View {
        Button { open(material) } label: {
            HStack(alignment: .center, spacing: 14) {
                NativeLibraryMaterialThumbnail(store: store, material: material, courseID: courseID,
                    url: materialURL(material), symbol: symbol(material), refresh: isSelected(material) ? "active" : "")
                    .frame(width: isExpanded ? 76 : 58, height: material.isDirectory ? 58 : (isExpanded ? 92 : 76))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NativeDesktopTheme.border.opacity(0.6), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 7) {
                    Text(material.name).font(NativeDesktopTheme.font(isExpanded ? 17 : 15, weight: .medium))
                        .foregroundStyle(NativeDesktopTheme.text).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(material.isDirectory ? "\(material.children?.count ?? 0)개 항목" : materialDate(material))
                        .font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted)
                    if !material.isDirectory {
                        HStack(spacing: 6) {
                            Text(description(material)).font(NativeDesktopTheme.font(11, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 5))
                            if isSearching {
                                let parent = (material.relPath as NSString).deletingLastPathComponent
                                if !parent.isEmpty { Text(parent).font(NativeDesktopTheme.font(11)).lineLimit(1).truncationMode(.middle) }
                            }
                        }.foregroundStyle(NativeDesktopTheme.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if material.isDirectory {
                    Image(systemName: "chevron.right").font(NativeDesktopTheme.font(12, weight: .medium))
                        .foregroundStyle(NativeDesktopTheme.muted)
                }
            }.padding(.horizontal, 10).padding(.vertical, 12).contentShape(Rectangle())
        }
        .background(isSelected(material) ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottom) {
            if !isSelected(material) { NativeDesktopTheme.border.opacity(0.55).frame(height: 0.5).padding(.leading, isExpanded ? 100 : 82).padding(.trailing, 10) }
        }
        .contextMenu { actions(material) }
        .modifier(materialDrag(material))
        .task(id: materialTaskID(material)) { await resolveURL(material) }
        .accessibilityIdentifier("native-material-" + material.relPath)
        .accessibilityAddTraits(isSelected(material) ? .isSelected : [])
    }

    private var compactListContent: some View {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(NativeDesktopTheme.font(12)).foregroundStyle(.red).padding(12)
                }
                if store.isLoading && scopedMaterials.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(24) }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if filesExpanded {
                        ForEach(treeRows) { entry in compactRow(entry.material, depth: entry.depth) }
                    }
                    if scopedMaterials.isEmpty && !store.isLoading {
                        VStack(spacing: 12) {
                            Image(systemName: "tray").font(NativeDesktopTheme.font(24, weight: .light))
                            Text(courseID == nil ? "과목을 선택하세요" : "자료를 가져오거나 새 노트를 만드세요").font(NativeDesktopTheme.font(12)).multilineTextAlignment(.center)
                            Button("파일 가져오기", systemImage: "square.and.arrow.down") { beginImport() }.buttonStyle(NativeToolButtonStyle()).disabled(courseID == nil)
                        }.foregroundStyle(NativeDesktopTheme.muted).frame(maxWidth: .infinity).padding(24)
                    }
                } else {
                    ForEach(items) { material in materialRow(material) }
                    contentSearchSection
                    if items.isEmpty && visibleContentHits.isEmpty && !searching { Text("검색 결과가 없습니다").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted).padding(16) }
                }
            }.padding(.horizontal, 4).padding(.bottom, 16)
    }
    private func compactRow(_ material: NativeMaterial, depth: Int) -> some View {
        Button { open(material) } label: {
            HStack(spacing: 7) {
                if material.isDirectory { Image(systemName: expandedFolders.contains(material.relPath) ? "chevron.down" : "chevron.right").font(NativeDesktopTheme.font(9)).frame(width: 10) }
                else { Color.clear.frame(width: 10, height: 1) }
                Image(systemName: symbol(material)).font(NativeDesktopTheme.font(14)).foregroundStyle(NativeDesktopTheme.muted).frame(width: 17)
                VStack(alignment: .leading, spacing: 3) {
                    Text(material.name).font(NativeDesktopTheme.font(13)).lineLimit(1).foregroundStyle(NativeDesktopTheme.text)
                    if !query.isEmpty { Text(material.relPath).font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }.padding(.leading, CGFloat(depth) * 14 + 8).padding(.trailing, 8).frame(minHeight: 44).padding(.vertical, query.isEmpty ? 0 : 5)
                .contentShape(Rectangle())
        }
        .background(selectedDocumentID == material.document(in: courseID ?? "").id || (material.isDirectory && folderPath == material.relPath) ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu { actions(material) }
        .modifier(materialDrag(material))
        .task(id: materialTaskID(material)) { await resolveURL(material) }
        .accessibilityIdentifier("native-material-\(material.relPath)")
        .accessibilityAddTraits(selectedDocumentID == material.document(in: courseID ?? "").id ? .isSelected : [])
    }

    @ViewBuilder private var contentSearchSection: some View {
                    if !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                        Section("본문 검색") {
                            if searching { ProgressView("본문을 찾는 중…") }
                            if let contentError { Text(contentError).foregroundStyle(NativeDesktopTheme.secondary) }
                            ForEach(visibleContentHits) { hit in
                                Button { open(hit) } label: {
                                    VStack(alignment:.leading,spacing:5) {
                                        Label((hit.relPath as NSString).lastPathComponent,systemImage:hit.kind == "pdf" ? "doc.richtext" : "doc.text").foregroundStyle(.primary).lineLimit(1)
                                        if let page = hit.page { Text("\(page)페이지").font(.caption).foregroundStyle(NativeDesktopTheme.secondary) }
                                        Text(hit.snippet).font(.caption).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(3)
                                    }.padding(.vertical,4)
                                }.accessibilityIdentifier("native-search-hit-" + hit.id)
                            }
                        }
                    }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 0) {
            if folderPath != rootPath {
                Button {
                    let parent = (folderPath as NSString).deletingLastPathComponent
                    folderPath = parent.count < rootPath.count ? rootPath : parent
                    query = ""; gallerySelection = nil
                } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("상위 폴더로").accessibilityIdentifier("native-library-back")
            }
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button(scope?.title ?? "전체 자료", systemImage: "folder") { folderPath = rootPath; query = ""; gallerySelection = nil }
                    .frame(minHeight: 44).contentShape(Rectangle())
                ForEach(Array(folderPath.split(separator: "/").enumerated()).filter { $0.offset >= rootPath.split(separator: "/").count }, id: \.offset) { index, part in
                    Image(systemName: "chevron.right").font(NativeDesktopTheme.font(8)).foregroundStyle(NativeDesktopTheme.muted)
                    Button(String(part)) { folderPath = folderPath.split(separator: "/").prefix(index + 1).joined(separator: "/"); query = ""; gallerySelection = nil }
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
            }.font(NativeDesktopTheme.font(12)).frame(minHeight: 44).padding(.horizontal, 12)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("native-library-breadcrumbs")
    }

    private var iconsContent: some View {
        VStack {
            if items.isEmpty { emptyFolder }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: isExpanded ? 170 : 120, maximum: isExpanded ? 260 : 200), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(items) { material in materialCard(material) }
                }.padding(.horizontal, 12).padding(.bottom, 16)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("native-library-icons")
    }
    private func materialCard(_ material: NativeMaterial) -> some View {
        Button { open(material) } label: {
            VStack(alignment: .leading, spacing: 7) {
                NativeLibraryMaterialThumbnail(store: store, material: material, courseID: courseID, url: materialURL(material), symbol: symbol(material), refresh: isSelected(material) ? "active" : "")
                    .aspectRatio(0.82, contentMode: .fit)
                Text(material.name).font(NativeDesktopTheme.font(isExpanded ? 16 : 14, weight: .medium)).foregroundStyle(NativeDesktopTheme.text).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(material.isDirectory ? "\(material.children?.count ?? 0)개 항목" : materialDate(material))
                    .font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1)
            }.padding(8).background(isSelected(material) ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .contextMenu { actions(material) }
        .modifier(materialDrag(material))
        .task(id: materialTaskID(material)) { await resolveURL(material) }
        .accessibilityIdentifier("native-material-" + material.relPath)
        .accessibilityAddTraits(isSelected(material) ? .isSelected : [])
    }
    private var galleryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let material = galleryMaterial {
                Button { open(material) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        NativeLibraryMaterialThumbnail(store: store, material: material, courseID: courseID, url: materialURL(material), symbol: symbol(material), refresh: isSelected(material) ? "active" : "")
                            .frame(height: 230)
                        Text(material.name).font(NativeDesktopTheme.font(14, weight: .semibold)).foregroundStyle(NativeDesktopTheme.text).lineLimit(2)
                        HStack {
                            Text(materialDate(material)).font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted)
                            Spacer()
                            Label("열기", systemImage: "arrow.up.right").font(NativeDesktopTheme.font(11))
                        }
                    }
                }
                .contextMenu { actions(material) }
                .modifier(materialDrag(material))
                .task(id: materialTaskID(material)) { await resolveURL(material) }
                .accessibilityIdentifier("native-library-gallery-preview")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 8) {
                        ForEach(items.filter { !$0.isDirectory }) { item in
                            Button { gallerySelection = item.relPath } label: {
                                VStack(spacing: 4) {
                                    NativeLibraryMaterialThumbnail(store: store, material: item, courseID: courseID, url: materialURL(item), symbol: symbol(item), refresh: isSelected(item) ? "active" : "")
                                        .frame(width: 70, height: 80)
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(item.relPath == material.relPath ? Color.accentColor : .clear, lineWidth: 2))
                                    Text(item.name).font(NativeDesktopTheme.font(11)).lineLimit(1).frame(width: 70)
                                }.padding(2)
                            }
                            .modifier(materialDrag(item))
                            .task(id: materialTaskID(item)) { await resolveURL(item) }
                            .accessibilityIdentifier("native-gallery-item-" + item.relPath)
                            .accessibilityAddTraits(item.relPath == material.relPath ? .isSelected : [])
                        }
                    }
                }
            }
            ForEach(items.filter(\.isDirectory)) { material in materialRow(material) }
            if items.isEmpty { emptyFolder }
        }.padding(.horizontal, 12).padding(.bottom, 16)
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-library-gallery")
    }
    private var columnsContent: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 6) {
                Text("좌우로 밀어 폴더를 탐색하세요").font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted).padding(.horizontal, 12)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(materialColumns) { column in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 3) {
                                    Text(column.title).font(NativeDesktopTheme.font(11, weight: .semibold)).foregroundStyle(NativeDesktopTheme.muted).padding(.horizontal, 12).padding(.vertical, 8)
                                    ForEach(NativeLibraryPresentation.sorted(column.materials, order: sortOrder)) { material in compactRow(material, depth: 0) }
                                    if column.materials.isEmpty { emptyFolder }
                                }
                            }.frame(width: 220).overlay(alignment: .trailing) { NativeDesktopTheme.border.frame(width: 1) }.id(column.id)
                        }
                    }
                }
            }
            .task {
                await Task.yield()
                proxy.scrollTo(folderPath, anchor: .trailing)
            }
            .onChange(of: folderPath) { _, path in withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(path, anchor: .trailing) } }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("native-library-columns")
    }
    private var emptyFolder: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder").font(NativeDesktopTheme.font(24, weight: .light))
            Text(courseID == nil ? "과목을 선택하세요" : "폴더가 비어 있어요").font(NativeDesktopTheme.font(12))
            if courseID != nil { Button("파일 가져오기", systemImage: "square.and.arrow.down") { beginImport() }.buttonStyle(NativeToolButtonStyle()) }
        }.foregroundStyle(NativeDesktopTheme.muted).frame(maxWidth: .infinity).padding(.vertical, 30)
    }
    private func isSelected(_ material: NativeMaterial) -> Bool {
        selectedDocumentID == material.document(in: courseID ?? "").id || material.isDirectory && folderPath == material.relPath
    }
    private func materialRevision(_ material: NativeMaterial) -> String { "\(material.mtime ?? 0):\(material.size ?? 0)" }
    private func materialTaskID(_ material: NativeMaterial) -> String { (courseID ?? "") + ":" + material.relPath + ":" + materialRevision(material) }
    private func materialURL(_ material: NativeMaterial) -> URL? { materialURLs[(courseID ?? "") + ":" + material.relPath] }
    private func materialDrag(_ material: NativeMaterial) -> NativeLibraryMaterialDrag {
        NativeLibraryMaterialDrag(url: material.isDirectory || material.learningTarget != nil ? nil : materialURL(material),
                                  store: store, document: material.document(in: courseID ?? ""))
    }
    private func resolveURL(_ material: NativeMaterial) async {
        guard !material.isDirectory, material.learningTarget == nil, let course = courseID else { return }
        let key = course + ":" + material.relPath
        do {
            let url = try await NativeLibraryMaterialAccess.url(store: store, courseID: course, relativePath: material.relPath)
            guard !Task.isCancelled, course == courseID else { return }
            materialURLs[key] = url
        } catch { /* Missing/unavailable files retain their type icon. Opening reports the precise error. */ }
    }
    private func materialDate(_ material: NativeMaterial) -> String {
        guard let mtime = material.mtime, mtime.isFinite, mtime > 0 else { return description(material) }
        // Repository mtimes are Unix milliseconds; accept seconds for legacy data.
        let date = Date(timeIntervalSince1970: mtime > 100_000_000_000 ? mtime / 1000 : mtime)
        return date.formatted(date: .numeric, time: .omitted)
    }

    @ViewBuilder private func actions(_ material: NativeMaterial) -> some View {
        Button(material.kind == "dir" ? "폴더 열기" : "열기", systemImage: material.kind == "dir" ? "folder" : "doc") { open(material) }
        if material.learningTarget == nil {
        Button("이름 변경", systemImage: "pencil") { renaming = material }
        Button("폴더로 이동", systemImage: "folder") { moving = material }
        if material.kind != "dir" {
            Button("공유", systemImage: "square.and.arrow.up") {
                guard let courseID else { return }
                perform { _ = try await store.invoke("materials:share", ["courseId": courseID, "relPath": material.relPath]) }
            }
            Button("파일로 내보내기", systemImage: "square.and.arrow.down") {
                guard let courseID else { return }
                perform { _ = try await store.invoke("materials:export", ["courseId": courseID, "relPath": material.relPath]) }
            }
        }
        Divider()
        Button("삭제", systemImage: "trash", role: .destructive) { deleting = material }
        }
    }

    private func open(_ material: NativeMaterial) {
        if material.kind == "dir" {
            gallerySelection = nil
            if displayMode != .compact { folderPath = material.relPath; query = ""; return }
            if expandedFolders.contains(material.relPath) && !isSearching {
                expandedFolders.remove(material.relPath); folderPath = rootPath
            } else {
                folderPath = material.relPath
                revealFolderInList()
            }
            query = ""
        }
        else if let courseID { onOpen(material.document(in: courseID)) }
    }
    private func revealFolderInList() {
        let ancestors = materialColumns.dropFirst().map(\.path)
        expandedFolders.formUnion(ancestors)
        filesExpanded = true
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do { try await operation() } catch { operationError = error.localizedDescription }
        }
    }
    private func symbol(_ material: NativeMaterial) -> String {
        switch material.kind {
        case "learning-article": return "doc.text"
        case "learning-quiz": return "questionmark.square"
        case "learning-exam": return "list.bullet.clipboard"
        case "learning-cards": return "rectangle.on.rectangle"
        case "learning-summary": return "text.alignleft"
        case "learning-overview": return "text.book.closed"
        case "dir": return "folder.fill"
        case "pdf": return "doc.richtext"
        case "note": return "doc.text"
        case "image": return "photo"
        case "video": return "play.rectangle"
        case "whiteboard": return "rectangle.and.pencil.and.ellipsis"
        default: return "doc"
        }
    }
    private func description(_ material: NativeMaterial) -> String {
        if material.learningTarget != nil {
            switch material.kind {
            case "learning-quiz": return "퀴즈"
            case "learning-exam": return "AI 생성 예상문제"
            case "learning-cards": return "플래시카드"
            case "learning-article": return "읽기 자료"
            case "learning-overview": return "표현과 학습 기록"
            default: return "요약"
            }
        }
        if material.kind == "whiteboard" { return "노트" }
        let ext = (material.name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "파일" : "\(ext) 파일"
    }
    private func searchContent() async {
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let course = courseID, !query.isEmpty else { contentHits = []; contentError = nil; searching = false; return }
        do {
            try await Task.sleep(for:.milliseconds(250)); try Task.checkCancellation(); searching = true
            let response = try await store.invoke("search:query",["courseId":course,"query":query,"limit":30])
            try Task.checkCancellation()
            let value: NativeContentResults = try NativeToolJSON.decode(response)
            contentHits = value.hits.filter { hit in (scope?.contains(path: hit.relPath) ?? true) && !hit.relPath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) }; contentError = nil; searching = false
        } catch is CancellationError {} catch { contentError = error.localizedDescription; contentHits = []; searching = false }
    }
    private func open(_ hit:NativeContentHit) {
        guard let courseID else { return }
        // The shell captures this space before flushing and applies the page
        // after the destination editor exists, just like an artifact citation.
        var payload: [String: Any] = ["courseId": courseID, "relPath": hit.relPath, "kind": hit.kind]
        if let page = hit.page, hit.kind == "pdf" { payload["page"] = page }
        store.events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:openDocument", payload: payload))
    }
}

private struct NativeContentResults: Decodable { let hits:[NativeContentHit] }
private struct NativeContentHit: Decodable, Identifiable {
    let kind:String, relPath:String, snippet:String
    let page:Int?
    var id:String { relPath + ":\(page ?? 0)" }
}

/// No directory name is reserved: imported 노트 folders and their non-PDF
/// children remain ordinary, reachable materials.
enum NativeLibraryIndex {
    static func flatten(_ materials: [NativeMaterial]) -> [NativeMaterial] {
        materials.flatMap { [$0] + flatten($0.children ?? []) }
    }
    static func contents(in folder: String, materials: [NativeMaterial]) -> [NativeMaterial] {
        guard !folder.isEmpty else { return materials }
        return flatten(materials).first(where: { $0.kind == "dir" && $0.relPath == folder })?.children ?? []
    }
}
