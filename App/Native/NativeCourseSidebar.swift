import SwiftUI

struct NativeCourseSidebar: View {
    var store: NativeWorkspaceStore
    @ObservedObject var navigation: NativeWorkspaceNavigation
    let settings: [String: Any]
    let onSelect: (String) -> Void
    /// Creates a course with this name and opens it.
    let onCreate: (String) async throws -> Void
    let onOpenSettings: (String) -> Void
    let onOpenURL: (String) -> Void
    let onOpenAIWeb: (NativeAIWebShortcut) -> Void
    let descriptor: (NativeDocumentReference) -> [String: Any]?
    let onOpenFavorite: (NativeSidebarFavorite) -> Void
    /// Projects (study spaces) are folders in the same list; one opens as its own workspace.
    var selectedContextID: String? = nil
    var onOpenProject: (NativeWorkspaceContext) -> Void = { _ in }
    /// Set to list the chosen folder's windows under it.
    var windowActions: NativeSidebarWindowActions? = nil
    @StateObject private var catalog = NativeLearningCatalog()
    @State private var deletingProject: NativeLearningSummary?
    @AppStorage("native.desktop.collapsedCourses") private var collapsedCourses = "[]"
    @State private var query = ""
    @State private var renamingID: String?
    /// What the + button's popover shows.
    @State private var adding: Adding?
    private enum Adding: Hashable, Identifiable {
        case course, manage
        /// A new folder inside the one with this id.
        case subfolder(String)
        var id: Self { self }
        var isForm: Bool { if case .manage = self { false } else { true } }
    }
    @State private var archiveCourse: NativeCourse?
    @State private var deletingCourse: NativeCourse?
    @State private var busy = false
    @State private var error: String?
    private var courses: [NativeCourse] { store.courses.filter { $0.workspaceKind != "study-space" } }
    /// The folders inside `id`, in their order; a folder whose parent is not listed (archived, deleted) sits at the top.
    private func children(of id: String?) -> [NativeCourse] {
        courses.filter { course in
            guard let parent = course.parentId, courses.contains(where: { $0.id == parent }) else { return id == nil }
            return parent == id
        }
    }
    /// The tree as rows, depth first, skipping what a collapsed folder holds.
    private var tree: [(course: NativeCourse, depth: Int)] {
        var rows: [(NativeCourse, Int)] = [], seen = Set<String>()
        func walk(_ parent: String?, _ depth: Int) {
            for course in children(of: parent) where seen.insert(course.id).inserted {
                rows.append((course, depth))
                if !contains(course.id, in: collapsedCourses) { walk(course.id, depth + 1) }
            }
        }
        walk(nil, 0)
        return rows
    }
    private func descendants(of id: String) -> Set<String> {
        var result = Set<String>(), queue = [id]
        while let next = queue.popLast() { for child in courses where child.parentId == next && result.insert(child.id).inserted { queue.append(child.id) } }
        return result
    }
    private var visible: [NativeCourse] { courses.filter { query.isEmpty || $0.name.localizedStandardContains(query) } }
    /// Projects keep one order (by name), so a row never moves because its contents changed.
    private var projects: [NativeLearningSummary] {
        catalog.projects.filter { $0.deletedAt == nil && (query.isEmpty || $0.displayName(courses: store.courses).localizedStandardContains(query)) }
            .sorted { $0.displayName(courses: store.courses).localizedStandardCompare($1.displayName(courses: store.courses)) == .orderedAscending }
    }
    private var deletedProjects: [NativeLearningSummary] { catalog.projects.filter { $0.deletedAt != nil } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                NativeRailSearchField(prompt: "폴더 찾기", text: $query, identifier: "native-course-search")
                    // 새 폴더 (Figma 129:3309): under the search field, 16 in from its left edge.
                    .bandalPopover(isPresented: Binding(get: { adding?.isForm == true }, set: { if !$0, adding?.isForm == true { adding = nil } }),
                                   at: .bottomLeading, offset: CGSize(width: 196, height: -11), width: 360, radius: 24, padding: 0) {
                        let parent: NativeCourse? = if case .subfolder(let id) = adding { courses.first { $0.id == id } } else { nil }
                        NativeNewCourseForm(parentName: parent?.name, cancel: { adding = nil }) { name, color in
                            try await onCreate(name); adding = nil
                            guard let id = store.selectedCourseID else { return }
                            if let parent { mutate("courses:move", ["courseId": id, "parentId": parent.id]) }
                            if color != "blue" { mutate("courses:setColor", ["courseId": id, "color": color]) }
                        }
                    }
                // ＋ makes a folder; the rarer actions are on its long-press and in each folder's ⋯ menu.
                Button { adding = .course } label: { Image(systemName: "plus").font(.system(size: 16)).foregroundStyle(NativeGlass.panelIcon).frame(width: 44, height: 34).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("폴더 추가").accessibilityIdentifier("native-course-add-menu")
                    .contextMenu {
                        Button("폴더 관리", systemImage: "folder.badge.gearshape") { adding = .manage }
                    }
                    .bandalPopover(isPresented: Binding(get: { adding == .manage }, set: { if !$0, adding == .manage { adding = nil } }), width: 340) { addingContent }
            }.padding(.leading, 12).padding(.trailing, 9).padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let message = error ?? catalog.error { NativeInlineError(message: message).padding(8) }
                    if !query.isEmpty { ForEach(visible) { courseRow($0, depth: 0) } }
                    else { ForEach(tree, id: \.course.id) { row in courseRow(row.course, depth: row.depth) } }
                    ForEach(projects, content: projectRow)
                    // Not while projects are still loading: a projects-only list would flash this first.
                    if courses.isEmpty && !catalog.loading && catalog.projects.allSatisfy({ $0.deletedAt != nil }) {
                        VStack(spacing: 12) {
                            NativeBandalMark(size: 44).foregroundStyle(NativeDecorMarkStyle())
                            Text("첫 폴더를 만들어보세요").font(NativeDesktopTheme.font(13))
                            Button("새 폴더 만들기") { adding = .course }.buttonStyle(NativeThemedButtonStyle(prominent: true)).accessibilityIdentifier("native-new-course-empty")
                            Button("기존 폴더 연결", systemImage: "folder.badge.plus") { adding = .manage }.buttonStyle(NativeThemedButtonStyle())
                        }.frame(maxWidth: .infinity).padding(.top, 32)
                    } else if !query.isEmpty && visible.isEmpty && projects.isEmpty { Text("일치하는 폴더가 없어요").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted).padding() }
                }.padding(.horizontal, 8).padding(.bottom, 16)
            }
        }.disabled(busy)
            .task { await catalog.reload(store) }
            .onReceive(store.events) { event in
                if ["learning:changed", "courses:changed"].contains(event.channel) { Task { await catalog.reload(store) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: NativeHomeTab.newCourse)) { _ in adding = .course }
    }
    /// One folder: its glyph and name, 14 pt whether chosen or not (the chosen one is medium on a pill).
    /// A folder holding folders, or the chosen one (its favourites), has a chevron; nested folders step in 14 pt
    /// a level, each level under a guide line that comes down from its parent's chevron.
    private func courseRow(_ course: NativeCourse, depth: Int) -> some View {
        // A project inside this folder selects its own row, not this one.
        let selected = store.selectedCourseID == course.id && (selectedContextID?.hasPrefix("project:") != true), collapsed = contains(course.id, in: collapsedCourses)
        let nested = query.isEmpty && !children(of: course.id).isEmpty, indent = CGFloat(min(depth, 6)) * 14
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if selected || nested {
                        Button { toggle(course.id, in: &collapsedCourses) } label: {
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(NativeGlass.panelIcon)
                                .rotationEffect(.degrees(collapsed ? 0 : 90)).animation(.snappy(duration: 0.18), value: collapsed)
                                .frame(width: 30, height: 38).contentShape(Rectangle())
                        }.accessibilityLabel(course.name + (collapsed ? " 펼치기" : " 접기")).accessibilityIdentifier("native-course-expand-" + course.id)
                    } else { Color.clear.frame(width: 30, height: 38) }
                }.padding(.leading, 4 + indent)
                if renamingID == course.id {
                    HStack(spacing: 8) {
                        NativeFolderGlyph(color: course.color, selected: selected).frame(width: 22)
                        BandalInlineEditor(text: course.name, isEditing: renaming(course.id), font: NativeDesktopTheme.font(14, weight: .medium), identifier: "native-course-rename") { name in
                            mutate("courses:rename", ["courseId": course.id, "name": name])
                        }
                    }.frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                } else {
                Button {
                    if collapsed, selected { toggle(course.id, in: &collapsedCourses) }
                    onSelect(course.id)
                } label: {
                    HStack(spacing: 8) {
                        NativeFolderGlyph(color: course.color, selected: selected).frame(width: 22)
                        Text(course.name).font(NativeDesktopTheme.font(14, weight: selected ? .medium : .regular)).foregroundStyle(selected ? NativeGlass.icon : NativeDesktopTheme.text).lineLimit(1)
                        Spacer(minLength: 0)
                        if course.missing == true { Text("연결 끊김").font(NativeDesktopTheme.font(10)).foregroundStyle(.orange) }
                    }.padding(.trailing, selected ? 0 : 8).frame(height: 38).contentShape(Rectangle())
                }.accessibilityIdentifier("native-course-" + course.id).accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu { courseMenu(course) }
                }
                if selected {
                    Menu { courseMenu(course) } label: { Image(systemName: "ellipsis").font(.system(size: 16)).foregroundStyle(NativeGlass.panelIcon).frame(width: 46, height: 38).contentShape(Rectangle()) }.accessibilityLabel(course.name + " 폴더 메뉴")
                }
            }.buttonStyle(.plain)
                .background(selected ? NativeGlass.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                // A tab dropped on the chosen course becomes its favourite.
                .onDrop(of: selected ? [NativeDockDragPayload.contentType] : [], isTargeted: nil) { providers in
                    guard let provider = providers.first else { return false }
                    provider.loadDataRepresentation(forTypeIdentifier: NativeDockDragPayload.contentType.identifier) { data, _ in
                        guard let data, let id = String(data: data, encoding: .utf8) else { return }
                        Task { @MainActor in NotificationCenter.default.post(name: NativeFavoritesSection.request, object: course.id, userInfo: ["documentID": id]) }
                    }
                    return true
                }
                .bandalConfirm("폴더를 보관할까요?", isPresented: Binding(get: { archiveCourse?.id == course.id }, set: { if !$0 { archiveCourse = nil } }),
                               message: "안의 폴더·파일과 즐겨찾기는 유지되고 폴더 관리에서 다시 꺼낼 수 있어요.", action: "보관") {
                    mutate("courses:archive", ["courseId": course.id, "archived": true])
                }
                .bandalConfirm("폴더를 삭제할까요?", isPresented: Binding(get: { deletingCourse?.id == course.id }, set: { if !$0 { deletingCourse = nil } }),
                               message: deleteMessage(course), action: "삭제", destructive: true, identifier: "native-course-delete-confirm") {
                    mutate("courses:delete", ["courseId": course.id])
                }
            if selected && !collapsed {
                // The folder's windows first, then its favourites. Only this folder's: the list is the open workspace's.
                if let windowActions, let ref = navigation.currentWindowRef, ref.workspaceID == "course:" + course.id {
                    NativeSidebarWindowsSection(windows: navigation.windows, activeID: ref.windowID,
                        titles: { id in (navigation.window(.init(workspaceID: ref.workspaceID, windowID: id))?.layout.groups ?? []).compactMap { navigation.document($0.activeID)?.title } },
                        tabCount: { id in navigation.documents(in: .init(workspaceID: ref.workspaceID, windowID: id)).count },
                        actions: windowActions)
                        .padding(.leading, indent)
                }
                NativeFavoritesSection(store: store, courseID: course.id, currentDocument: navigation.active, descriptor: descriptor, documentByID: navigation.document, onOpen: onOpenFavorite)
                    .padding(.leading, indent)
            }
        }
        .background(alignment: .leading) {
            if query.isEmpty { ForEach(0..<min(depth, 6), id: \.self) { level in NativeGlass.treeGuide.frame(width: 1).padding(.leading, 19 + CGFloat(level) * 14).allowsHitTesting(false) } }
        }
    }
    private func deleteMessage(_ course: NativeCourse) -> String {
        let inside = descendants(of: course.id).count
        return (inside > 0 ? "안에 있는 폴더 \(inside)개와 " : "") + "파일이 최근 삭제로 옮겨져요. 폴더 관리 › 최근 삭제에서 복원할 수 있어요."
    }
    /// Where 폴더로 이동 can put a folder: the top level, or any folder not inside it.
    @ViewBuilder private func moveMenu(_ course: NativeCourse) -> some View {
        let blocked = descendants(of: course.id).union([course.id])
        Menu("폴더로 이동", systemImage: "arrow.turn.down.right") {
            if course.parentId != nil { Button("맨 위로", systemImage: "arrow.up.to.line") { mutate("courses:move", ["courseId": course.id, "parentId": NSNull()]) } }
            ForEach(allRows.filter { !blocked.contains($0.course.id) && $0.course.id != course.parentId }, id: \.course.id) { row in
                Button { mutate("courses:move", ["courseId": course.id, "parentId": row.course.id]) } label: {
                    Text(verbatim: String(repeating: "    ", count: row.depth) + row.course.name)
                }
            }
        }
    }
    /// The whole tree, collapsed folders included (the move menu offers every folder).
    private var allRows: [(course: NativeCourse, depth: Int)] {
        var rows: [(NativeCourse, Int)] = [], seen = Set<String>()
        func walk(_ parent: String?, _ depth: Int) { for course in children(of: parent) where seen.insert(course.id).inserted { rows.append((course, depth)); walk(course.id, depth + 1) } }
        walk(nil, 0)
        return rows
    }
    @ViewBuilder private func courseMenu(_ course: NativeCourse) -> some View {
        // The long-press menu as Figma 129:3094 draws it: tiles on top, the move and the pending row, then what the design does not show.
        ControlGroup {
            Button("이름 변경", systemImage: "pencil") { renamingID = course.id }
            Button("폴더 보관", systemImage: "archivebox") { archiveCourse = course }
            Button("폴더 삭제", systemImage: "trash", role: .destructive) { deletingCourse = course }
        }
        Button("하위 폴더 만들기", systemImage: "folder.badge.plus") { adding = .subfolder(course.id) }.accessibilityIdentifier("native-course-add-subfolder")
        moveMenu(course)
        Divider()
        Menu("색상", systemImage: "circle.fill") {
            ForEach(NativeFolderColor.all, id: \.name) { item in
                Button { mutate("courses:setColor", ["courseId": course.id, "color": item.name]) } label: {
                    if course.color == item.name { Label(item.label, systemImage: "checkmark") } else { Text(item.label) }
                }
            }
        }
        if store.selectedCourseID == course.id {
            Menu("즐겨찾기", systemImage: "star") {
                Button("링크 추가", systemImage: "link.badge.plus") { NotificationCenter.default.post(name: NativeFavoritesSection.request, object: course.id) }.accessibilityIdentifier("native-favorite-add-link")
                if let current = navigation.active, descriptor(current) != nil {
                    Button("현재 탭 즐겨찾기에 추가", systemImage: "star") { NotificationCenter.default.post(name: NativeFavoritesSection.request, object: course.id, userInfo: ["current": true]) }.accessibilityIdentifier("native-favorite-add-current")
                }
            }
        }
        Button("폴더 관리", systemImage: "folder.badge.gearshape") { adding = .manage }
    }
    @ViewBuilder private var addingContent: some View {
        switch adding {
        case .manage: NativeCourseManager(store: store, archivedProjects: deletedProjects.map { ($0.id, $0.displayName(courses: store.courses)) }) { id in
            if let project = deletedProjects.first(where: { $0.id == id }) { mutateProject("learning:restore", project) }
        }
        case .course, .subfolder, nil: EmptyView()
        }
    }
    /// A project (study space) is a folder like any other: the same row, the same ⋯ menu; it opens its own workspace.
    private func projectRow(_ project: NativeLearningSummary) -> some View {
        let context = NativeWorkspaceContext.project(project, courses: store.courses), selected = selectedContextID == context.id
        let tint = NativeFolderColor.color(store.courses.first { $0.id == project.binding.courseID }?.color ?? "blue")
        return HStack(spacing: 0) {
            if renamingID == project.id {
                HStack(spacing: 8) {
                    NativeFolderGlyph(tint: tint, selected: selected).frame(width: 22)
                    BandalInlineEditor(text: project.name, isEditing: renaming(project.id), font: NativeDesktopTheme.font(14), identifier: "native-project-rename") { renameProject(project, to: $0) }
                }.padding(.leading, 34).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            } else {
                Button { onOpenProject(context) } label: {
                    HStack(spacing: 8) {
                        NativeFolderGlyph(tint: tint, selected: selected).frame(width: 22)
                        Text(context.title).font(NativeDesktopTheme.font(14, weight: selected ? .medium : .regular)).foregroundStyle(selected ? NativeGlass.icon : NativeDesktopTheme.text).lineLimit(1)
                        Spacer(minLength: 0)
                        if project.dueCardCount > 0 { Text("\(project.dueCardCount)").font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted) }
                    }.padding(.leading, 34).padding(.trailing, selected ? 0 : 8).frame(height: 38).contentShape(Rectangle())
                }.accessibilityIdentifier("native-project-" + project.id).accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu { projectMenu(project) }
                if selected {
                    Menu { projectMenu(project) } label: { Image(systemName: "ellipsis").font(.system(size: 16)).foregroundStyle(NativeGlass.panelIcon).frame(width: 46, height: 38).contentShape(Rectangle()) }
                        .accessibilityLabel(context.title + " 폴더 메뉴")
                }
            }
        }.buttonStyle(.plain)
            .background(selected ? NativeGlass.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
            .bandalConfirm("폴더를 보관할까요?", isPresented: Binding(get: { deletingProject?.id == project.id }, set: { if !$0 { deletingProject = nil } }),
                           message: "자료와 학습 기록은 그대로이고 폴더 관리에서 다시 꺼낼 수 있어요.", action: "보관") {
                mutateProject("learning:delete", project)
            }
    }
    @ViewBuilder private func projectMenu(_ project: NativeLearningSummary) -> some View {
        ControlGroup {
            Button("이름 변경", systemImage: "pencil") { renamingID = project.id }
            Button("폴더 보관", systemImage: "archivebox", role: .destructive) { deletingProject = project }
        }
        Button("폴더 관리", systemImage: "folder.badge.gearshape") { adding = .manage }
    }
    private func renameProject(_ project: NativeLearningSummary, to name: String) {
        Task { @MainActor in
            do {
                _ = try await store.invoke("learning:rename", ["binding": project.binding.request, "name": name])
                await catalog.reload(store); error = nil
                if selectedContextID == NativeWorkspaceContext.project(project).id {
                    var context = NativeWorkspaceContext.project(project, courses: store.courses); context.title = name; onOpenProject(context)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func mutateProject(_ channel: String, _ project: NativeLearningSummary) {
        Task { @MainActor in
            do {
                if channel == "learning:delete" { try await store.flushDocuments() }
                _ = try await store.invoke(channel, ["binding": project.binding.request]); await catalog.reload(store); error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    private func renaming(_ id: String) -> Binding<Bool> {
        .editing(id, in: $renamingID)
    }
    private func mutate(_ channel: String, _ request: [String: Any]) {
        guard !busy else { return }; busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await store.flushDocuments(); _ = try await store.invoke(channel, request) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func contains(_ id: String, in raw: String) -> Bool { (try? JSONDecoder().decode(Set<String>.self, from: Data(raw.utf8)))?.contains(id) == true }
    private func toggle(_ id: String, in raw: inout String) {
        var values = (try? JSONDecoder().decode(Set<String>.self, from: Data(raw.utf8))) ?? []
        if !values.insert(id).inserted { values.remove(id) }
        if let data = try? JSONEncoder().encode(values), let string = String(data: data, encoding: .utf8) { raw = string }
    }
}

/// 새 과목 (Figma 129:3309): 취소 · 만들기 on top, the name, a colour, and where linked folders live.
private struct NativeNewCourseForm: View {
    /// Set when the folder is made inside another one.
    var parentName: String? = nil
    let cancel: () -> Void
    let create: @MainActor (String, String) async throws -> Void
    @State private var name = ""
    @State private var color = "blue"
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool
    private static let colors: [(String, Color)] = NativeFolderColor.all.map { ($0.name, NativeFolderColor.color($0.name)) }
    private var ready: Bool { !busy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                VStack(spacing: 1) {
                    BandalText(parentName == nil ? "새 폴더" : "하위 폴더").fontWeight(.semibold).foregroundStyle(NativeDesktopTheme.text)
                    if let parentName { Text(verbatim: parentName).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1) }
                }
                HStack {
                    Button(action: cancel) { BandalText("취소") }.accessibilityIdentifier("native-course-cancel")
                    Spacer()
                    Button(action: submit) { BandalText("만들기").fontWeight(.semibold) }.disabled(!ready).opacity(ready ? 1 : 0.35).accessibilityIdentifier("native-create-course")
                }.foregroundStyle(NativeGlass.accent)
            }.font(.system(size: 17)).buttonStyle(.plain).padding(.horizontal, 20).frame(height: 52)
            VStack(alignment: .leading, spacing: 14) {
                TextField("폴더 이름", text: $name).font(.system(size: 17)).textFieldStyle(.plain).focused($focused).onSubmit(submit).disabled(busy)
                    .padding(.horizontal, 14).frame(height: 46)
                    .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("native-course-name")
                BandalText("색").font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary).frame(height: 16)
                HStack(spacing: 10) {
                    ForEach(Self.colors, id: \.0) { value, tint in
                        Button { color = value } label: {
                            Circle().fill(tint).frame(width: 20, height: 20).frame(width: 30, height: 30)
                                .overlay { if color == value { Circle().strokeBorder(NativeGlass.accent, lineWidth: 2) } }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(NativeFolderColor.label(value)).accessibilityAddTraits(color == value ? .isSelected : [])
                            .accessibilityIdentifier("native-course-color-" + value)
                    }
                }
                if let error { Text(error).font(.system(size: 13)).foregroundStyle(.red).lineLimit(2) }
            }.padding(.horizontal, 20).padding(.vertical, 8)
            BandalText("나중에 ‘기존 폴더 연결’로 파일 앱 폴더를 붙일 수 있어요.").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.vertical, 16)
        }.onAppear { focused = true }
    }
    private func submit() {
        guard ready else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await create(name.trimmingCharacters(in: .whitespacesAndNewlines), color) } catch { self.error = error.localizedDescription }
        }
    }
}

/// The folder colours: one palette for the new-folder form, the 색상 menu and every folder glyph.
enum NativeFolderColor {
    static let all: [(name: String, label: LocalizedStringKey)] = [("blue", "파랑"), ("green", "초록"), ("purple", "보라"), ("orange", "주황"),
                                                                 ("red", "빨강"), ("pink", "분홍"), ("yellow", "노랑"), ("gray", "회색")]
    static func label(_ name: String) -> LocalizedStringKey { all.first { $0.name == name }?.label ?? "파랑" }
    static func color(_ name: String) -> Color {
        switch name {
        case "red": Color(uiColor: .systemRed)
        case "orange": Color(uiColor: .systemOrange)
        case "yellow", "gold": NativeDesktopTheme.adaptive(0xf5b83d, 0xe6a93a)
        case "green": Color(uiColor: .systemGreen)
        case "purple": Color(uiColor: .systemPurple)
        case "pink": Color(uiColor: .systemPink)
        case "gray": NativeDesktopTheme.secondary
        default: NativeDesktopTheme.adaptive(0x3b6fe0, 0x5a8af0)
        }
    }
}

/// A folder's mark, as the desktop app draws it: the outline of a folder with a short bar of the folder's
/// colour inside, low on the left. The outline is the row's own ink (darker on the chosen row); only the bar is coloured.
struct NativeFolderGlyph: View {
    let tint: Color
    var selected = false
    /// The glyph's width; it is four fifths as tall.
    var size: CGFloat = 20
    init(tint: Color, selected: Bool = false, size: CGFloat = 20) { self.tint = tint; self.selected = selected; self.size = size }
    init(color: String, selected: Bool = false, size: CGFloat = 20) { self.init(tint: NativeFolderColor.color(color), selected: selected, size: size) }
    var body: some View {
        let height = (size * 0.8).rounded(), line = max(1.2, size * 0.075)
        NativeFolderOutline().stroke(selected ? NativeGlass.icon : NativeGlass.panelIcon, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            .padding(line / 2)
            .overlay(alignment: .bottomLeading) {
                Capsule().fill(tint).frame(width: size * 0.36, height: max(2, size * 0.11))
                    .padding(.leading, size * 0.2).padding(.bottom, height * 0.2)
            }
            .frame(width: size, height: height)
            .accessibilityHidden(true)
    }
}
/// A folder seen from the front: a rounded body with its tab at the top left, sloping down into the top edge.
struct NativeFolderOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, r = min(w, h) * 0.2
        let tabWidth = w * 0.44, tabHeight = h * 0.17, slope = h * 0.17
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + tabWidth - slope, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + tabWidth, y: rect.minY + tabHeight))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY + tabHeight))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tabHeight + r), control: CGPoint(x: rect.maxX, y: rect.minY + tabHeight))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A button on a glass panel or the empty workspace in the decor's colours: `prominent` fills it with the
/// accent (white label), otherwise a soft accent wash with an accent label.
struct NativeThemedButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NativeDesktopTheme.font(14, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(NativeGlass.accent))
            .padding(.horizontal, 16).frame(minHeight: 40)
            .background {
                Capsule().fill(prominent ? AnyShapeStyle(NativeGlass.accent) : AnyShapeStyle(NativeGlass.accentSoft))
                    .overlay { if prominent { Capsule().fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)) } }
                    .shadow(color: .black.opacity(prominent ? 0.12 : 0), radius: 6, y: 2)
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// An error in a list or panel: an orange mark and the message, not raw red text.
struct NativeInlineError: View {
    let message: String
    var body: some View {
        Label { BandalText(message).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }.font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary)
    }
}
