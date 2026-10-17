import SwiftUI

struct NativeSettingsWidgetDock: View {
    @ObservedObject var store: NativeWorkspaceStore
    @ObservedObject var services: NativePlatformServices
    var availableHeight: CGFloat = 680
    @State private var settings: [String: Any] = [:]
    @State private var error: String?
    private var widgets: [String: Any] { settings["widgets"] as? [String: Any] ?? [:] }
    private var enabled: [String] { (widgets["enabled"] as? [String] ?? []).filter { ["todo", "board", "mail"].contains($0) } }
    private var active: String { let value = widgets["active"] as? String ?? "todo"; return enabled.contains(value) ? value : enabled.first ?? "todo" }
    private var mailURL: String? {
        let mail = NativeUniversityCatalog.resolvedServices(settings: settings).filter { $0.kind == "mail" }
        let chosen = mail.first { $0.id == widgets["mailServiceId"] as? String } ?? mail.first
        return chosen?.url ?? (widgets["mailUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    var body: some View {
        Group {
            if !enabled.isEmpty {
                VStack(spacing: 0) {
                    NativeDesktopTheme.border.frame(height: 1)
                    HStack(spacing: 2) {
                        ForEach(enabled, id: \.self) { id in
                            Button(title(id)) { Task { do { _ = try await store.invoke("settings:set", ["widgets": ["active": id]]) } catch { self.error = error.localizedDescription } } }
                                .font(NativeDesktopTheme.font(11, weight: .medium)).padding(.horizontal, 10).frame(height: 32)
                                .background(active == id ? NativeDesktopTheme.accentMuted : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityIdentifier("native-widget-" + id)
                        }
                        Spacer(minLength: 0)
                    }.buttonStyle(.plain).padding(8)
                    if let error { NativeToolError(message: error) }
                    if active == "mail" {
                        if let mailURL { NativeWidgetMail(store: store, host: services.browser, url: mailURL) }
                        else { Text("설정 → 위젯에서 학교 메일이나 메일 주소를 연결하세요.").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    } else { NativeWidgetTasks(store: store, board: active == "board").id(active) }
                }.frame(height: min(max(160, availableHeight * 0.65), max(220, availableHeight * ((widgets["heightRatio"] as? NSNumber)?.doubleValue ?? 0.38))))
                    .background(NativeDesktopTheme.surface).clipped()
            }
        }.task { do { settings = try await store.invoke("settings:get") as? [String: Any] ?? [:] } catch { self.error = error.localizedDescription } }
            .onReceive(store.events) { event in if event.channel == "settings:changed", let value = event.payload as? [String: Any] { settings = value["settings"] as? [String: Any] ?? value } }
    }
    private func title(_ id: String) -> String { id == "todo" ? "투두" : id == "board" ? "학업 보드" : "메일함" }
}

private struct NativeWidgetTasks: View {
    @ObservedObject var store: NativeWorkspaceStore
    let board: Bool
    @State private var tasks: [NativePlannerTask] = []
    @State private var error: String?
    @State private var changing = Set<String>()
    @State private var adding = false
    @State private var editing: NativePlannerTask?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(store.courses.first { $0.id == store.selectedCourseID }?.name ?? "모든 과목").font(NativeDesktopTheme.font(11)).lineLimit(1); Spacer(); Button("할 일 추가", systemImage: "plus") { adding = true }.labelStyle(.iconOnly).accessibilityIdentifier("native-widget-add-task") }.padding(.horizontal, 12).frame(height: 30)
            if let error { NativeToolError(message: error) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(board ? ["todo", "in-progress", "done"] : ["todo", "in-progress"], id: \.self) { status in
                        let values = tasks.filter { $0.status == status }
                        if board { Text(status == "todo" ? "할 일" : status == "in-progress" ? "진행 중" : "완료").font(NativeDesktopTheme.font(11, weight: .medium)).foregroundStyle(NativeDesktopTheme.muted) }
                        ForEach(values) { task in
                            HStack(alignment: .top, spacing: 8) {
                                Button { update(task, status: task.completed ? "todo" : "done") } label: { Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").frame(width: 26, height: 30) }.buttonStyle(.plain).disabled(changing.contains(task.id)).accessibilityLabel(task.completed ? "미완료로 표시" : "완료로 표시")
                                Button { editing = task } label: { VStack(alignment: .leading, spacing: 3) { Text(task.title).strikethrough(task.completed).font(NativeDesktopTheme.font(12)).multilineTextAlignment(.leading); if let due = task.dueDate { Text(due.formatted(date: .abbreviated, time: .omitted)).font(NativeDesktopTheme.font(10)).foregroundStyle(NativeDesktopTheme.muted) } }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading) }.buttonStyle(.plain)
                                if board { Menu { ForEach(["todo", "in-progress", "done"], id: \.self) { value in Button(value == "todo" ? "할 일" : value == "in-progress" ? "진행 중" : "완료") { update(task, status: value) } } } label: { Image(systemName: "ellipsis").frame(width: 24, height: 30) } }
                            }
                        }
                    }
                    if tasks.filter({ board || !$0.completed }).isEmpty { Text("할 일을 추가해보세요.").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted).padding(.vertical, 20) }
                }.padding(12)
            }
        }.task(id: store.selectedCourseID) { await load() }
            .onReceive(store.events) { event in if event.channel == "board:changed" { Task { await load() } } }
            .sheet(isPresented: $adding) { NativeTaskEditor(task: nil, courses: store.courses, defaultCourseID: store.selectedCourseID) { request in _ = try await store.invoke("board:createTask", request); await load() } }
            .sheet(item: $editing) { item in NativeTaskEditor(task: item, courses: store.courses, defaultCourseID: store.selectedCourseID) { request in _ = try await store.invoke("board:updateTask", request); await load() } }
    }
    private func load() async {
        let course = store.selectedCourseID
        do { var request: [String: Any] = ["includeDone": board]; if let course { request["courseId"] = course }; let values: [NativePlannerTask] = try NativeToolJSON.decode(try await store.invoke("board:listTasks", request)); guard course == store.selectedCourseID else { return }; tasks = values; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func update(_ task: NativePlannerTask, status: String) { guard changing.insert(task.id).inserted else { return }; Task { defer { changing.remove(task.id) }; do { _ = try await store.invoke("board:updateTask", ["id": task.id, "status": status]); await load() } catch { self.error = error.localizedDescription } } }
}

private struct NativeWidgetMail: View {
    @ObservedObject var store: NativeWorkspaceStore
    let url: String
    @StateObject private var session: NativeBrowserSession
    init(store: NativeWorkspaceStore, host: DesktopBrowserHost, url: String) {
        self.store = store; self.url = url
        _session = StateObject(wrappedValue: NativeBrowserSession(store: store, host: host, workspaceID: "right-sidebar-mail"))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("뒤로", systemImage: "chevron.left") { perform { try await session.action("goBack") } }.disabled(session.active?.canGoBack != true)
                Button("새로고침", systemImage: "arrow.clockwise") { perform { try await session.action("reload") } }
                Spacer()
                Button("전체 메일함 열기", systemImage: "arrow.up.right.square") { store.events.send(.init(channel: "nativeWorkspace:openBrowserURL", payload: ["url": session.active?.url ?? url])) }
            }.buttonStyle(NativeToolIconStyle()).padding(.horizontal, 8)
            if let error = session.error { NativeToolError(message: error) }
            NativeBrowserSurface(host: session.host, selectedID: session.activeID)
        }.task {
            let existing = session.host.pages.keys.contains(where: session.owns)
            await session.start()
            if !existing || session.active?.url == "about:blank" { perform { try await session.navigate(url) } }
        }.onChange(of: url) { _, value in perform { try await session.navigate(value) } }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) { Task { do { try await action() } catch { session.error = error.localizedDescription } } }
}
