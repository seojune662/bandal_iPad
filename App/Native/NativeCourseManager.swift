import SwiftUI

struct NativeCourseManager: View {
    var store: NativeWorkspaceStore
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
            if let error { Text(error).font(.system(size:11)).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
            ScrollView {
                VStack(alignment:.leading,spacing:0) {
                    ForEach([false,true],id:\.self) { archived in
                        let values = courses.filter { $0.archived == archived }
                        if !values.isEmpty {
                            BandalSectionHeader(archived ? "보관한 과목" : "내 과목").padding(.horizontal,8).padding(.top,4)
                            ForEach(values) { course in row(course) }
                        }
                    }
                }
            }.frame(maxHeight:360).fixedSize(horizontal:false,vertical:true)
            BandalMenuDivider()
            BandalMenuRow("기존 폴더 연결",symbol:"folder.badge.plus",detail:"보관한 과목은 파일과 필기를 그대로 두고 목록에서만 숨겨요") {
                change {
                    guard let folder = try await store.invoke("courses:pickFolder") as? [String:Any], let path = folder["path"] as? String else { return }
                    let result = try await store.invoke("courses:addFromFolder",["folderPath":path,"name":folder["name"] as? String ?? "연결한 과목","color":"blue"]) as? [String:Any]
                    if result?["status"] as? String == "failed" { throw DesktopRuntimeError(result?["reason"] as? String ?? "폴더를 연결하지 못했습니다.") }
                }
            }.accessibilityIdentifier("native-manager-link-folder")
        }
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
        .task { await load() }
        .accessibilityElement(children:.contain).accessibilityIdentifier("native-course-manager")
    }
    private func row(_ course: ManagedCourse) -> some View {
        HStack(spacing:8) {
            Image(systemName:course.archived ? "archivebox" : "books.vertical").font(.system(size:12)).foregroundStyle(NativeDesktopTheme.muted).frame(width:18)
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
                Button(course.archived ? "자료실에 다시 표시" : "과목 보관",systemImage:course.archived ? "tray.and.arrow.up" : "archivebox") {
                    change { _ = try await store.invoke("courses:archive",["courseId":course.id,"archived":!course.archived]) }
                }
            } label: { Image(systemName:"ellipsis").frame(width:32,height:BandalMetrics.rowHeight).contentShape(Rectangle()) }
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
                case "duplicate": throw DesktopRuntimeError("선택한 폴더가 다른 과목에 이미 연결되어 있습니다.")
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
