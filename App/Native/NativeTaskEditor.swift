import SwiftUI

/// 새 할 일 · 할 일 수정: 취소 and 추가 on top, the title, the course, a week of days for the due date,
/// then time, reminder, status and the linked note. Enter or 추가 saves; the host closes it.
struct NativeTaskEditor: View {
    let task: NativePlannerTask?
    let courses: [NativeCourse]
    let close: () -> Void
    /// Sends the request and returns what the store answered (the saved task).
    let save: ([String: Any]) async throws -> Any?
    @State private var title: String
    @State private var notes: String
    /// Empty for a task that belongs to no course.
    @State private var courseID: String
    @State private var status: String
    /// The start of the due day; nil while the task has no due date.
    @State private var dueDay: Date?
    @State private var allDay: Bool
    /// Only its hour and minute are used, and only while the task is not all day.
    @State private var time: Date
    @State private var reminder: NativePlannerReminder
    /// The Monday of the week the due strip shows.
    @State private var week: Date?
    /// The detail row that is open in place: "time", "reminder" or "notes".
    @State private var expanded: String?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    init(task: NativePlannerTask?, courses: [NativeCourse], defaultCourseID: String?, defaultStatus: String = "todo", defaultDueDate: Date? = nil,
         close: @escaping () -> Void, save: @escaping ([String: Any]) async throws -> Any?) {
        self.task = task; self.courses = courses; self.close = close; self.save = save
        let due = task == nil ? defaultDueDate : task?.dueDate
        _title = State(initialValue: task?.title ?? "")
        _notes = State(initialValue: task?.notes ?? "")
        _courseID = State(initialValue: task == nil ? defaultCourseID ?? "" : task?.courseId ?? "")
        _status = State(initialValue: task?.status ?? defaultStatus)
        _dueDay = State(initialValue: due.map { Calendar.current.startOfDay(for: $0) })
        // A task without a due date starts all day when it is given one, whatever flag it was stored with.
        _allDay = State(initialValue: task?.dueAt == nil ? true : task?.allDay ?? true)
        _time = State(initialValue: task?.allDay == false ? due ?? Self.endOfDay : Self.endOfDay)
        _reminder = State(initialValue: task.map { NativePlannerReminder.choice(for: $0.id) } ?? .off)
        _week = State(initialValue: Self.weekStart(due ?? Date()))
        // A memo the task already has is shown; an empty one stays folded away.
        _expanded = State(initialValue: task?.notes.isEmpty == false ? "notes" : nil)
    }

