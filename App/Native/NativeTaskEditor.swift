import SwiftUI

/// 새 할 일 · 할 일 수정: 취소 and 추가 on top, the title, the course, a strip of days for the due date,
/// then time, status and memo. Enter or 추가 saves; the host closes it.
struct NativeTaskEditor: View {
    let task: NativePlannerTask?
    let courses: [NativeCourse]
    let close: () -> Void
    let save: ([String: Any]) async throws -> Void
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
    @State private var choosingTime = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    init(task: NativePlannerTask?, courses: [NativeCourse], defaultCourseID: String?, defaultStatus: String = "todo", defaultDueDate: Date? = nil,
         close: @escaping () -> Void, save: @escaping ([String: Any]) async throws -> Void) {
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
    }

    /// 오후 11:59, the time a due date gets when it is first given one.
    private static var endOfDay: Date { Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date()) ?? Date() }
    /// The days on the due strip: eight weeks from today, starting earlier or reaching further for a due day outside them.
    static func stripDays(today: Date, due: Date?, calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: min(today, due ?? today))
        let end = max(calendar.date(byAdding: .day, value: 55, to: calendar.startOfDay(for: today)) ?? today,
                      due.flatMap { calendar.date(byAdding: .day, value: 6, to: calendar.startOfDay(for: $0)) } ?? today)
        let count = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
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
            }.buttonStyle(.plain).padding(.horizontal, 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TextField("제목", text: $title).font(.system(size: 18, weight: .semibold)).textFieldStyle(.plain)
                        .focused($titleFocused).submitLabel(.done).onSubmit(submit)
                        .padding(.horizontal, 16).frame(minHeight: 55)
                        .background(NativePlannerPalette.paper, in: RoundedRectangle(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(NativeDesktopTheme.border) }
                        .accessibilityIdentifier("native-task-title")
                    if !courses.isEmpty { section("과목") { courseChips } }
                    // The strip shows day numbers only; the month of the chosen day is spelled out beside the label.
                    section("마감", detail: dueDay?.formatted(.dateTime.month().day().weekday(.wide))) { dueStrip }
                    details
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
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
            }
            content()
        }
    }
    private var courseChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(courses) { course in
                    NativePlannerChip(title: course.name, tint: course.tint, selected: courseID == course.id) { courseID = courseID == course.id ? "" : course.id }
                        .accessibilityLabel("과목 " + course.name).accessibilityIdentifier("native-task-course-" + course.id)
                }
            }.padding(.vertical, 1)
        }
    }
    private var dueStrip: some View {
        let calendar = Calendar.current
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Self.stripDays(today: Date(), due: dueDay), id: \.self) { day in
                        let on = dueDay == day
                        Button { dueDay = on ? nil : day } label: {
                            VStack(spacing: 2) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 12))
                                    .foregroundStyle(on ? NativePlannerPalette.paper : NativeDesktopTheme.muted)
                                Text(String(calendar.component(.day, from: day))).font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(on ? NativePlannerPalette.paper : NativeDesktopTheme.text)
                            }
                            .frame(width: 64, height: 57).background(on ? NativeDesktopTheme.secondary : .clear, in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).id(day)
                            .accessibilityLabel("마감 " + day.formatted(.dateTime.month().day().weekday(.wide))).accessibilityAddTraits(on ? .isSelected : [])
                            .accessibilityIdentifier("native-task-due-" + NativePlannerTask.dayFormatter.string(from: day))
                    }
                }
            }.frame(height: 57).onAppear { if let dueDay { proxy.scrollTo(dueDay, anchor: .center) } }
        }
    }
    private var details: some View {
        VStack(spacing: 0) {
            let timeText = dueDay == nil ? "마감 없음" : allDay ? "하루 종일" : time.formatted(date: .omitted, time: .shortened)
            BandalSettingRow(title: "시간", size: 15) {
                // Opens in place: under the keyboard a popover from this row has nowhere to go, so the keyboard goes first.
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    choosingTime.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text(timeText).foregroundStyle(NativeDesktopTheme.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(NativeDesktopTheme.muted)
                            .rotationEffect(.degrees(choosingTime && dueDay != nil ? 90 : 0))
                    }.font(.system(size: 15)).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(dueDay == nil)
                    .accessibilityLabel("마감 시간").accessibilityValue(timeText).accessibilityIdentifier("native-task-time")
            }.padding(.horizontal, 16).frame(minHeight: 47)
            if choosingTime && dueDay != nil {
                separator
                BandalSettingRow(title: "하루 종일", size: 15) { Toggle("하루 종일", isOn: $allDay).labelsHidden().accessibilityIdentifier("native-task-all-day") }
                    .padding(.horizontal, 16).frame(minHeight: 47)
                if !allDay {
                    DatePicker("시간", selection: $time, displayedComponents: .hourAndMinute).datePickerStyle(.wheel).labelsHidden()
                        .frame(height: 132).clipped().accessibilityIdentifier("native-task-time-picker")
                }
            }
            separator
            BandalSettingRow(title: "상태", size: 15) {
                BandalSegmented(options: (task == nil ? ["todo", "in-progress"] : NativePlannerTask.statuses).map { ($0, NativePlannerTask.statusTitle($0)) },
                                selection: $status, identifierPrefix: "native-task-editor-status-", spoken: "상태")
            }.padding(.horizontal, 16).frame(minHeight: 58)
            separator
            TextField("메모", text: $notes, axis: .vertical).font(.system(size: 15)).lineLimit(1...4).textFieldStyle(.plain)
                .padding(.horizontal, 16).padding(.vertical, 13).accessibilityIdentifier("native-task-notes")
        }
        .background(NativePlannerPalette.paper, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(NativeDesktopTheme.border) }
    }
    private var separator: some View { NativeDesktopTheme.border.frame(height: 1).padding(.leading, 16) }

    private func submit() {
        guard ready else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            var request: [String: Any] = ["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "notes": notes,
                "courseId": courseID.isEmpty ? NSNull() : courseID as Any, "status": status]
            request.merge(Self.dueFields(task: task, day: dueDay, allDay: allDay, time: time)) { _, new in new }
            if let task { request["id"] = task.id }
            do { try await save(request); close() }
            catch { self.error = error.localizedDescription }
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
