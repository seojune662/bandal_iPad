import SwiftUI

struct NativeCourseSidebar: View {
    var store: NativeWorkspaceStore
    @ObservedObject var navigation: NativeWorkspaceNavigation
    let settings: [String: Any]
    let onSelect: (String) -> Void
    let onCreate: () -> Void
    let onManage: () -> Void
    let onOpenSettings: (String) -> Void
    let onOpenURL: (String) -> Void
    let onOpenAIWeb: (NativeAIWebShortcut) -> Void
    let descriptor: (NativeDocumentReference) -> [String: Any]?
    let onOpenFavorite: (NativeSidebarFavorite) -> Void
    @AppStorage("native.desktop.collapsedCourses") private var collapsedCourses = "[]"
    @AppStorage("native.desktop.collapsedCourseGroups") private var collapsedGroups = "[]"
    @State private var groups: [NativeSidebarCourseGroup] = []
    @State private var query = ""
    @State private var renamingID: String?
    @State private var creatingGroup = false
    @State private var archiveCourse: NativeCourse?
    @State private var deletingGroup: NativeSidebarCourseGroup?
    @State private var busy = false
    @State private var error: String?
    private var courses: [NativeCourse] { store.courses.filter { $0.workspaceKind != "study-space" } }
    private var visible: [NativeCourse] { courses.filter { query.isEmpty || $0.name.localizedStandardContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                NativeRailSearchField(prompt: "과목 찾기", text: $query, identifier: "native-course-search")
                Menu {
                    Button("새 과목 만들기", systemImage: "plus") { onCreate() }.accessibilityIdentifier("native-new-course")
                    Button("폴더에서 추가", systemImage: "folder.badge.plus") { onManage() }
                    Button("과목 그룹 만들기", systemImage: "folder") { creatingGroup = true }
                    Button("보관된 과목 관리", systemImage: "archivebox") { onManage() }
                } label: { Image(systemName: "plus").foregroundStyle(NativeDesktopTheme.secondary).frame(width: 40, height: 40).contentShape(Rectangle()) }
                .accessibilityLabel("과목 추가").accessibilityIdentifier("native-course-add-menu")
                .bandalPopover(isPresented: $creatingGroup) {
                    BandalTextEntry(title: "새 그룹", prompt: "그룹 이름", actionTitle: "만들기", identifier: "native-group-name") { name in
                        creatingGroup = false; mutate("courseGroups:create", ["name": name])
                    }
                }
            }.padding(.leading, 12).padding(.trailing, 6).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let error { Text(error).font(NativeDesktopTheme.font(11)).foregroundStyle(.red).padding(8) }
                    if !query.isEmpty { ForEach(visible, content: courseRow) }
                    else {
                        ForEach(groups) { group in
                            groupHeading(group)
                            if !contains(group.id, in: collapsedGroups) { ForEach(courses.filter { $0.groupId == group.id }, content: courseRow) }
                        }
                        ForEach(courses.filter { course in course.groupId == nil || !groups.contains { $0.id == course.groupId } }, content: courseRow)
                    }
                    if courses.isEmpty {
                        VStack(spacing: 12) {
                            NativeBandalMark(size: 44).foregroundStyle(NativeDesktopTheme.muted.opacity(0.4))
                            Text("첫 과목을 만들어보세요").font(NativeDesktopTheme.font(13))
                            Button("폴더에서 추가", systemImage: "folder.badge.plus", action: onManage).buttonStyle(.bordered)
                            Button("새 과목 만들기", action: onCreate).accessibilityIdentifier("native-new-course-empty")
                        }.frame(maxWidth: .infinity).padding(.top, 32)
                    } else if !query.isEmpty && visible.isEmpty { Text("일치하는 과목이 없어요").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted).padding() }
                }.padding(.horizontal, 8).padding(.bottom, 16)
            }
        }.background(NativeDesktopTheme.surface).disabled(busy)
            .task { await loadGroups() }
            .onReceive(store.events) { event in if event.channel == "courses:changed" { Task { await loadGroups() } } }
    }
    private func courseRow(_ course: NativeCourse) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { toggle(course.id, in: &collapsedCourses) } label: {
                    Image(systemName: contains(course.id, in: collapsedCourses) ? "chevron.right" : "chevron.down").font(.system(size: 10)).frame(width: 44, height: 44)
                }.accessibilityLabel(course.name + (contains(course.id, in: collapsedCourses) ? " 펼치기" : " 접기")).accessibilityIdentifier("native-course-expand-" + course.id)
                if renamingID == course.id {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.muted)
                        BandalInlineEditor(text: course.name, isEditing: renaming(course.id), font: NativeDesktopTheme.font(13), identifier: "native-course-rename") { name in
                            mutate("courses:rename", ["courseId": course.id, "name": name])
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                } else {
                Button {
                    if contains(course.id, in: collapsedCourses) { toggle(course.id, in: &collapsedCourses) }
                    onSelect(course.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.muted)
                        Text(course.name).lineLimit(1)
                        Circle().fill(color(course.color)).frame(width: 6, height: 6).accessibilityHidden(true)
                        Spacer(minLength: 0)
                        if course.missing == true { Text("연결 끊김").font(NativeDesktopTheme.font(10)).foregroundStyle(.orange) }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.accessibilityIdentifier("native-course-" + course.id)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { renamingID = course.id })
                }
                Menu { courseMenu(course) } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel(course.name + " 과목 메뉴")
            }.font(NativeDesktopTheme.font(13)).buttonStyle(.plain)
                .background(store.selectedCourseID == course.id ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 6))
                .bandalConfirm("과목을 보관할까요?", isPresented: Binding(get: { archiveCourse?.id == course.id }, set: { if !$0 { archiveCourse = nil } }),
                               message: "파일과 즐겨찾기는 유지되고 과목 관리에서 다시 꺼낼 수 있어요.", action: "보관") {
                    mutate("courses:archive", ["courseId": course.id, "archived": true])
                }
            if !contains(course.id, in: collapsedCourses) {
                NativeFavoritesSection(store: store, courseID: course.id, currentDocument: navigation.active, descriptor: descriptor, documentByID: navigation.document, onOpen: onOpenFavorite)
            }
        }
    }
    @ViewBuilder private func courseMenu(_ course: NativeCourse) -> some View {
        Button("이름 변경", systemImage: "pencil") { renamingID = course.id }
        Menu("색상", systemImage: "circle.fill") { ForEach([("blue", "파랑"), ("green", "초록"), ("purple", "보라"), ("orange", "주황"), ("red", "빨강"), ("pink", "분홍"), ("yellow", "노랑")], id: \.0) { value, name in Button(name) { mutate("courses:setColor", ["courseId": course.id, "color": value]) } } }
        Menu("그룹으로 이동", systemImage: "folder") {
            Button("그룹 없음") { mutate("courses:organize", ["courseId": course.id, "groupId": NSNull()]) }
            ForEach(groups) { group in Button(group.name) { mutate("courses:organize", ["courseId": course.id, "groupId": group.id]) } }
        }
        Button("과목 보관", systemImage: "archivebox") { archiveCourse = course }
        Button("폴더 연결 및 보관 관리", systemImage: "folder.badge.gearshape", action: onManage)
    }
    private func groupHeading(_ group: NativeSidebarCourseGroup) -> some View {
        HStack {
            if renamingID == group.id {
                BandalInlineEditor(text: group.name, isEditing: renaming(group.id), font: NativeDesktopTheme.font(12, weight: .medium), identifier: "native-group-rename") { name in
                    mutate("courseGroups:rename", ["groupId": group.id, "name": name])
                }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            } else {
                Button { toggle(group.id, in: &collapsedGroups) } label: { Label(group.name, systemImage: contains(group.id, in: collapsedGroups) ? "chevron.right" : "chevron.down").frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle()) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { renamingID = group.id })
            }
            Menu {
                Button("그룹 이름 변경") { renamingID = group.id }
                Button("그룹 삭제", role: .destructive) { deletingGroup = group }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 32) }
        }.buttonStyle(.plain).font(NativeDesktopTheme.font(12, weight: .medium)).foregroundStyle(NativeDesktopTheme.muted).padding(.leading, 8)
            .bandalConfirm("그룹을 삭제할까요?", isPresented: Binding(get: { deletingGroup?.id == group.id }, set: { if !$0 { deletingGroup = nil } }),
                           message: "그룹 안의 과목은 그대로 남아요.", action: "그룹 삭제", destructive: true) {
                mutate("courseGroups:delete", ["groupId": group.id])
            }
    }
    private func renaming(_ id: String) -> Binding<Bool> {
        Binding(get: { renamingID == id }, set: { renamingID = $0 ? id : nil })
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
    private func color(_ value: String) -> Color {
        switch value { case "red": .red; case "orange": .orange; case "yellow", "gold": .yellow; case "green": .green; case "purple": .purple; case "pink": .pink; default: .blue }
    }
}
