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

/// The board's 달력: a month of days with each task as a chip, and a panel for the chosen day beside it.
struct NativePlannerCalendar<Card: View>: View {
    var store: NativeWorkspaceStore
    let tasks: [NativePlannerTask]
    let onCreate: (Date) -> Void
    /// The board's task card (popover, menu and drag included).
    @ViewBuilder let card: (NativePlannerTask) -> Card
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
            // The day panel sits beside the month, or under it where the board is narrow.
            if geometry.size.width >= 760 {
                HStack(spacing: 0) { monthView; NativeDesktopTheme.border.frame(width: 1); dayPanel.frame(width: 340) }
            } else {
                VStack(spacing: 0) { monthView; NativeDesktopTheme.border.frame(height: 1); dayPanel.frame(height: min(300, geometry.size.height * 0.42)) }
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

    // MARK: Month
    private var monthView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(month.formatted(.dateTime.year().month(.wide))).font(.system(size: 22, weight: .bold)).lineLimit(1)
                Spacer(minLength: 0)
                monthStep("이전 달", symbol: "chevron.left", by: -1)
                Button { month = Date(); selectedDay = Date() } label: {
                    Text("오늘").font(.system(size: 13, weight: .medium)).padding(.horizontal, 13).frame(height: 30)
                        .background(NativePlannerPalette.paper, in: Capsule()).overlay { Capsule().strokeBorder(NativeDesktopTheme.border) }.contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityLabel("오늘로 이동").accessibilityIdentifier("native-planner-today")
                monthStep("다음 달", symbol: "chevron.right", by: 1)
            }.frame(height: 31)
            if let calendarError { NativeToolError(message:calendarError) }
            weekdays
            grid
        }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 23).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private func monthStep(_ title: String, symbol: String, by count: Int) -> some View {
        Button { if let date = calendar.date(byAdding: .month, value: count, to: month) { month = date } } label: {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(NativeDesktopTheme.secondary).frame(width: 11, height: 30).contentShape(Rectangle().inset(by: -10))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
    private var weekdays: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return HStack(spacing: 0) {
            ForEach(0..<7) { index in
                Text(symbols[(index + calendar.firstWeekday - 1) % 7]).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NativeDesktopTheme.muted).frame(maxWidth: .infinity)
            }
        }.frame(height: 30).accessibilityHidden(true)
    }
    private var grid: some View {
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        return GeometryReader { geometry in
            // The weeks share the height; a short board scrolls rather than squeezing a week under 72 pt.
            let size = CGSize(width: geometry.size.width / 7, height: max(72, geometry.size.height / CGFloat(max(weeks.count, 1))))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(weeks, id: \.self) { week in
                        HStack(spacing: 0) { ForEach(week, id: \.self) { dayCell($0, size: size) } }
                    }
                }
            }.scrollBounceBehavior(.basedOnSize)
        }
        .background(NativePlannerPalette.panel).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(NativePlannerPalette.panelStroke) }
    }
    private func dayCell(_ day: Date, size: CGSize) -> some View {
        let today = calendar.isDateInToday(day), selected = calendar.isDate(day, inSameDayAs: selectedDay)
        let outside = !calendar.isDate(day, equalTo: month, toGranularity: .month)
        let entries = tasks.filter { $0.occurs(on: day, calendar: calendar) }
        let external = externalEvents.filter { $0.occurs(on:day,calendar:calendar) }
        // Under the 26 pt number, as many 23 pt chips (4 pt apart) as the cell holds; the rest are counted beside the number.
        let total = entries.count + external.count, shown = min(total, max(1, Int((size.height - 42) / 27)))
        return Button { selectedDay = day } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text(String(calendar.component(.day, from: day))).font(.system(size: 14, weight: today ? .semibold : .regular))
                        .foregroundStyle(today ? NativePlannerPalette.paper : outside ? NativeDesktopTheme.muted : NativeDesktopTheme.text)
                        .frame(width: 26, height: 26).background(today ? NativeDesktopTheme.text : .clear, in: Circle())
                    Spacer(minLength: 0)
                    if total > shown { Text("+\(total - shown)").font(.system(size: 11, weight: .medium)).foregroundStyle(NativeDesktopTheme.muted) }
                }
                ForEach(entries.prefix(shown)) { task in
                    chip(task.title, color: task.completed ? NativeDesktopTheme.muted : task.dueBadge()?.urgent == true ? NativePlannerPalette.urgent : NativeDesktopTheme.text) {
                        Circle().fill(store.courses.first { $0.id == task.courseId }?.tint ?? NativeDesktopTheme.muted).frame(width: 6, height: 6)
                    }
                }
                ForEach(external.prefix(max(0, shown - entries.count))) { event in
                    chip(event.title, color: NativeDesktopTheme.secondary) { Image(systemName: "calendar").font(.system(size: 9)).foregroundStyle(NativeDesktopTheme.muted) }
                }
            }
            .padding(8).frame(width: size.width, height: size.height, alignment: .topLeading)
            // Today already carries the dark circle; another chosen day is filled lightly.
            .background(selected && !today ? NativeGlass.selection : .clear)
            .overlay { Rectangle().strokeBorder(NativeDesktopTheme.text.opacity(0.06), lineWidth: 0.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(day.formatted(.dateTime.month().day().weekday(.wide)) + (total > 0 ? ", 일정 \(total)개" : ""))
        .accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier("native-planner-day-" + NativePlannerTask.dayFormatter.string(from: day))
        .contextMenu { Button("할 일 추가", systemImage: "plus") { onCreate(day) } }
    }
    /// One line in a day cell; a long title fades out at the edge instead of ending in "…".
    private func chip<Mark: View>(_ title: String, color: Color, @ViewBuilder mark: () -> Mark) -> some View {
        let label = HStack(spacing: 5) {
            mark()
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(color).lineLimit(1).fixedSize()
        }
        return ViewThatFits(in: .horizontal) {
            label
            // minWidth 0: without it the frame grows to the title instead of cutting it.
            label.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
                .mask { HStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 20) } }
        }
        .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 23, maxHeight: 23, alignment: .leading)
        .background(NativePlannerPalette.paper, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Day
    private var dayPanel: some View {
        let entries = tasks.filter { $0.occurs(on: selectedDay, calendar: calendar) }
        let external = externalEvents.filter { $0.occurs(on:selectedDay,calendar:calendar) }
        let title = selectedDay.formatted(.dateTime.month().day().weekday(.wide))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 19, weight: .bold)).lineLimit(1)
                Spacer(minLength: 0)
                Button { onCreate(selectedDay) } label: {
                    Image(systemName: "plus").font(.system(size: 16)).frame(width: 17, height: 27).contentShape(Rectangle().inset(by: -10))
                }.buttonStyle(.plain).accessibilityLabel(title + "에 할 일 추가").accessibilityIdentifier("native-task-add")
            }.frame(height: 27)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if entries.isEmpty && external.isEmpty {
                        VStack(spacing: 6) {
                            Text("이 날은 일정이 없어요").font(.system(size: 15, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
                            Text("+ 를 눌러 바로 추가할 수 있어요").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                        let upcoming = NativePlannerTask.upcoming(tasks)
                        if !upcoming.isEmpty {
                            Text("다가오는 일정").font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary)
                            ForEach(upcoming) { card($0) }
                        }
                    }
                    ForEach(entries) { card($0) }
                    ForEach(external) { event in
                        Button { openExternalEvent(event) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(event.title).font(.system(size: 15, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                HStack(spacing: 6) {
                                    Image(systemName: "calendar").font(.system(size: 11))
                                    Text(event.calendarTitle).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if !event.allDay, let start = event.start { Text(start.formatted(date: .omitted, time: .shortened)) }
                                }.font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(NativePlannerPalette.tool, in: RoundedRectangle(cornerRadius: 16))
                            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(NativeDesktopTheme.border) }
                        }.buttonStyle(.plain).accessibilityHint("Apple 캘린더에서 열기")
                    }
                }.padding(.bottom, 2)
            }.scrollBounceBehavior(.basedOnSize)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