    /// 오후 11:59, the time a due date gets when it is first given one.
    private static var endOfDay: Date { Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date()) ?? Date() }
    /// The Monday on or before `day`: the strip runs 월–일 whatever the device's first weekday.
    static func weekStart(_ day: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: start) + 5) % 7), to: start) ?? start
    }
    /// The weeks on the due strip, each 월–일: from this week (or an earlier due day's) for eight weeks, further for a later due day.
    static func stripWeeks(today: Date, due: Date?, calendar: Calendar = .current) -> [[Date]] {
        let first = weekStart(min(today, due ?? today), calendar: calendar)
        let last = max(calendar.date(byAdding: .day, value: 49, to: weekStart(today, calendar: calendar)) ?? today, weekStart(due ?? today, calendar: calendar))
        let count = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) / 7 + 1
        return (0..<count).map { week in (0..<7).compactMap { calendar.date(byAdding: .day, value: week * 7 + $0, to: first) } }
    }
    private var ready: Bool { !busy && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Button("취소", action: close).font(.system(size: 16)).accessibilityLabel("할 일 편집 취소").accessibilityIdentifier("native-task-cancel")
                Spacer()
                Text(task == nil ? "새 할 일" : "할 일 수정").font(.system(size: 17, weight: .bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(task == nil ? "추가" : "저장", action: submit).font(.system(size: 16, weight: .bold)).disabled(!ready).opacity(ready ? 1 : 0.35)
                    .accessibilityLabel(task == nil ? "할 일 추가 완료" : "할 일 저장").accessibilityIdentifier("native-task-save")
            }.buttonStyle(.plain).frame(height: 24).padding(.horizontal, 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TextField("제목", text: $title).font(.system(size: 18, weight: .semibold)).textFieldStyle(.plain)
                        .focused($titleFocused).submitLabel(.done).onSubmit(submit)
                        .padding(.horizontal, 17).frame(height: 55)
                        .background(NativePlannerPalette.paper, in: RoundedRectangle(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(NativeDesktopTheme.border) }
                        .accessibilityIdentifier("native-task-title")
                    if !courses.isEmpty { section("과목") { courseChips } }
                    section("마감", detail: dueDetail) { dueStrip }
                    details
                    if expanded != "notes" { notesDisclosure }
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(NativePlannerPalette.urgent).fixedSize(horizontal: false, vertical: true) }
                }.padding(.horizontal, 28)
            }.scrollBounceBehavior(.basedOnSize)
        }
        .padding(.vertical, 22).foregroundStyle(NativeDesktopTheme.text)
        .disabled(busy)
        .onAppear { if task == nil { titleFocused = true } }
    }

    private func section<Content: View>(_ label: String, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary)
                if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.muted) }
            }.frame(height: 18)
            content()
        }
    }
    private var courseChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(courses) { course in
                    NativePlannerChip(title: course.name, tint: course.tint, selected: courseID == course.id, inset: 13) { courseID = courseID == course.id ? "" : course.id }
                        .accessibilityLabel("과목 " + course.name).accessibilityIdentifier("native-task-course-" + course.id)
                }
            }.frame(height: 36)
        }
    }
    /// The strip shows day numbers only. This week needs no more; a due day or a week further away is spelled out beside the label.
    private var dueDetail: String? {
        let thisWeek = Self.weekStart(Date())
        if let dueDay, Self.weekStart(dueDay) != thisWeek || week != thisWeek { return dueDay.formatted(.dateTime.month().day().weekday(.wide)) }
        return week.flatMap { $0 == thisWeek ? nil : $0.formatted(.dateTime.year().month()) }
    }
    private var dueStrip: some View {
        let calendar = Calendar.current
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Self.stripWeeks(today: Date(), due: dueDay), id: \.self) { days in
                    HStack(spacing: 6) {
                        ForEach(days, id: \.self) { day in
                            let on = dueDay == day
                            Button { dueDay = on ? nil : day } label: {
                                VStack(spacing: 2) {
                                    Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 12))
                                        .foregroundStyle(on ? NativePlannerPalette.paper : NativeDesktopTheme.muted)
                                    Text(String(calendar.component(.day, from: day))).font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(on ? NativePlannerPalette.paper : NativeDesktopTheme.text)
                                }
                                .frame(maxWidth: .infinity).frame(height: 57).background(on ? NativeDesktopTheme.secondary : .clear, in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("마감 " + day.formatted(.dateTime.month().day().weekday(.wide))).accessibilityAddTraits(on ? .isSelected : [])
                                .accessibilityIdentifier("native-task-due-" + NativePlannerTask.dayFormatter.string(from: day))
                        }
                    }.containerRelativeFrame(.horizontal).id(days[0])
                }
            }.scrollTargetLayout()
        }.scrollTargetBehavior(.paging).scrollPosition(id: $week).frame(height: 57)
    }
    private var details: some View {
        VStack(spacing: 0) {
            let timeText = dueDay == nil ? "마감 없음" : allDay ? "하루 종일" : time.formatted(date: .omitted, time: .shortened)
            // The rows open in place: under the keyboard a popover from a row has nowhere to go, so the keyboard goes first.
            disclosure("시간", value: timeText, key: "time", spoken: "마감 시간", identifier: "native-task-time").disabled(dueDay == nil)
            if expanded == "time" && dueDay != nil {
                separator
                BandalSettingRow(title: "하루 종일", size: 15) { Toggle("하루 종일", isOn: $allDay).labelsHidden().accessibilityIdentifier("native-task-all-day") }
                    .padding(.horizontal, 16).frame(minHeight: 47)
                if !allDay {
                    DatePicker("시간", selection: $time, displayedComponents: .hourAndMinute).datePickerStyle(.wheel).labelsHidden()
                        .frame(height: 132).clipped().accessibilityIdentifier("native-task-time-picker")
                }
            }
            separator
            disclosure("알림", value: dueDay == nil ? "마감 없음" : reminder.title, key: "reminder", spoken: "알림", identifier: "native-task-reminder").disabled(dueDay == nil)
            if expanded == "reminder" && dueDay != nil {
                ForEach(NativePlannerReminder.allCases, id: \.self) { choice in
                    separator
                    Button { choose(choice) } label: {
                        HStack {
                            Text(choice.title).font(.system(size: 15)).foregroundStyle(NativeDesktopTheme.secondary)
                            Spacer()
                            if reminder == choice { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)) }
                        }.padding(.horizontal, 16).frame(height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("알림 " + choice.title).accessibilityAddTraits(reminder == choice ? .isSelected : [])
                        .accessibilityIdentifier("native-task-reminder-" + choice.rawValue)
                }
            }
            separator
            BandalSettingRow(title: "상태", size: 15) {
                NativePlannerStatusSwitch(statuses: task == nil ? ["todo", "in-progress"] : NativePlannerTask.statuses, selection: $status,
                                          identifierPrefix: "native-task-editor-status-", compact: true)
            }.padding(.horizontal, 16).frame(height: 58)
            separator
            // 준비 중: the synced task record has no field for a linked note yet.
            BandalSettingRow(title: "노트 연결", size: 15) {
                HStack(spacing: 6) {
                    Text("준비 중").font(.system(size: 15)).foregroundStyle(NativeDesktopTheme.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
                }
            }.padding(.horizontal, 16).frame(height: 47).opacity(0.5).accessibilityElement(children: .combine).accessibilityIdentifier("native-task-link-note")
            if expanded == "notes" {
                separator
                TextField("메모", text: $notes, axis: .vertical).font(.system(size: 15)).lineLimit(1...4).textFieldStyle(.plain)
                    .padding(.horizontal, 16).padding(.vertical, 13).accessibilityIdentifier("native-task-notes")
            }
        }
        .background(NativePlannerPalette.paper, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(NativeDesktopTheme.border) }
    }
    private func disclosure(_ title: String, value: String, key: String, spoken: String, identifier: String) -> some View {
        BandalSettingRow(title: title, size: 15) {
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                expanded = expanded == key ? nil : key
            } label: {
                HStack(spacing: 6) {
                    Text(value).foregroundStyle(NativeDesktopTheme.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
                        .rotationEffect(.degrees(expanded == key && dueDay != nil ? 90 : 0))
                }.font(.system(size: 15)).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(spoken).accessibilityValue(value).accessibilityIdentifier(identifier)
        }.padding(.horizontal, 16).frame(height: 47)
    }
    /// 메모 is not in the drawn sheet: it waits behind this line under the list.
    private var notesDisclosure: some View {
        Button { expanded = "notes" } label: {
            Text("메모 추가").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.muted).frame(minHeight: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.top, -14).accessibilityIdentifier("native-task-notes-add")
    }
    private var separator: some View { NativeDesktopTheme.border.frame(height: 1).padding(.leading, 16) }

    private func choose(_ choice: NativePlannerReminder) {
        reminder = choice; expanded = nil
        guard choice != .off else { return }
        Task { @MainActor in
            if await !NativePlannerReminder.authorized() { reminder = .off; error = "알림이 꺼져 있어요. iPad 설정 › 알림 › 반달에서 허용해 주세요." }
        }
    }
    private func submit() {
        guard ready else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            var request: [String: Any] = ["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "notes": notes,
                "courseId": courseID.isEmpty ? NSNull() : courseID as Any, "status": status]
            request.merge(Self.dueFields(task: task, day: dueDay, allDay: allDay, time: time)) { _, new in new }
            if let task { request["id"] = task.id }
            do {
                let saved = try await save(request)
                // The reminder is this iPad's own: it is kept beside the task, not in it.
                if let saved, let result: NativePlannerTask = try? NativeToolJSON.decode(saved) { NativePlannerReminder.set(dueDay == nil ? .off : reminder, for: result) }
                close()
            } catch { self.error = error.localizedDescription }
        }
    }
    /// `allDay` and `dueAt` for the request: the day alone for an all-day task, otherwise that day at the chosen hour
    /// and minute. Empty when an existing task's date was left as it came, so that what this sheet cannot show
    /// (seconds, a start date, a date it could not read) is not rewritten by a rename.
    static func dueFields(task: NativePlannerTask?, day: Date?, allDay: Bool, time: Date, calendar: Calendar = .current) -> [String: Any] {
        let clock = { calendar.dateComponents([.hour, .minute], from: $0) }
        if let task {
            let original = task.dueDate
            let sameDay = day == original.map { calendar.startOfDay(for: $0) }
            if sameDay && (day == nil || (allDay == task.allDay && (allDay || clock(time) == clock(original ?? time)))) { return [:] }
        }
        guard let day else { return ["allDay": allDay, "dueAt": NSNull()] }
        if allDay { return ["allDay": true, "dueAt": NativePlannerTask.dayFormatter.string(from: day)] }
        let due = calendar.date(bySettingHour: clock(time).hour ?? 23, minute: clock(time).minute ?? 59, second: 0, of: day) ?? day
        return ["allDay": false, "dueAt": ISO8601DateFormatter().string(from: due)]
    }
}
