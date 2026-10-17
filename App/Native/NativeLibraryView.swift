import SwiftUI
import UniformTypeIdentifiers

struct NativeLibraryView: View {
    @ObservedObject var store: NativeWorkspaceStore
    var selectedDocumentID: String? = nil
    var onOpen: (NativeDocumentReference) -> Void
    @State private var query = ""
    @State private var folderPath = ""
    @State private var expandedFolders = Set<String>()
    @State private var filesExpanded = true
    @State private var boardsExpanded = true
    @State private var importing = false
    @State private var creation: Creation?
    @State private var renaming: NativeMaterial?
    @State private var moving: NativeMaterial?
    @State private var deleting: NativeMaterial?
    @State private var operationError: String?
    @State private var working = false
    @State private var boards: [NativeMaterial] = []
    @State private var contentHits: [NativeContentHit] = []
    @State private var searchRevision = 0
    @State private var searching = false
    @State private var contentError: String?
    @State private var markdownTitlePrefix = "새 마크다운"

    private enum Creation: String, Identifiable { case ink, markdown, folder, whiteboard; var id: String { rawValue } }
    private var courseID: String? { store.selectedCourseID }
    private var currentItems: [NativeMaterial] {
        NativeLibraryIndex.contents(in: folderPath, materials: store.materials) + (folderPath.isEmpty ? boards : [])
    }
    private var items: [NativeMaterial] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = search.isEmpty ? currentItems : (NativeLibraryIndex.flatten(store.materials) + boards).filter {
            (folderPath.isEmpty || $0.relPath.hasPrefix(folderPath + "/")) &&
                ($0.name.localizedStandardContains(search) || $0.relPath.localizedStandardContains(search))
        }
        return source.sorted {
            if ($0.kind == "dir") != ($1.kind == "dir") { return $0.kind == "dir" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var configuredContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("자료").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if working { ProgressView().scaleEffect(0.7) }
                    NativeChromeButton(title: "파일 가져오기", symbol: "tray.and.arrow.down") { importing = true }
                        .disabled(courseID == nil || working).accessibilityIdentifier("native-library-import")
                    Menu {
                        Button("새 필기 노트", systemImage: "pencil.tip.crop.circle.badge.plus") { creation = .ink }
                        Button("새 마크다운", systemImage: "doc.badge.plus") { creation = .markdown }
                        Button("새 노트", systemImage: "rectangle.and.pencil.and.ellipsis") { creation = .whiteboard }
                        Divider()
                        Button("새 폴더", systemImage: "folder.badge.plus") { creation = .folder }
                    } label: { Image(systemName: "plus").font(.system(size: 15)).frame(width: 32, height: 36) }
                        .disabled(courseID == nil || working).accessibilityLabel("추가").accessibilityIdentifier("native-library-create")
                    NativeChromeButton(title: "자료 새로고침", symbol: "arrow.clockwise") { Task { await store.refreshMaterials(); await loadBoards() } }
                }
                Label(store.courses.first { $0.id == courseID }?.name ?? "과목을 선택하세요", systemImage: "folder")
                    .font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1)
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                TextField("자료 검색", text: $query).font(.system(size: 12)).textFieldStyle(.plain)
                    .accessibilityIdentifier("native-library-search")
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark").font(.system(size: 10)) }.accessibilityLabel("검색 지우기") }
            }.foregroundStyle(NativeDesktopTheme.muted).padding(.horizontal, 8).frame(height: 32)
                .background(NativeDesktopTheme.raised.opacity(0.65), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 12).padding(.bottom, 12)
            libraryContent
        }
        .background(NativeDesktopTheme.surface)
        .buttonStyle(.plain)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): perform { try await store.importFiles(urls, parentPath: folderPath) }
            case .failure(let error): operationError = error.localizedDescription
            }
        }
    }

    private var presentedContent: some View {
        configuredContent
        .sheet(item: $creation) { creationSheet($0) }
        .sheet(item: $moving) { NativeMaterialMovePicker(material: $0, store: store) }
        .sheet(item: $renaming) { material in
            NativeNameSheet(title: "이름 변경", prompt: "새 이름", initialValue: material.name, actionTitle: "저장") { name in
                if material.kind == "whiteboard", let courseID {
                    _ = try await store.withExternalMutation {
                        _ = try await store.invoke("canvas:rename",["courseId":courseID,"id":material.relPath,"title":name])
                        return ["changedCourseIDs":[courseID]]
                    }
                    await loadBoards()
                } else { try await store.rename(material, to: name) }
            }
        }
        .confirmationDialog("\(deleting?.name ?? "자료") 삭제", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let material = deleting {
                Button("삭제", role: .destructive) {
                    perform {
                        if material.kind == "whiteboard", let courseID {
                            _ = try await store.withExternalMutation {
                                _ = try await store.invoke("canvas:delete",["courseId":courseID,"id":material.relPath])
                                return ["changedCourseIDs":[courseID]]
                            }
                            store.events.send(NativeWorkspaceEvent(channel:"nativeWorkspace:materialDeleted",payload:["courseId":courseID,"relPath":material.relPath,"isDirectory":false]))
                            await loadBoards()
                        } else { try await store.delete(material) }
                    }
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
        .onChange(of: courseID) { _, _ in folderPath = ""; query = ""; expandedFolders = [] }
        .task(id:courseID) { await loadBoards() }
        .task(id:searchTaskID) { await searchContent() }
        .task(id:store.isReady) {
            if store.isReady, let settings = try? await store.invoke("settings:get") as? [String:Any] { updatePreferences(settings) }
        }
        .onReceive(store.events,perform:receive)
        .onChange(of: store.materials) { _, materials in
            if !folderPath.isEmpty && !NativeLibraryIndex.flatten(materials).contains(where: { $0.relPath == folderPath && $0.kind == "dir" }) { folderPath = "" }
        }
    }

    private var searchTaskID: String { "\(courseID ?? ""):\(query):\(searchRevision)" }
    private func receive(_ event: NativeWorkspaceEvent) {
        if event.channel == "settings:changed", let payload = event.payload as? [String:Any], let settings = payload["settings"] as? [String:Any] { updatePreferences(settings); return }
        guard let payload = event.payload as? [String:Any], payload["courseId"] as? String == courseID else { return }
        if ["search:changed","materials:changed"].contains(event.channel) { searchRevision += 1 }
        if ["canvas:changed","materials:changed"].contains(event.channel) { Task { await loadBoards() } }
    }

    private func updatePreferences(_ settings: [String:Any]) {
        markdownTitlePrefix = (settings["tabs"] as? [String:Any])?["markdownTitlePrefix"] as? String ?? "새 마크다운"
    }

    @ViewBuilder private func creationSheet(_ kind: Creation) -> some View {
            switch kind {
            case .whiteboard:
                NativeNameSheet(title:"새 노트",prompt:"노트 이름") { title in
                    guard let courseID else { return }
                    let value = try await store.invoke("canvas:create",["courseId":courseID,"title":title])
                    guard let row = value as? [String:Any], let id = row["id"] as? String else { throw DesktopRuntimeError("노트를 만들지 못했습니다.") }
                    await loadBoards(); onOpen(NativeDocumentReference(courseID:courseID,relativePath:id,title:title,kind:"whiteboard"))
                }
            case .ink: NativeNewNoteSheet(store: store, parentPath:folderPath,onCreated: onOpen)
            case .markdown:
                NativeNameSheet(title: "새 마크다운", prompt: markdownTitlePrefix, defaultValue: markdownTitlePrefix) { name in
                    let document = try await store.createMarkdown(title: name, parentPath: folderPath); onOpen(document)
                }
            case .folder:
                NativeNameSheet(title: "새 폴더", prompt: "폴더 이름") { name in
                    try await store.createFolder(name: name, parentPath: folderPath)
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
            materials.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }.flatMap { material in
                [TreeEntry(material: material, depth: depth)] + (expandedFolders.contains(material.relPath) ? descend(material.children ?? [], depth: depth + 1) : [])
            }
        }
        return descend(store.materials, depth: 0)
    }
    private var libraryContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.red).padding(12)
                }
                if store.isLoading && store.materials.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(24) }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack {
                        Button { boardsExpanded.toggle() } label: {
                            HStack(spacing: 8) {
                                Image(systemName: boardsExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                                Text("노트").font(.system(size: 12, weight: .medium))
                                Text("\(boards.count)").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
                            }.frame(height: 36)
                        }
                        Spacer()
                        Button { creation = .whiteboard } label: { Image(systemName: "plus").font(.system(size: 12)).frame(width: 32, height: 36) }
                            .disabled(courseID == nil).accessibilityLabel("새 노트 만들기")
                    }.padding(.horizontal, 12)
                    if boardsExpanded {
                        ForEach(boards) { material in materialRow(material, depth: 0) }
                        if boards.isEmpty { Text("새 노트를 만들어 생각을 펼쳐보세요.").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted).padding(.horizontal, 16).padding(.bottom, 24) }
                    }
                    Button { filesExpanded.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: filesExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                            Text("파일").font(.system(size: 12, weight: .medium))
                            Spacer()
                            if !folderPath.isEmpty { Text((folderPath as NSString).lastPathComponent).font(.system(size: 10)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1) }
                        }.padding(.horizontal, 12).frame(height: 36)
                    }
                    if filesExpanded {
                        ForEach(treeRows) { entry in materialRow(entry.material, depth: entry.depth) }
                    }
                    if store.materials.isEmpty && !store.isLoading {
                        VStack(spacing: 12) {
                            Image(systemName: "tray").font(.system(size: 24, weight: .light))
                            Text(courseID == nil ? "과목을 선택하세요" : "자료를 가져오거나 새 노트를 만드세요").font(.system(size: 12)).multilineTextAlignment(.center)
                            Button("파일 가져오기") { importing = true }.disabled(courseID == nil)
                        }.foregroundStyle(NativeDesktopTheme.muted).frame(maxWidth: .infinity).padding(24)
                    }
                } else {
                    ForEach(items) { material in materialRow(material, depth: 0) }
                    contentSearchSection
                    if items.isEmpty && contentHits.isEmpty && !searching { Text("검색 결과가 없습니다").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).padding(16) }
                }
            }.padding(.horizontal, 4).padding(.bottom, 16)
        }.refreshable { await store.refreshMaterials() }
    }
    private func materialRow(_ material: NativeMaterial, depth: Int) -> some View {
        Button { open(material) } label: {
            HStack(spacing: 7) {
                if material.isDirectory { Image(systemName: expandedFolders.contains(material.relPath) ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 10) }
                else { Color.clear.frame(width: 10, height: 1) }
                Image(systemName: symbol(material)).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.muted).frame(width: 17)
                VStack(alignment: .leading, spacing: 3) {
                    Text(material.name).font(.system(size: 13)).lineLimit(1).foregroundStyle(NativeDesktopTheme.text)
                    if !query.isEmpty { Text(material.relPath).font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }.padding(.leading, CGFloat(depth) * 14 + 8).padding(.trailing, 8).frame(minHeight: 34).padding(.vertical, query.isEmpty ? 0 : 5)
                .contentShape(Rectangle())
        }
        .background(selectedDocumentID == material.document(in: courseID ?? "").id || (material.isDirectory && folderPath == material.relPath) ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu { actions(material) }
        .accessibilityIdentifier("native-material-\(material.relPath)")
        .accessibilityAddTraits(selectedDocumentID == material.document(in: courseID ?? "").id ? .isSelected : [])
    }

    @ViewBuilder private var contentSearchSection: some View {
                    if !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                        Section("본문 검색") {
                            if searching { ProgressView("본문을 찾는 중…") }
                            if let contentError { Text(contentError).foregroundStyle(.secondary) }
                            ForEach(contentHits.filter { folderPath.isEmpty || $0.relPath.hasPrefix(folderPath + "/") }) { hit in
                                Button { open(hit) } label: {
                                    VStack(alignment:.leading,spacing:5) {
                                        Label((hit.relPath as NSString).lastPathComponent,systemImage:hit.kind == "pdf" ? "doc.richtext" : "doc.text").foregroundStyle(.primary).lineLimit(1)
                                        if let page = hit.page { Text("\(page)페이지").font(.caption).foregroundStyle(.secondary) }
                                        Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }.padding(.vertical,4)
                                }.accessibilityIdentifier("native-search-hit-" + hit.id)
                            }
                        }
                    }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("전체 자료", systemImage: "folder") { folderPath = ""; query = "" }
                ForEach(Array(folderPath.split(separator: "/").enumerated()), id: \.offset) { index, part in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(String(part)) { folderPath = folderPath.split(separator: "/").prefix(index + 1).joined(separator: "/"); query = "" }
                }
            }.font(.subheadline).padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(.bar)
    }

    private func row(_ material: NativeMaterial) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(material)).font(.title2).foregroundStyle(material.kind == "dir" ? Color.accentColor : .secondary)
                .frame(width: 32, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(material.name).font(.body).foregroundStyle(.primary).lineLimit(2)
                if !query.isEmpty { Text(material.relPath).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                else if material.kind == "dir" { Text("\(material.children?.count ?? 0)개 항목").font(.caption).foregroundStyle(.secondary) }
                else { Text(description(material)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if material.kind == "dir" { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 4).contentShape(Rectangle())
    }

    @ViewBuilder private func actions(_ material: NativeMaterial) -> some View {
        Button(material.kind == "dir" ? "폴더 열기" : "열기", systemImage: material.kind == "dir" ? "folder" : "doc") { open(material) }
        Button("이름 변경", systemImage: "pencil") { renaming = material }
        if material.kind != "whiteboard" { Button("폴더로 이동", systemImage: "folder") { moving = material } }
        if material.kind != "dir" && material.kind != "whiteboard" {
            Button("공유", systemImage: "square.and.arrow.up") {
                guard let courseID else { return }
                perform { try await store.flushDocuments(); _ = try await store.invoke("materials:share", ["courseId": courseID, "relPath": material.relPath]) }
            }
        }
        Divider()
        Button("삭제", systemImage: "trash", role: .destructive) { deleting = material }
    }

    private func open(_ material: NativeMaterial) {
        if material.kind == "dir" {
            if !expandedFolders.insert(material.relPath).inserted { expandedFolders.remove(material.relPath); folderPath = "" }
            else { folderPath = material.relPath }
            query = ""
        }
        else if let courseID { onOpen(material.document(in: courseID)) }
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
        if material.kind == "whiteboard" { return "노트" }
        let ext = (material.name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "파일" : "\(ext) 파일"
    }
    private func loadBoards() async {
        guard let course = courseID else { boards = []; return }
        do {
            let rows = try await store.invoke("canvas:list",["courseId":course]) as? [[String:Any]] ?? []
            guard courseID == course else { return }
            boards = rows.compactMap { row in
                guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
                return NativeMaterial(relPath:id,name:title,kind:"whiteboard",children:nil,size:nil,mtime:nil)
            }
        } catch { if courseID == course { operationError = error.localizedDescription } }
    }
    private func searchContent() async {
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let course = courseID, !query.isEmpty else { contentHits = []; contentError = nil; searching = false; return }
        do {
            try await Task.sleep(for:.milliseconds(250)); try Task.checkCancellation(); searching = true
            let response = try await store.invoke("search:query",["courseId":course,"query":query,"limit":30])
            try Task.checkCancellation()
            let value: NativeContentResults = try NativeToolJSON.decode(response)
            contentHits = value.hits; contentError = nil; searching = false
        } catch is CancellationError {} catch { contentError = error.localizedDescription; contentHits = []; searching = false }
    }
    private func open(_ hit:NativeContentHit) {
        guard let courseID else { return }
        perform {
            try await store.flushDocuments()
            if let page = hit.page, hit.kind == "pdf" {
                _ = try await store.invoke("pdf:setViewState",["courseId":courseID,"relPath":hit.relPath,"page":page,"zoom":1])
                store.events.send(NativeWorkspaceEvent(channel:"nativeWorkspace:goToPage",payload:["courseId":courseID,"relPath":hit.relPath,"page":page]))
            }
            onOpen(NativeDocumentReference(courseID:courseID,relativePath:hit.relPath,title:(hit.relPath as NSString).lastPathComponent,kind:hit.kind))
        }
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
