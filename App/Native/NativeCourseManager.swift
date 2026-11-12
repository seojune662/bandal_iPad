import SwiftUI

struct NativeCourseManager: View {
    var store: NativeWorkspaceStore
    /// Folders kept from AI study (projects) that were archived, with their names; restored by id.
    var archivedProjects: [(id: String, name: String)] = []
    var restoreProject: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var courses: [ManagedCourse] = []
    @State private var renamingID: String?
    @State private var busy = false
    @State private var error: String?
    @State private var purging: ManagedCourse?
    private struct ManagedCourse: Decodable, Identifiable {
        let id: String
        let name: String
        let color: String
        let archived: Bool
        let missing: Bool
        var parentId: String? = nil
        var deletedAt: String? = nil
    }
    /// 최근 삭제 lists what was deleted, each folder once: one deleted along with its parent is inside that row.
    private var deleted: [ManagedCourse] {
        courses.filter { course in
            guard let stamp = course.deletedAt else { return false }
            return !courses.contains { $0.id == course.parentId && $0.deletedAt == stamp }
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            if let error { NativeInlineError(message: error) }
            ScrollView {
                VStack(alignment:.leading,spacing:0) {
                    ForEach([false,true],id:\.self) { archived in
                        let values = courses.filter { $0.archived == archived && $0.deletedAt == nil }
                        if !values.isEmpty {
                            BandalSectionHeader(archived ? "보관한 폴더" : "내 폴더").padding(.horizontal,8).padding(.top,4)
                            ForEach(values) { course in row(course) }
                            if archived { archivedProjectRows }
                        }
                    }
                    if !courses.contains(where: { $0.archived && $0.deletedAt == nil }), !archivedProjects.isEmpty {
                        BandalSectionHeader("보관한 폴더").padding(.horizontal,8).padding(.top,4)
                        archivedProjectRows
                    }
                    if !deleted.isEmpty {
                        BandalSectionHeader("최근 삭제").padding(.horizontal,8).padding(.top,4)
                        ForEach(deleted) { course in deletedRow(course) }
                    }
                }
            }.frame(maxHeight:360).fixedSize(horizontal:false,vertical:true)
            BandalMenuDivider()
            BandalMenuRow("기존 폴더 연결",symbol:"folder.badge.plus",detail:"파일 앱의 폴더를 그대로 반달 폴더로 써요") {
                change {
                    guard let folder = try await store.invoke("courses:pickFolder") as? [String:Any], let path = folder["path"] as? String else { return }
                    let result = try await store.invoke("courses:addFromFolder",["folderPath":path,"name":folder["name"] as? String ?? "연결한 폴더","color":"blue"]) as? [String:Any]
                    if result?["status"] as? String == "failed" { throw DesktopRuntimeError(result?["reason"] as? String ?? "폴더를 연결하지 못했습니다.") }
                }
            }.accessibilityIdentifier("native-manager-link-folder")
        }
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
        .task { await load() }
        .bandalConfirm("영구 삭제할까요?", isPresented: Binding(get: { purging != nil }, set: { if !$0 { DispatchQueue.main.async { purging = nil } } }),
                       message: "안에 있던 폴더와 파일까지 지워지고 되돌릴 수 없어요. 파일 앱에서 연결한 폴더는 반달에서만 빠지고 원본은 남아요.", action: "영구 삭제", destructive: true) {
            if let course = purging { change { _ = try await store.invoke("courses:purge",["courseId":course.id]) } }
        }
        .accessibilityElement(children:.contain).accessibilityIdentifier("native-course-manager")
    }
    @ViewBuilder private var archivedProjectRows: some View {
        ForEach(archivedProjects, id: \.id) { project in
            HStack(spacing:8) {
                Image(systemName:"archivebox").font(.system(size:12)).foregroundStyle(NativeDesktopTheme.muted).frame(width:18)
                Text(verbatim: project.name).lineLimit(1)
                Spacer(minLength:4)
                Button("다시 꺼내기") { restoreProject(project.id) }.buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.accent).frame(minHeight:44)
                    .accessibilityIdentifier("native-manager-restore-" + project.id)
            }.font(.system(size:BandalMetrics.bodySize)).padding(.horizontal,8).frame(minHeight:BandalMetrics.rowHeight)
        }
    }
    private func deletedRow(_ course: ManagedCourse) -> some View {
        HStack(spacing:8) {
            NativeFolderGlyph(color: course.color, size: 16).opacity(0.5).frame(width:18)
            Text(verbatim: course.name).lineLimit(1).foregroundStyle(NativeDesktopTheme.secondary)
            Spacer(minLength:4)
            Button("복원") { change { _ = try await store.invoke("courses:restore",["courseId":course.id]) } }
                .buttonStyle(.plain).foregroundStyle(NativeGlass.accent).frame(minHeight:44).accessibilityIdentifier("native-manager-restore-course-" + course.id)
            Menu {
                Button("영구 삭제",systemImage:"trash",role:.destructive) { purging = course }
            } label: { Image(systemName:"ellipsis").frame(width:44,height:max(44, BandalMetrics.rowHeight)).contentShape(Rectangle()) }
            .accessibilityLabel(course.name + " 삭제 관리")
        }.font(.system(size:BandalMetrics.bodySize)).padding(.horizontal,8).frame(minHeight:BandalMetrics.rowHeight)
    }
    private func row(_ course: ManagedCourse) -> some View {
        HStack(spacing:8) {
            Group { if course.archived { Image(systemName:"archivebox").font(.system(size:12)).foregroundStyle(NativeDesktopTheme.muted) } else { NativeFolderGlyph(color: course.color, size: 16) } }.frame(width:18)
            VStack(alignment:.leading,spacing:1) {
                BandalInlineEditor(text:course.name,isEditing:.editing(course.id,in:$renamingID),identifier:"native-manager-rename") { name in
                    change { _ = try await store.invoke("courses:rename",["courseId":course.id,"name":name]) }
                }
                if course.missing { Text("폴더 연결이 필요해요").font(.system(size:11)).foregroundStyle(.orange) }
            }
            Spacer(minLength:4)
            Menu {
                Button("이름 변경",systemImage:"pencil") { renamingID = course.id }
                if course.missing { Button("폴더 다시 연결",systemImage:"folder.badge.questionmark") { relink(course) } }
                Button(course.archived ? "다시 꺼내기" : "폴더 보관",systemImage:course.archived ? "tray.and.arrow.up" : "archivebox") {
                    change { _ = try await store.invoke("courses:archive",["courseId":course.id,"archived":!course.archived]) }
                }
            } label: { Image(systemName:"ellipsis").frame(width:44,height:max(44, BandalMetrics.rowHeight)).contentShape(Rectangle()) }
            .accessibilityLabel(course.name + " 관리")
        }.font(.system(size:BandalMetrics.bodySize)).padding(.horizontal,8).frame(minHeight:BandalMetrics.rowHeight)
    }
    private func load() async {
        do { courses = try NativeToolJSON.decode(await store.invoke("courses:list",["includeArchived":true,"includeDeleted":true])); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func change(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; do { try await store.flushDocuments(); try await operation(); await load() } catch { self.error = error.localizedDescription } }
    }
    private func relink(_ course: ManagedCourse) {
        change {
            guard let folder = try await store.invoke("courses:pickFolder") as? [String:Any], let path = folder["path"] as? String else { return }
            _ = try await store.withExternalMutation {
                guard let result = try await store.invoke("courses:relink",["courseId":course.id,"folderPath":path]) as? [String:Any] else { throw DesktopRuntimeError("폴더 연결 결과를 확인하지 못했습니다.") }
                switch result["status"] as? String {
                case "ok": return ["status":"ok","changedCourseIDs":[course.id]]
                case "duplicate": throw DesktopRuntimeError("선택한 폴더가 이미 다른 곳에 연결되어 있습니다.")
                default: throw DesktopRuntimeError(result["reason"] as? String ?? "폴더를 연결하지 못했습니다.")
                }
            }
        }
    }
}

struct NativeMaterialMovePicker: View {
    let material: NativeMaterial
    var store: NativeWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    private var folders: [NativeMaterial] {
        NativeLibraryIndex.flatten(store.materials).filter { $0.isDirectory && $0.relPath != material.relPath && !$0.relPath.hasPrefix(material.relPath + "/") }
    }
    @State private var query = ""
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            BandalSectionHeader("이동할 폴더").padding(.horizontal,8)
            if let error { Text(error).font(.system(size:11)).foregroundStyle(.red) }
            BandalSearchList(prompt:"폴더 찾기",query:$query,identifier:"native-move-search") {
                BandalMenuRow("전체 자료",symbol:"folder") { move("") }
                ForEach(folders.filter { query.isEmpty || $0.relPath.localizedStandardContains(query) }) { folder in BandalMenuRow(folder.relPath,symbol:"folder") { move(folder.relPath) } }
            }
        }.disabled(busy)
    }
    private func move(_ folder: String) {
        busy = true
        Task { defer { busy = false }; do { try await store.move(material,to:folder); dismiss() } catch { self.error = error.localizedDescription } }
    }
}
