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
    /// Whole days from today to the due day: 0 today, negative once overdue.
    func daysLeft(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let dueDate else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: dueDate)).day
    }
    /// The countdown on a card: "D-3", "D-DAY", "D+2", red from the day before. A finished task has none.
    func dueBadge(now: Date = Date(), calendar: Calendar = .current) -> (label: String, urgent: Bool)? {
        guard !completed, let days = daysLeft(now: now, calendar: calendar) else { return nil }
        return (days > 0 ? "D-\(days)" : days == 0 ? "D-DAY" : "D+\(-days)", days <= 1)
    }
    /// Nearest due first, undated last, then by title.
    static func boardOrder(_ first: NativePlannerTask, _ second: NativePlannerTask) -> Bool {
        let (a, b) = (first.dueDate ?? .distantFuture, second.dueDate ?? .distantFuture)
        return a == b ? first.title < second.title : a < b
    }
    /// What the calendar suggests on an empty day: the nearest unfinished tasks due today or later.
    static func upcoming(_ tasks: [NativePlannerTask], now: Date = Date(), limit: Int = 2) -> [NativePlannerTask] {
        Array(tasks.filter { !$0.completed && ($0.daysLeft(now: now) ?? -1) >= 0 }.sorted(by: boardOrder).prefix(limit))
    }
    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        if allDay { return Self.dayFormatter.date(from: value) }
        return Self.timeFormatter.date(from: value) ?? Self.fractionalFormatter.date(from: value)
    }
    // Shared: the board sorts and counts days on every pass.
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let timeFormatter = ISO8601DateFormatter()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// 학업 보드: the tasks of every course as three status columns or a month calendar, filtered by course.
struct NativePlannerWorkspace: View {
    var store: NativeWorkspaceStore
    let courseID: String?
    /// How much of the board's bottom the keyboard covers. The popup ignores the keyboard so that typing does not
    /// squeeze it, which leaves it to the host to say.
    var keyboardInset: CGFloat = 0
    /// Set while the board is the popup over the workspace: it shows 닫기 and leaves the glass behind it to the host.
    var onClose: (() -> Void)?
    init(store: NativeWorkspaceStore, courseID: String? = nil, keyboardInset: CGFloat = 0, onClose: (() -> Void)? = nil) {
        self.store = store; self.courseID = courseID; self.keyboardInset = keyboardInset; self.onClose = onClose
        _courseFilter = State(initialValue: courseID)
    }
    @State private var tasks: [NativePlannerTask] = []
    @State private var hidingDone = false
    /// nil shows every course (전체).
    @State private var courseFilter: String?
    /// "board" or "calendar", the values of 설정 › 학업 보드 › 기본 보기.
    @State private var mode = "calendar"
    @State private var preferencesLoaded = false
    @State private var error: String?
    @State private var editor: TaskEditorIdentity?
    /// The card whose popover is open.
    @State private var detailID: String?
    @State private var pendingDeletion: NativePlannerTask?
    @State private var requestID = UUID()
    @State private var changing = Set<String>()
    private struct TaskEditorIdentity: Identifiable {
        let id = UUID()
        let task: NativePlannerTask?
        var status = "todo"
        var date: Date? = nil
    }
    private var visibleTasks: [NativePlannerTask] {
        tasks.filter { (courseFilter == nil || $0.courseId == courseFilter) && !(hidingDone && $0.completed) }.sorted(by: NativePlannerTask.boardOrder)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            NativeDesktopTheme.border.frame(height: 1)
            if let error { NativeToolError(message: error) }
            // Nothing view-specific until 설정 › 기본 보기 is known: the board does not open on one view and jump to the other.
            if !preferencesLoaded {
                Color.clear
            } else if mode == "calendar" {
                NativePlannerCalendar(store: store, tasks: visibleTasks, onCreate: { editor = TaskEditorIdentity(task: nil, date: $0) }, card: card)
            } else {
                GeometryReader { geometry in list(in: geometry.size) }
            }
        }
        .foregroundStyle(NativeDesktopTheme.text).font(.system(size: 13))
        // The popup's glass is the host's; without a shape of its own a tap between controls would reach the backdrop and close it.
        .background(onClose == nil ? NativeDesktopTheme.bgApp : .clear).contentShape(Rectangle())
        .overlay { GeometryReader { geometry in if let item = editor { editorSheet(item, in: geometry.size) } } }
        // One Esc handler: the sheet on top closes first, then the popup.
        .background { BandalEscapeKey { if editor != nil { editor = nil } else { onClose?() } } }
        .task { await load() }
        .onReceive(store.events) { event in if event.channel == "board:changed" { Task { await load() } } }
    }

    // MARK: Header
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { boardTitle; viewSwitch; Spacer(minLength: 0); closeButton }
                VStack(alignment: .leading, spacing: 12) { HStack { boardTitle; Spacer(minLength: 0); closeButton }; viewSwitch }
            }
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        NativePlannerChip(title: "전체", selected: courseFilter == nil) { courseFilter = nil }
                            .accessibilityLabel("전체 과목").accessibilityIdentifier("native-planner-filter-all")
                        ForEach(store.courses) { course in
                            NativePlannerChip(title: course.name, tint: course.tint, selected: courseFilter == course.id, clears: true) {
                                courseFilter = courseFilter == course.id ? nil : course.id
                            }.accessibilityLabel(course.name + " 과목만 보기").accessibilityIdentifier("native-planner-filter-" + course.id)
                        }
                    }.padding(.vertical, 1)
                }
                if mode == "board" {
                    Toggle("완료 숨기기", isOn: $hidingDone).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary)
                        .toggleStyle(.switch).controlSize(.mini).fixedSize().accessibilityIdentifier("native-planner-hide-done")
                }
            }.frame(height: 36)
        }.padding(.horizontal, 28).padding(.vertical, 22)
    }
    private var boardTitle: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1").font(.system(size: 22, weight: .medium)).accessibilityHidden(true)
            Text("학업 보드").font(.system(size: 26, weight: .bold)).fixedSize()
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
    private var viewSwitch: some View {
        BandalSegmented(options: [("board", "할 일 목록"), ("calendar", "달력")], selection: $mode, identifierPrefix: "native-planner-",
                        symbols: ["board": "list.dash", "calendar": "rectangle.on.rectangle"], large: true)
            .opacity(preferencesLoaded ? 1 : 0).disabled(!preferencesLoaded).accessibilityHidden(!preferencesLoaded)
    }
    @ViewBuilder private var closeButton: some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 22)).foregroundStyle(NativeDesktopTheme.secondary)
                    .frame(width: 68, height: 68).background(NativePlannerPalette.tool, in: Circle()).contentShape(Circle())
            }.buttonStyle(.plain).accessibilityLabel("학업 보드 닫기").accessibilityIdentifier("native-board-overlay-close")
        }
    }

    // MARK: List
    private func list(in size: CGSize) -> some View {
        let statuses = hidingDone ? ["todo", "in-progress"] : NativePlannerTask.statuses
        // Side by side while the board is wider than tall; otherwise the sections stack and the cards go two across.
        let stacked = size.width < size.height || size.width < 720
        return Group {
            if stacked {
                NativePlannerSectionStack(spacing: 14) { ForEach(statuses, id: \.self) { column($0, across: size.width >= 640 ? 2 : 1, inset: 15) } }
            } else {
                HStack(alignment: .top, spacing: 14) { ForEach(statuses, id: \.self) { column($0, across: 1, inset: 13) } }
            }
        }.padding(.horizontal, 24).padding(.vertical, 20)
    }
    private func column(_ status: String, across: Int, inset: CGFloat) -> some View {
        let values = visibleTasks.filter { $0.status == status }, title = NativePlannerTask.statusTitle(status)
        let cards = VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<across, id: \.self) { index in
                    VStack(spacing: 10) { ForEach(values.enumerated().filter { $0.offset % across == index }.map(\.element)) { card($0) } }
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            if status != "done" {
                Button { editor = TaskEditorIdentity(task: nil, status: status) } label: {
                    HStack(spacing: 6) { Image(systemName: "plus"); Text("할 일 추가") }.font(.system(size: 14))
                        .foregroundStyle(NativeDesktopTheme.muted).padding(6).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(title + " 열에 할 일 추가")
                    .accessibilityIdentifier(status == "todo" ? "native-task-add" : "native-task-add-" + status)
            }
        }.padding(.horizontal, inset).padding(.bottom, 2)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: NativePlannerTask.statusSymbols[status] ?? "circle").font(.system(size: 15, weight: .semibold)).frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(String(values.count)).font(.system(size: 14, weight: .medium)).foregroundStyle(NativeDesktopTheme.muted)
            }.frame(height: 21).padding(.horizontal, inset + 4).accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            // The cards at their own height while they fit, which is also what the stacked layout measures. Past that
            // they scroll, and the scroll view spans the column so its indicator sits in the gutter beside the cards.
            ViewThatFits(in: .vertical) { cards; ScrollView { cards }.scrollIndicatorsFlash(onAppear: true) }
        }
        .padding(.vertical, 15).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NativePlannerPalette.panel, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(NativeDesktopTheme.border) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-planner-column-" + status)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let task = tasks.first(where: { $0.id == id }) else { return false }
            setStatus(task, status: status); return true
        }
    }

    // MARK: Card
    /// A task card with its popover, long-press menu and drag: the same in a column and in the calendar's day panel.
    private func card(_ task: NativePlannerTask) -> some View {
        let course = store.courses.first { $0.id == task.courseId }
        return Button { detailID = task.id } label: { NativePlannerCard(task: task, course: course, selected: detailID == task.id) }
            .buttonStyle(.plain).disabled(changing.contains(task.id))
            .accessibilityLabel(task.title).accessibilityValue([course?.name, task.dueText(), NativePlannerTask.statusTitle(task.status)].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("native-task-edit-\(task.id)")
            .bandalPopover(isPresented: .editing(task.id, in: $detailID), arrowEdge: .leading, width: 362) {
                NativePlannerTaskDetail(task: task, course: course,
                    setStatus: { detailID = nil; setStatus(task, status: $0) }, delete: { detailID = nil; delete(task) })
            }
            .contextMenu {
                ForEach(NativePlannerTask.statuses, id: \.self) { status in Button(NativePlannerTask.statusTitle(status)) { setStatus(task, status: status) } }
                Button("수정") { editor = TaskEditorIdentity(task: task) }
                Button("삭제", role: .destructive) { pendingDeletion = task }
            }
            .bandalConfirm("할 일을 삭제할까요?", isPresented: Binding(get: { pendingDeletion?.id == task.id }, set: { if !$0 { pendingDeletion = nil } }), action: "삭제", destructive: true) {
                pendingDeletion = nil; delete(task)
            }
            .draggable(task.id)
    }

    // MARK: Editor
    /// 새 할 일 as a small sheet one layer above the board, centred in what the keyboard leaves of it.
    private func editorSheet(_ item: TaskEditorIdentity, in size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28)
        return ZStack {
            Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture { editor = nil }.accessibilityHidden(true)
            NativeTaskEditor(task: item.task, courses: store.courses, defaultCourseID: courseFilter ?? courseID ?? store.selectedCourseID,
                             defaultStatus: item.status, defaultDueDate: item.date, close: { editor = nil }) { request in
                _ = try await store.invoke(item.task == nil ? "board:createTask" : "board:updateTask", request)
                await load()
            }
            .frame(maxWidth: 540, maxHeight: max(200, size.height - keyboardInset - 32)).fixedSize(horizontal: false, vertical: true)
            // Glass does not show through glass: the sheet gets a body of its own, and a shape so that a tap on it stays on it.
            .contentShape(shape).bandalGlass(in: shape, fill: NativeGlass.sheet)
            .padding(16).padding(.bottom, keyboardInset)
            .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal).accessibilityIdentifier("native-task-editor")
            .id(item.id)
        }.frame(width: size.width, height: size.height)
    }

    // MARK: Data
    private func load() async {
        let identifier = UUID(); requestID = identifier
        do {
            if !preferencesLoaded {
                // Unreadable settings fall back to the defaults; the tasks still load.
                let tabs = ((try? await store.invoke("settings:get")) as? [String: Any])?["tabs"] as? [String: Any] ?? [:]
                if !preferencesLoaded {
                    mode = tabs["boardDefaultView"] as? String == "board" ? "board" : "calendar"
                    hidingDone = tabs["boardHideDone"] as? Bool == true
                    preferencesLoaded = true
                }
            }
            let result: [NativePlannerTask] = try NativeToolJSON.decode(try await store.invoke("board:listTasks", ["includeDone": true]))
            guard identifier == requestID else { return }
            tasks = result; error = nil
        } catch { if identifier == requestID { self.error = error.localizedDescription } }
    }
    private func setStatus(_ task: NativePlannerTask, status: String) {
        guard status != task.status, changing.insert(task.id).inserted else { return }
        Task {
            defer { changing.remove(task.id) }
            do { _ = try await store.invoke("board:updateTask", ["id": task.id, "status": status]); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func delete(_ task: NativePlannerTask) {
        Task {
            do { _ = try await store.invoke("board:deleteTask", ["id": task.id]); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
}
