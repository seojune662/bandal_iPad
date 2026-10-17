import SwiftUI

struct NativeCourseManager: View {
    @ObservedObject var store: NativeWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var courses: [ManagedCourse] = []
    @State private var renaming: ManagedCourse?
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
        NavigationStack {
            List {
                if let error { NativeToolError(message:error) }
                ForEach([false,true],id:\.self) { archived in
                    let values = courses.filter { $0.archived == archived }
                    if !values.isEmpty {
                        Section(archived ? "보관한 과목" : "내 과목") {
                            ForEach(values) { course in
                                HStack {
                                    Image(systemName:course.archived ? "archivebox" : "books.vertical").foregroundStyle(.secondary)
                                    VStack(alignment:.leading) {
                                        Text(course.name)
                                        if course.missing { Text("폴더 연결이 필요해요").font(.caption).foregroundStyle(.orange) }
                                    }
                                    Spacer()
                                    Menu {
                                        Button("이름 변경",systemImage:"pencil") { renaming = course }
                                        if course.missing {
                                            Button("폴더 다시 연결",systemImage:"folder.badge.questionmark") { relink(course) }
                                        }
                                        Button(course.archived ? "자료실에 다시 표시" : "과목 보관",systemImage:course.archived ? "tray.and.arrow.up" : "archivebox") {
                                            change { _ = try await store.invoke("courses:archive",["courseId":course.id,"archived":!course.archived]) }
                                        }
                                    } label: { Image(systemName:"ellipsis.circle").frame(width:44,height:44) }
                                    .accessibilityLabel(course.name + " 관리")
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("기존 폴더 연결",systemImage:"folder.badge.plus") {
                        change {
                            guard let folder = try await store.invoke("courses:pickFolder") as? [String:Any], let path = folder["path"] as? String else { return }
                            let result = try await store.invoke("courses:addFromFolder",["folderPath":path,"name":folder["name"] as? String ?? "연결한 과목","color":"blue"]) as? [String:Any]
                            if result?["status"] as? String == "failed" { throw DesktopRuntimeError(result?["reason"] as? String ?? "폴더를 연결하지 못했습니다.") }
                        }
                    }
                } footer: { Text("보관한 과목은 파일과 필기를 유지하며 자료실 목록에서만 숨깁니다.") }
            }
            .disabled(busy)
            .overlay { if busy { ProgressView().padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)) } }
            .navigationTitle("과목 관리").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("완료") { dismiss() } } }
            .task { await load() }
            .sheet(item:$renaming) { course in
                NativeNameSheet(title:"과목 이름",prompt:"과목 이름",initialValue:course.name,actionTitle:"저장") { name in
                    try await store.flushDocuments()
                    _ = try await store.invoke("courses:rename",["courseId":course.id,"name":name]); await load()
                }
            }
        }
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
    @ObservedObject var store: NativeWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    private var folders: [NativeMaterial] {
        NativeLibraryIndex.flatten(store.materials).filter { $0.isDirectory && $0.relPath != material.relPath && !$0.relPath.hasPrefix(material.relPath + "/") }
    }
    var body: some View {
        NavigationStack {
            List {
                if let error { NativeToolError(message:error) }
                Button("전체 자료",systemImage:"folder") { move("") }
                ForEach(folders) { folder in Button(folder.relPath,systemImage:"folder") { move(folder.relPath) } }
            }.disabled(busy)
            .navigationTitle("이동할 폴더").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("취소") { dismiss() }.disabled(busy) } }
        }
    }
    private func move(_ folder: String) {
        busy = true
        Task { defer { busy = false }; do { try await store.move(material,to:folder); dismiss() } catch { self.error = error.localizedDescription } }
    }
}
