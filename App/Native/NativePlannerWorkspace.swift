import SwiftUI

struct NativePlannerTask: Decodable, Identifiable {
    let id: String
    let courseId: String?
    let title: String
    let notes: String
    let status: String
    let kind: String
    let color: String
    let dueAt: String?
    let startAt: String?
    let allDay: Bool
    var completed: Bool { status == "done" }
    var dueDate: Date? {
        date(dueAt)
    }
    var startDate: Date? { date(startAt) }
    func occurs(on day: Date, calendar: Calendar = .current) -> Bool {
        guard let end = dueDate ?? startDate else { return false }
        let start = min(startDate ?? end, end)
        let target = calendar.startOfDay(for: day)
        return target >= calendar.startOfDay(for: start) && target <= calendar.startOfDay(for: end)
    }
    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        if allDay { return Self.dayFormatter.date(from: value) }
        return ISO8601DateFormatter().date(from: value)
            ?? ISO8601DateFormatter.fractional.date(from: value)
    }
    static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

struct NativePlannerWorkspace: View {
    var store: NativeWorkspaceStore
    let courseID: String?
    private var effectiveCourseID: String? { courseID ?? store.selectedCourseID }
    init(store: NativeWorkspaceStore, courseID: String? = nil) {
        self.store = store; self.courseID = courseID
        _courseFilter = State(initialValue: courseID ?? "*")
    }
    @State private var tasks: [NativePlannerTask] = []
    @State private var showingCompleted = true
    @State private var courseFilter = "*"
    @State private var calendarView = true
    @State private var preferencesLoaded = false
    @State private var loading = false
    @State private var error: String?
    @State private var editor: TaskEditorIdentity?
    @State private var pendingDeletion: NativePlannerTask?
    @State private var requestID = UUID()
    @State private var changing = Set<String>()
    private struct TaskEditorIdentity: Identifiable {
        let id = UUID()
        let task: NativePlannerTask?
        /// Opened from a task card: the popover hangs off that card.
        var anchoredOnCard = false
        var status = "todo"
        var date: Date? = nil
    }
    private var visibleTasks: [NativePlannerTask] {
        tasks.filter { showingCompleted || !$0.completed }.sorted {
            if $0.completed != $1.completed { return !$0.completed }
            return ($0.dueAt ?? "9999", $0.title) < ($1.dueAt ?? "9999", $1.title)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { boardTitle; viewSwitch; courseFilters; boardActions }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { boardTitle; Spacer(); viewSwitch; boardActions }
                    courseFilters
                }
            }.padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 60)
                .background(NativeDesktopTheme.surface)
                .overlay(alignment: .bottom) { NativeDesktopTheme.border.frame(height: 1) }
            if let error { NativeToolError(message: error) }
            if calendarView {
                NativePlannerCalendar(store: store, tasks: visibleTasks, courses: store.courses,
                    onEdit: { editor = TaskEditorIdentity(task: $0) },
                    onCreate: { editor = TaskEditorIdentity(task: nil, date: $0) })
            } else {
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(showingCompleted ? ["todo", "in-progress", "done"] : ["todo", "in-progress"], id: \.self) { status in
                                taskColumn(status).frame(width: max(336, (geometry.size.width - 32 - (showingCompleted ? 24 : 12)) / (showingCompleted ? 3 : 2)))
                            }
                        }.padding(16).frame(minHeight: geometry.size.height, alignment: .top)
                    }
                }
            }
        }.background(NativeDesktopTheme.bgApp).foregroundStyle(NativeDesktopTheme.text).font(.system(size: 13))
        .popover(isPresented: Binding(get: { editor != nil && editor?.anchoredOnCard != true }, set: { if !$0 { editor = nil } }), attachmentAnchor: .point(.top), arrowEdge: .top) {
            if let item = editor { taskEditor(item) }
        }
        .task(id: courseFilter) { await load() }
        .onReceive(store.events) { event in if event.channel == "board:changed" { Task { await load() } } }
    }
    private var boardTitle: some View {
        Text(calendarView ? "달력과 마감" : "과제와 시험").font(.system(size: 18, weight: .semibold)).fixedSize()
    }
    private var viewSwitch: some View {
        HStack(spacing: 0) {
            ForEach([true, false], id: \.self) { calendar in
                Button(calendar ? "달력" : "목록") { calendarView = calendar }
                    .font(.system(size: 13, weight: .medium)).frame(width: 60, height: 36)
                    .foregroundStyle(calendarView == calendar ? NativeDesktopTheme.onAccent : NativeDesktopTheme.secondary)
                    .background(calendarView == calendar ? NativeDesktopTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier(calendar ? "native-planner-calendar" : "native-planner-board")
            }.buttonStyle(.plain)
        }.padding(4).background(NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 8))
    }
    private var courseFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                courseChip("모든 과목", id: "*")
                courseChip("전체", id: "")
                ForEach(store.courses) { course in courseChip(course.name, id: course.id) }
            }
        }.frame(minWidth: 100)
    }
    private func courseChip(_ title: String, id: String) -> some View {
        Button { courseFilter = id } label: {
            HStack(spacing: 8) {
                if id != "*" { Circle().fill(NativeDesktopTheme.muted).frame(width: 8, height: 8) }
                Text(title).lineLimit(1)
            }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 32)
                .foregroundStyle(courseFilter == id ? NativeDesktopTheme.text : NativeDesktopTheme.secondary)
                .background(courseFilter == id ? NativeDesktopTheme.accentMuted : NativeDesktopTheme.bgApp, in: Capsule())
        }.buttonStyle(.plain)
    }
    private var boardActions: some View {
        HStack(spacing: 8) {
            if !calendarView {
                Toggle("완료 숨기기", isOn: Binding(get: { !showingCompleted }, set: { showingCompleted = !$0 }))
                    .font(.system(size: 12)).toggleStyle(.switch).controlSize(.mini).fixedSize()
            }
            Button("새로고침", systemImage: "arrow.clockwise") { Task { await load() } }.buttonStyle(NativeToolIconStyle()).disabled(loading)
            Button("할 일 추가", systemImage: "plus") { editor = TaskEditorIdentity(task: nil) }
                .buttonStyle(NativeToolIconStyle()).accessibilityIdentifier("native-task-add")
        }
    }
    private func taskColumn(_ status: String) -> some View {
        let values = visibleTasks.filter { $0.status == status }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(statusColor(status)).frame(width: 8, height: 8)
                Text(statusTitle(status)).font(.system(size: 13, weight: .medium))
                Text(String(values.count)).font(.system(size: 12, design: .monospaced)).foregroundStyle(NativeDesktopTheme.muted)
                    .frame(minWidth: 24, minHeight: 24).background(NativeDesktopTheme.raised, in: Capsule())
                Spacer()
            }.padding(.horizontal, 12).frame(height: 44)
            NativeDesktopTheme.border.frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(values) { task in taskCard(task).draggable(task.id) }
                    if values.isEmpty {
                        Text(status == "todo" ? "할 일을 추가해보세요" : status == "in-progress" ? "진행 중인 일정이 없어요" : "완료한 일정이 여기에 모여요")
                            .font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }.padding(12)
            }.frame(minHeight: 220)
            NativeDesktopTheme.border.frame(height: 1)
            Button { editor = TaskEditorIdentity(task: nil, status: status) } label: { Label("추가", systemImage: "plus").font(.system(size: 13)).frame(maxWidth: .infinity).frame(height: 36) }
                .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.secondary).background(NativeDesktopTheme.bgApp)
        }.background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NativeDesktopTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, let task = tasks.first(where: { $0.id == id }) else { return false }
                setStatus(task, status: status); return true
            }
    }
    private func taskCard(_ task: NativePlannerTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Button { setStatus(task, status: task.completed ? "todo" : "done") } label: {
                    Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 16)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(statusColor(task.status)).disabled(changing.contains(task.id))
                    .accessibilityLabel(task.completed ? "미완료로 표시" : "완료로 표시").accessibilityIdentifier("native-task-toggle-\(task.id)")
                Button { editor = TaskEditorIdentity(task: task, anchoredOnCard: true) } label: {
                    Text(task.title).strikethrough(task.completed).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                }.buttonStyle(.plain).accessibilityIdentifier("native-task-edit-\(task.id)")
                    .popover(isPresented: Binding(get: { editor?.anchoredOnCard == true && editor?.task?.id == task.id }, set: { if !$0 { editor = nil } }), arrowEdge: .leading) {
                        if let item = editor { taskEditor(item) }
                    }
            }
            if !task.notes.isEmpty { Text(task.notes).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(3) }
            HStack(spacing: 8) {
                if let course = store.courses.first(where: { $0.id == task.courseId }) { Text(course.name).lineLimit(1) }
                Spacer(minLength: 0)
                if let date = task.dueDate { Label(date.formatted(date: .abbreviated, time: task.allDay ? .omitted : .shortened), systemImage: "calendar") }
            }.font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
        }.padding(12).background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(NativeDesktopTheme.border))
            .contextMenu {
                ForEach(["todo", "in-progress", "done"], id: \.self) { status in Button(statusTitle(status)) { setStatus(task, status: status) } }
                Button("수정") { editor = TaskEditorIdentity(task: task) }
                Button("삭제", role: .destructive) { pendingDeletion = task }
            }
            .bandalConfirm("할 일을 삭제할까요?", isPresented: Binding(get: { pendingDeletion?.id == task.id }, set: { if !$0 { pendingDeletion = nil } }), action: "삭제", destructive: true) {
                pendingDeletion = nil
                Task {
                    do { _ = try await store.invoke("board:deleteTask", ["id": task.id]); await load() }
                    catch { self.error = error.localizedDescription }
                }
            }
    }
    private func taskEditor(_ item: TaskEditorIdentity) -> some View {
        NativeTaskEditor(task: item.task, courses: store.courses, defaultCourseID: courseFilter == "*" ? effectiveCourseID : courseFilter.isEmpty ? nil : courseFilter, defaultStatus: item.status, defaultDueDate: item.date) { request in
            _ = try await store.invoke(item.task == nil ? "board:createTask" : "board:updateTask", request)
            await load()
        }
        .padding(BandalMetrics.padding).frame(width: 320).presentationCompactAdaptation(.popover)
    }
    private func statusTitle(_ status: String) -> String { status == "todo" ? "할 일" : status == "in-progress" ? "진행 중" : "완료" }
    private func statusColor(_ status: String) -> Color { status == "done" ? Color(red: 0.25, green: 0.54, blue: 0.38) : status == "in-progress" ? Color(red: 0.25, green: 0.48, blue: 0.73) : NativeDesktopTheme.muted }
    private func load() async {
        let identifier = UUID(); requestID = identifier; loading = true
        defer { if identifier == requestID { loading = false } }
        var request: [String: Any] = ["includeDone": true]
        if courseFilter != "*" { request["courseId"] = courseFilter.isEmpty ? NSNull() : courseFilter as Any }
        do {
            if !preferencesLoaded {
                let settings = try await store.invoke("settings:get") as? [String: Any] ?? [:]
                let tabs = settings["tabs"] as? [String: Any] ?? [:]
                calendarView = tabs["boardDefaultView"] as? String != "board"
                showingCompleted = tabs["boardHideDone"] as? Bool != true
                preferencesLoaded = true
            }
            let result: [NativePlannerTask] = try NativeToolJSON.decode(try await store.invoke("board:listTasks", request))
            guard identifier == requestID else { return }
            tasks = result; error = nil
        } catch { if identifier == requestID { self.error = error.localizedDescription } }
    }
    private func setStatus(_ task: NativePlannerTask, status: String) {
        guard changing.insert(task.id).inserted else { return }
        Task {
            defer { changing.remove(task.id) }
            do { _ = try await store.invoke("board:updateTask", ["id": task.id, "status": status]); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct NativeTaskEditor: View {
    let task: NativePlannerTask?
    let courses: [NativeCourse]
    let save: ([String: Any]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var notes: String
    @State private var courseID: String
    @State private var kind: String
    @State private var status: String
    @State private var hasDueDate: Bool
    @State private var allDay: Bool
    @State private var dueDate: Date
    @State private var busy = false
    @State private var error: String?
    init(task: NativePlannerTask?, courses: [NativeCourse], defaultCourseID: String?, defaultStatus: String = "todo", defaultDueDate: Date? = nil, save: @escaping ([String: Any]) async throws -> Void) {
        self.task = task; self.courses = courses; self.save = save
        _title = State(initialValue: task?.title ?? "")
        _notes = State(initialValue: task?.notes ?? "")
        _courseID = State(initialValue: task == nil ? defaultCourseID ?? "" : task?.courseId ?? "")
        _kind = State(initialValue: task?.kind ?? "task")
        _status = State(initialValue: task?.status ?? defaultStatus)
        _hasDueDate = State(initialValue: task == nil ? defaultDueDate != nil : task?.dueAt != nil)
        _allDay = State(initialValue: task?.allDay ?? true)
        _dueDate = State(initialValue: task?.dueDate ?? defaultDueDate ?? Date())
    }
    /// A popover: a new task is added with Enter or 추가; an edit saves when the popover closes.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BandalSectionHeader(task == nil ? "새 할 일" : "할 일")
            TextField("제목", text: $title).font(.system(size: 14, weight: .medium)).textFieldStyle(.plain)
                .focused($titleFocused).submitLabel(.done).onSubmit { if task == nil { submit() } }
                .accessibilityIdentifier("native-task-title")
            TextField("메모", text: $notes, axis: .vertical).font(.system(size: 12)).lineLimit(2...6).textFieldStyle(.plain)
                .foregroundStyle(NativeDesktopTheme.secondary)
            BandalMenuDivider()
            row("과목") { Picker("과목", selection: $courseID) { Text("공통").tag(""); ForEach(courses) { Text($0.name).tag($0.id) } } }
            row("종류") { Picker("종류", selection: $kind) { Text("할 일").tag("task"); Text("과제").tag("assignment"); Text("시험").tag("exam"); Text("수업").tag("class") } }
            row("상태") { Picker("상태", selection: $status) { Text("할 일").tag("todo"); Text("진행 중").tag("in-progress"); Text("완료").tag("done") }.pickerStyle(.segmented).frame(width: 190) }
            row("마감일") { Toggle("마감일", isOn: $hasDueDate).labelsHidden() }
            if hasDueDate {
                row("하루 종일") { Toggle("하루 종일", isOn: $allDay).labelsHidden() }
                DatePicker("날짜", selection: $dueDate, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute]).font(.system(size: BandalMetrics.bodySize))
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            if task == nil {
                HStack { Spacer(); Button("추가") { submit() }.font(.system(size: BandalMetrics.bodySize, weight: .semibold))
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy).accessibilityIdentifier("native-task-save") }
            }
        }
        .disabled(busy)
        .onAppear { if task == nil { titleFocused = true } }
        .onDisappear { if task != nil, changed, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { submit() } }
    }
    @FocusState private var titleFocused: Bool
    private var changed: Bool {
        guard let task else { return false }
        return title != task.title || notes != task.notes || courseID != (task.courseId ?? "") || kind != task.kind || status != task.status
            || hasDueDate != (task.dueAt != nil) || allDay != task.allDay || (hasDueDate && dueDate != task.dueDate)
    }
    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack { Text(label).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary); Spacer(); control() }.frame(minHeight: 32)
    }
    private func submit() {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            var request: [String: Any] = ["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "notes": notes,
                "courseId": courseID.isEmpty ? NSNull() : courseID as Any, "kind": kind, "status": status,
                "allDay": allDay, "dueAt": hasDueDate ? (allDay ? NativePlannerTask.dayFormatter.string(from: dueDate) : ISO8601DateFormatter().string(from: dueDate)) : NSNull()]
            if let task { request["id"] = task.id }
            do { try await save(request); if task == nil { dismiss() } }
            catch { self.error = error.localizedDescription }
        }
    }
}
