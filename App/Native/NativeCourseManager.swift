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
    private struct ManagedCourse: Decodable, Identifiable {
        let id: String
        let name: String
        let color: String
        let archived: Bool
        let missing: Bool
    }
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            if let error { NativeInlineError(message: error) }
            ScrollView {
                VStack(alignment:.leading,spacing:0) {
                    ForEach([false,true],id:\.self) { archived in
                        let values = courses.filter { $0.archived == archived }
                        if !values.isEmpty {
                            BandalSectionHeader(archived ? "보관한 폴더" : "내 폴더").padding(.horizontal,8).padding(.top,4)
                            ForEach(values) { course in row(course) }
                            if archived { archivedProjectRows }
                        }
                    }
                    if !courses.contains(where: \.archived), !archivedProjects.isEmpty {
                        BandalSectionHeader("보관한 폴더").padding(.horizontal,8).padding(.top,4)
                        archivedProjectRows
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
    private func row(_ course: ManagedCourse) -> some View {
        HStack(spacing:8) {
            Image(systemName:course.archived ? "archivebox" : "folder.fill").font(.system(size:12)).foregroundStyle(course.archived ? NativeDesktopTheme.muted : NativeFolderColor.color(course.color)).frame(width:18)
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
        do { courses = try NativeToolJSON.decode(await store.invoke("courses:list",["includeArchived":true])); error = nil }
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
