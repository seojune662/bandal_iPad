import SwiftUI

struct NativePlannerExternalEvent: Decodable, Identifiable {
    let id: String
    let title: String
    let startAt: String
    let dueAt: String
    let allDay: Bool
    let calendarTitle: String
    var start: Date? { NativeNotificationPlan.date(startAt) }
    func occurs(on day: Date, calendar: Calendar = .current) -> Bool {
        guard let start, let end = NativeNotificationPlan.date(dueAt), let interval = calendar.dateInterval(of:.day,for:day) else { return false }
        // EventKit end dates are exclusive (including multi-day all-day events).
        return start < interval.end && max(end,start.addingTimeInterval(1)) > interval.start
    }
}

struct NativePlannerCalendar: View {
    @ObservedObject var store: NativeWorkspaceStore
    let tasks: [NativePlannerTask]
    let courses: [NativeCourse]
    let onEdit: (NativePlannerTask) -> Void
    let onCreate: (Date) -> Void
    @State private var month = Date()
    @State private var selectedDay = Date()
    @State private var externalEvents: [NativePlannerExternalEvent] = []
    @State private var calendarError: String?
    @State private var refreshToken = UUID()
    @Environment(\.scenePhase) private var scenePhase
    private var calendar: Calendar { Calendar.current }
    private var days: [Date] {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let count = ((offset + range.count + 6) / 7) * 7
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: start) }
    }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(month.formatted(.dateTime.year().month(.wide))).font(.system(size: 18, weight: .semibold))
                        Spacer()
                        Button("이전 달", systemImage: "chevron.left") { moveMonth(-1) }.buttonStyle(NativeToolIconStyle())
                        Button("오늘") { month = Date(); selectedDay = Date() }.buttonStyle(NativeToolButtonStyle(compact: true))
                        Button("다음 달", systemImage: "chevron.right") { moveMonth(1) }.buttonStyle(NativeToolIconStyle())
                    }.frame(height: 44).padding(.bottom, 12)
                    if let calendarError { NativeToolError(message:calendarError) }
                    weekdays
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                            ForEach(days, id: \.self) { day in dayCell(day) }
                        }.padding(1).background(NativeDesktopTheme.border)
                    }
                    if geometry.size.width < 760 { agenda.frame(maxHeight: 260).padding(.top, 12) }
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if geometry.size.width >= 760 {
                    NativeDesktopTheme.border.frame(width: 1)
                    agenda.padding(16).frame(width: 320, alignment: .top).frame(maxHeight: .infinity, alignment: .top).background(NativeDesktopTheme.surface)
                }
            }
        }
        .task(id:month) { await loadExternalEvents() }
        .onReceive(store.events) { event in
            if event.channel == "settings:changed" { Task { await loadExternalEvents() } }
        }
        .onChange(of:scenePhase) { _, phase in if phase == .active { Task { await loadExternalEvents() } } }
    }
    private func loadExternalEvents() async {
        let token = UUID(); refreshToken = token
        guard let first = days.first, let last = days.last, let end = calendar.date(byAdding:.day,value:1,to:last) else { return }
        do {
            let formatter = ISO8601DateFormatter()
            let result: [NativePlannerExternalEvent] = try NativeToolJSON.decode(try await store.invokePrivate("nativeSettings:calendarEvents",["from":formatter.string(from:first),"to":formatter.string(from:end)]))
            guard refreshToken == token else { return }
            externalEvents = result; calendarError = nil
        } catch { if refreshToken == token { calendarError = error.localizedDescription } }
    }
    private func openExternalEvent(_ event: NativePlannerExternalEvent) {
        Task { do { _ = try await store.invokePrivate("nativeSettings:openCalendar",["date":event.startAt]) } catch { calendarError = error.localizedDescription } }
    }
    private var weekdays: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return HStack(spacing: 0) {
            ForEach(0..<7) { index in
                let position = (index + calendar.firstWeekday - 1) % 7
                Text(symbols[position]).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(position == 0 ? Color.red : NativeDesktopTheme.muted).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        }.background(NativeDesktopTheme.surface).overlay(Rectangle().strokeBorder(NativeDesktopTheme.border))
    }
    private func dayCell(_ day: Date) -> some View {
        let today = calendar.isDateInToday(day), selected = calendar.isDate(day, inSameDayAs: selectedDay)
        let outside = !calendar.isDate(day, equalTo: month, toGranularity: .month)
        let entries = tasks.filter { $0.occurs(on: day, calendar: calendar) }
        let external = externalEvents.filter { $0.occurs(on:day,calendar:calendar) }
        return VStack(alignment: .leading, spacing: 4) {
            Button { selectedDay = day } label: {
                Text(String(calendar.component(.day, from: day))).font(.system(size: 12, design: .monospaced)).frame(width: 28, height: 28)
                    .foregroundStyle(today ? NativeDesktopTheme.onAccent : outside ? NativeDesktopTheme.muted : NativeDesktopTheme.secondary)
                    .background(today ? NativeDesktopTheme.accent : .clear, in: Circle())
            }.buttonStyle(.plain)
            ForEach(entries.prefix(3)) { task in
                Button { selectedDay = day; onEdit(task) } label: {
                    Text(task.title).font(.system(size: 11)).lineLimit(1).strikethrough(task.completed)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.vertical, 3)
                        .background(NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 3))
                }.buttonStyle(.plain)
            }
            ForEach(external.prefix(max(0,3-entries.count))) { event in
                Button { selectedDay = day; openExternalEvent(event) } label: {
                    Label(event.title,systemImage:"calendar").font(.system(size:11)).lineLimit(1)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,4).padding(.vertical,3)
                        .background(NativeDesktopTheme.accentMuted,in:RoundedRectangle(cornerRadius:3))
                }.buttonStyle(.plain)
            }
            if entries.count + external.count > 3 { Text("+\(entries.count + external.count - 3)").font(.system(size: 10)).foregroundStyle(NativeDesktopTheme.muted) }
            Spacer(minLength: 0)
        }.padding(4).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(selected ? NativeDesktopTheme.raised : outside ? NativeDesktopTheme.bgApp : NativeDesktopTheme.surface)
            .overlay(Rectangle().strokeBorder(selected ? NativeDesktopTheme.muted : .clear))
            .contentShape(Rectangle()).onTapGesture { selectedDay = day }
            .contextMenu { Button("일정 추가", systemImage: "plus") { onCreate(day) } }
    }
    private var agenda: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(selectedDay.formatted(.dateTime.month().day().weekday(.wide))).font(.system(size: 16, weight: .medium))
                Spacer()
                Button("일정 추가", systemImage: "plus") { onCreate(selectedDay) }.buttonStyle(NativeToolIconStyle())
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    let entries = tasks.filter { $0.occurs(on: selectedDay, calendar: calendar) }
                    let external = externalEvents.filter { $0.occurs(on:selectedDay,calendar:calendar) }
                    if entries.isEmpty && external.isEmpty { Text("이 날짜에 예정된 일정이 없어요.").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.muted).padding(.vertical, 24) }
                    ForEach(entries) { task in
                        Button { onEdit(task) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.title).font(.system(size: 13, weight: .medium)).strikethrough(task.completed)
                                if let course = courses.first(where: { $0.id == task.courseId }) { Text(course.name).font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted) }
                                if !task.notes.isEmpty { Text(task.notes).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(3) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(NativeDesktopTheme.border))
                        }.buttonStyle(.plain)
                    }
                    ForEach(external) { event in
                        Button { openExternalEvent(event) } label: {
                            VStack(alignment:.leading,spacing:6) {
                                Label(event.title,systemImage:"calendar").font(.system(size:13,weight:.medium))
                                Text(event.calendarTitle).font(.system(size:11)).foregroundStyle(NativeDesktopTheme.muted)
                                if !event.allDay, let start = event.start { Text(start.formatted(date:.omitted,time:.shortened)).font(.system(size:12)) }
                            }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                                .background(NativeDesktopTheme.accentMuted,in:RoundedRectangle(cornerRadius:6))
                        }.buttonStyle(.plain).accessibilityHint("Apple 캘린더에서 열기")
                    }
                }
            }
            Button("일정 추가", systemImage: "plus") { onCreate(selectedDay) }.buttonStyle(NativeToolButtonStyle(primary: true))
        }
    }
    private func moveMonth(_ count: Int) { if let date = calendar.date(byAdding: .month, value: count, to: month) { month = date } }
}
