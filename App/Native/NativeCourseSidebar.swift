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
    @StateObject private var catalog = NativeLearningCatalog()
    @State private var deletingProject: NativeLearningSummary?
    @AppStorage("native.desktop.collapsedCourses") private var collapsedCourses = "[]"
    @AppStorage("native.desktop.collapsedCourseGroups") private var collapsedGroups = "[]"
    @State private var groups: [NativeSidebarCourseGroup] = []
    @State private var query = ""
    @State private var renamingID: String?
    /// What the + button's popover shows.
    @State private var adding: Adding?
    private enum Adding: Identifiable { case course, group, manage; var id: Self { self } }
    @State private var archiveCourse: NativeCourse?
    @State private var deletingGroup: NativeSidebarCourseGroup?
    @State private var busy = false
    @State private var error: String?
    private var courses: [NativeCourse] { store.courses.filter { $0.workspaceKind != "study-space" } }
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
                    .bandalPopover(isPresented: Binding(get: { adding == .course }, set: { if !$0, adding == .course { adding = nil } }),
                                   at: .bottomLeading, offset: CGSize(width: 196, height: -11), width: 360, radius: 24, padding: 0) {
                        NativeNewCourseForm(cancel: { adding = nil }) { name, color in
                            try await onCreate(name); adding = nil
                            if color != "blue", let id = store.selectedCourseID { mutate("courses:setColor", ["courseId": id, "color": color]) }
                        }
                    }
                // ＋ makes a folder; the rarer actions are on its long-press and in each folder's ⋯ menu.
                Button { adding = .course } label: { Image(systemName: "plus").font(.system(size: 16)).foregroundStyle(NativeGlass.panelIcon).frame(width: 44, height: 34).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("폴더 추가").accessibilityIdentifier("native-course-add-menu")
                    .contextMenu {
                        Button("그룹 만들기", systemImage: "folder") { adding = .group }
                        Button("폴더 관리", systemImage: "folder.badge.gearshape") { adding = .manage }
                    }
                    .bandalPopover(isPresented: Binding(get: { adding == .group || adding == .manage }, set: { if !$0, adding != .course { adding = nil } }), width: adding == .manage ? 340 : 280) { addingContent }
            }.padding(.leading, 12).padding(.trailing, 9).padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let message = error ?? catalog.error { NativeInlineError(message: message).padding(8) }
                    if !query.isEmpty { ForEach(visible, content: courseRow) }
                    else {
                        ForEach(groups) { group in
                            groupHeading(group)
                            if !contains(group.id, in: collapsedGroups) { ForEach(courses.filter { $0.groupId == group.id }, content: courseRow) }
                        }
                        ForEach(courses.filter { course in course.groupId == nil || !groups.contains { $0.id == course.groupId } }, content: courseRow)
                    }
                    ForEach(projects, content: projectRow)
                    // Not while projects are still loading: a projects-only list would flash this first.
                    if courses.isEmpty && !catalog.loading && catalog.projects.allSatisfy({ $0.deletedAt != nil }) {
                        VStack(spacing: 12) {
                            NativeBandalMark(size: 44).foregroundStyle(NativeDecorMarkStyle())
                            Text("첫 폴더를 만들어보세요").font(NativeDesktopTheme.font(13))
                            Button("새 폴더 만들기") { adding = .course }.buttonStyle(.borderedProminent).accessibilityIdentifier("native-new-course-empty")
                            Button("기존 폴더 연결", systemImage: "folder.badge.plus") { adding = .manage }.buttonStyle(.bordered)
                        }.frame(maxWidth: .infinity).padding(.top, 32)
                    } else if !query.isEmpty && visible.isEmpty && projects.isEmpty { Text("일치하는 폴더가 없어요").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted).padding() }
                }.padding(.horizontal, 8).padding(.bottom, 16)
            }
        }.disabled(busy)
            .task { await loadGroups() }
            .task { await catalog.reload(store) }
            .onReceive(store.events) { event in
                if event.channel == "courses:changed" { Task { await loadGroups() } }
                if ["learning:changed", "courses:changed"].contains(event.channel) { Task { await catalog.reload(store) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: NativeHomeTab.newCourse)) { _ in adding = .course }
    }
    /// The chosen course: 13 Medium on a 38 pt pill with its chevron and ⋯. The others: a 16 pt folder and 14 pt name, their menu on a long-press.
    private func courseRow(_ course: NativeCourse) -> some View {
        // A project inside this folder selects its own row, not this one.
        let selected = store.selectedCourseID == course.id && (selectedContextID?.hasPrefix("project:") != true), collapsed = contains(course.id, in: collapsedCourses)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                if selected {
                    Button { toggle(course.id, in: &collapsedCourses) } label: {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 13)).foregroundStyle(NativeGlass.panelIcon).frame(width: 30, height: 38).padding(.leading, 4).contentShape(Rectangle())
                    }.accessibilityLabel(course.name + (collapsed ? " 펼치기" : " 접기")).accessibilityIdentifier("native-course-expand-" + course.id)
                }
                if renamingID == course.id {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(NativeFolderColor.color(course.color)).frame(width: 20)
                        BandalInlineEditor(text: course.name, isEditing: renaming(course.id), font: NativeDesktopTheme.font(13, weight: .medium), identifier: "native-course-rename") { name in
                            mutate("courses:rename", ["courseId": course.id, "name": name])
                        }
                    }.padding(.leading, selected ? 0 : 34).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                } else {
                Button {
                    if collapsed { toggle(course.id, in: &collapsedCourses) }
                    onSelect(course.id)
                } label: {
                    HStack(spacing: selected ? 6 : 8) {
                        Image(systemName: "folder.fill").font(.system(size: selected ? 14 : 16)).foregroundStyle(NativeFolderColor.color(course.color)).frame(width: selected ? 20 : 22)
                        Text(course.name).font(NativeDesktopTheme.font(selected ? 13 : 14, weight: selected ? .medium : .regular)).foregroundStyle(selected ? NativeGlass.icon : NativeDesktopTheme.text).lineLimit(1)
                        Spacer(minLength: 0)
                        if course.missing == true { Text("연결 끊김").font(NativeDesktopTheme.font(10)).foregroundStyle(.orange) }
                    }.padding(.leading, selected ? 0 : 34).padding(.trailing, selected ? 0 : 8).frame(height: 38).contentShape(Rectangle())
                }.accessibilityIdentifier("native-course-" + course.id)
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
                               message: "파일과 즐겨찾기는 유지되고 보관된 폴더 관리에서 다시 꺼낼 수 있어요.", action: "보관") {
                    mutate("courses:archive", ["courseId": course.id, "archived": true])
                }
            if selected && !collapsed {
                NativeFavoritesSection(store: store, courseID: course.id, currentDocument: navigation.active, descriptor: descriptor, documentByID: navigation.document, onOpen: onOpenFavorite)
            }
        }
    }
    @ViewBuilder private func courseMenu(_ course: NativeCourse) -> some View {
        // The long-press menu as Figma 129:3094 draws it: tiles on top, the move and the pending row, then what the design does not show.
        ControlGroup {
            Button("이름 변경", systemImage: "pencil") { renamingID = course.id }
            Button("폴더 보관", systemImage: "archivebox", role: .destructive) { archiveCourse = course }
        }
        Menu("그룹으로 이동", systemImage: "folder") {
            Button("그룹 없음") { mutate("courses:organize", ["courseId": course.id, "groupId": NSNull()]) }
            ForEach(groups) { group in Button(group.name) { mutate("courses:organize", ["courseId": course.id, "groupId": group.id]) } }
        }
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
        Button("그룹 만들기", systemImage: "folder") { adding = .group }
        Button("폴더 관리", systemImage: "folder.badge.gearshape") { adding = .manage }
    }
    private func groupHeading(_ group: NativeSidebarCourseGroup) -> some View {
        HStack {
            if renamingID == group.id {
                BandalInlineEditor(text: group.name, isEditing: renaming(group.id), font: NativeDesktopTheme.font(12, weight: .medium), identifier: "native-group-rename") { name in
                    mutate("courseGroups:rename", ["groupId": group.id, "name": name])
                }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            } else {
                Button { toggle(group.id, in: &collapsedGroups) } label: { Label(group.name, systemImage: contains(group.id, in: collapsedGroups) ? "chevron.right" : "chevron.down").frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle()) }
            }
            Menu {
                Button("그룹 이름 변경") { renamingID = group.id }
                Button("그룹 삭제", role: .destructive) { deletingGroup = group }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 36).contentShape(Rectangle()) }.accessibilityLabel(group.name + " 그룹 메뉴")
        }.buttonStyle(.plain).font(NativeDesktopTheme.font(12, weight: .medium)).foregroundStyle(NativeDesktopTheme.muted).padding(.leading, 8)
            .bandalConfirm("그룹을 삭제할까요?", isPresented: Binding(get: { deletingGroup?.id == group.id }, set: { if !$0 { deletingGroup = nil } }),
                           message: "그룹 안의 폴더는 그대로 남아요.", action: "그룹 삭제", destructive: true) {
                mutate("courseGroups:delete", ["groupId": group.id])
            }
    }
    @ViewBuilder private var addingContent: some View {
        switch adding {
        case .group:
            BandalTextEntry(title: "새 그룹", prompt: "그룹 이름", actionTitle: "만들기", identifier: "native-group-name") { name in
                adding = nil; mutate("courseGroups:create", ["name": name])
            }
        case .manage: NativeCourseManager(store: store, archivedProjects: deletedProjects.map { ($0.id, $0.displayName(courses: store.courses)) }) { id in
            if let project = deletedProjects.first(where: { $0.id == id }) { mutateProject("learning:restore", project) }
        }
        case .course, nil: EmptyView()
        }
    }
    /// A project (study space) is a folder like any other: the same row, the same ⋯ menu; it opens its own workspace.
    private func projectRow(_ project: NativeLearningSummary) -> some View {
        let context = NativeWorkspaceContext.project(project, courses: store.courses), selected = selectedContextID == context.id
        let tint = NativeFolderColor.color(store.courses.first { $0.id == project.binding.courseID }?.color ?? "blue")
        return HStack(spacing: 0) {
            if renamingID == project.id {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").font(.system(size: 16)).foregroundStyle(tint).frame(width: 22)
                    BandalInlineEditor(text: project.name, isEditing: renaming(project.id), font: NativeDesktopTheme.font(14), identifier: "native-project-rename") { renameProject(project, to: $0) }
                }.padding(.leading, 34).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            } else {
                Button { onOpenProject(context) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").font(.system(size: 16)).foregroundStyle(tint).frame(width: 22)
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
            do { try await store.flushDocuments(); _ = try await store.invoke(channel, request); await loadGroups() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func loadGroups() async {
        do { let loaded: [NativeSidebarCourseGroup] = try NativeToolJSON.decode(try await store.invoke("courseGroups:list")); if !Task.isCancelled { groups = loaded } }
        catch { self.error = error.localizedDescription }
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
                BandalText("새 폴더").fontWeight(.semibold).foregroundStyle(NativeDesktopTheme.text)
                HStack {
                    Button(action: cancel) { BandalText("취소") }.accessibilityIdentifier("native-course-cancel")
                    Spacer()
                    Button(action: submit) { BandalText("만들기").fontWeight(.semibold) }.disabled(!ready).opacity(ready ? 1 : 0.35).accessibilityIdentifier("native-create-course")
                }.foregroundStyle(NativeDesktopTheme.accent)
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
                                .overlay { if color == value { Circle().strokeBorder(NativeDesktopTheme.accent, lineWidth: 2) } }
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

/// An error in a list or panel: an orange mark and the message, not raw red text.
struct NativeInlineError: View {
    let message: String
    var body: some View {
        Label { BandalText(message).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }.font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary)
    }
}
