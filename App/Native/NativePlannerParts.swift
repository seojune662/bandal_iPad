import SwiftUI

/// The study board's own surfaces (Surface/Paper · Surface/Tool · Glass/패널 · Glass/시트 in the design file).
/// Text, hairlines and the dark chips come from `NativeDesktopTheme`.
enum NativePlannerPalette {
    static let paper = NativeDesktopTheme.adaptive(0xffffff, 0x181818)
    static let tool = NativeDesktopTheme.adaptive(0xf7f7f7, 0x1f1f1f)
    static let panel = NativeDesktopTheme.adaptive(0xf4f4f6, 0x1f1f21)
    static let sheet = NativeDesktopTheme.adaptive(0xfafafb, 0x1c1c1e)
}

extension NativeCourse {
    /// The colour picked when the course was made.
    var tint: Color {
        switch color { case "red": .red; case "orange": .orange; case "yellow", "gold": .yellow; case "green": .green; case "purple": .purple; case "pink": .pink; case "gray": .gray; default: .blue }
    }
}

extension NativePlannerTask {
    static let statuses = ["todo", "in-progress", "done"]
    static let statusSymbols = ["todo": "circle", "in-progress": "circle.righthalf.filled", "done": "checkmark.circle.fill"]
    static func statusTitle(_ status: String) -> String { status == "todo" ? "할 일" : status == "in-progress" ? "진행 중" : "완료" }
    /// "11월 11일 (수) 오후 11:59 · D-1": the time only for a timed task, the countdown only while unfinished.
    func dueText(now: Date = Date()) -> String? {
        guard let dueDate else { return nil }
        let day = "\(dueDate.formatted(.dateTime.month().day())) (\(dueDate.formatted(.dateTime.weekday(.abbreviated))))"
        let time = allDay ? "" : " " + dueDate.formatted(date: .omitted, time: .shortened)
        return day + time + (dueBadge(now: now).map { " · " + $0.label } ?? "")
    }
}

/// A course filter or choice: a capsule with the course's colour dot, dark while chosen.
struct NativePlannerChip: View {
    let title: String
    var tint: Color?
    let selected: Bool
    /// The chosen chip carries an × that clears it (the board's filter row).
    var clears = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let tint { Circle().fill(tint).frame(width: 8, height: 8) }
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if clears && selected { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
            }
            // The outlined chip is its hairline larger all round, as drawn.
            .padding(.horizontal, selected ? 14 : 15).frame(height: selected ? 34 : 36)
            .foregroundStyle(selected ? NativePlannerPalette.paper : NativeDesktopTheme.text)
            .background(selected ? NativeDesktopTheme.secondary : NativePlannerPalette.paper, in: Capsule())
            .overlay { if !selected { Capsule().strokeBorder(NativeDesktopTheme.border) } }
            .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One task on the board and in the calendar's day panel: title, course and the days left.
struct NativePlannerCard: View {
    let task: NativePlannerTask
    let course: NativeCourse?
    /// Its popover is open.
    var selected = false
    var body: some View {
        let badge = task.dueBadge()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if task.completed { Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(NativeDesktopTheme.muted) }
                Text(task.title).font(.system(size: 15, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    .foregroundStyle(task.completed ? NativeDesktopTheme.muted : NativeDesktopTheme.text)
            }.frame(minHeight: 21)
            if course != nil || badge != nil {
                HStack(spacing: 6) {
                    if let course {
                        Circle().fill(course.tint).frame(width: 8, height: 8)
                        Text(course.name).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let badge {
                        Text(badge.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(badge.urgent ? Color.red : NativeDesktopTheme.secondary)
                            .padding(.horizontal, 8).frame(height: 23)
                            .background(badge.urgent ? Color.red.opacity(0.12) : NativePlannerPalette.tool, in: Capsule())
                    }
                }.frame(minHeight: 18)
            }
        }
        // 14 × 12 inside a 1 pt hairline, as drawn: 80 pt with a countdown, 75 without.
        .padding(.horizontal, 15).padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading)
        .background(NativePlannerPalette.paper, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? NativeDesktopTheme.muted : NativeDesktopTheme.border, lineWidth: selected ? 1.5 : 1) }
        .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// The popover beside a tapped card: what it is for, when it is due, its status, and delete.
struct NativePlannerTaskDetail: View {
    let task: NativePlannerTask
    let course: NativeCourse?
    let setStatus: (String) -> Void
    let delete: () -> Void
    @State private var confirmingDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(task.title).font(.system(size: 20, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            if let course {
                row("과목") {
                    Circle().fill(course.tint).frame(width: 8, height: 8)
                    Text(course.name).lineLimit(1)
                }
            }
            if let due = task.dueText() {
                row("마감") { Text(due).foregroundStyle(task.dueBadge()?.urgent == true ? Color.red : NativeDesktopTheme.text) }
            }
            BandalSegmented(options: NativePlannerTask.statuses.map { ($0, NativePlannerTask.statusTitle($0)) },
                            selection: Binding(get: { task.status }, set: { if $0 != task.status { setStatus($0) } }), identifierPrefix: "native-task-status-",
                            symbols: NativePlannerTask.statusSymbols, large: true, fills: true, spoken: "상태")
            if !task.notes.isEmpty {
                Text(task.notes).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 12)
                    .background(NativePlannerPalette.tool, in: RoundedRectangle(cornerRadius: 14))
            }
            Button { confirmingDelete = true } label: {
                Text("할 일 삭제").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, minHeight: 48).background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).accessibilityIdentifier("native-task-delete")
                .bandalConfirm("할 일을 삭제할까요?", isPresented: $confirmingDelete, action: "삭제", destructive: true, identifier: "native-task-delete-confirm", perform: delete)
        }
        // The popover pads 12; the design's inset is 20 × 18.
        .padding(.horizontal, 8).padding(.vertical, 6)
    }
    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary).frame(width: 50, alignment: .leading)
            value()
        }.font(.system(size: 15, weight: .medium)).accessibilityElement(children: .combine)
    }
}

/// Sections stacked in a fixed height (the board in portrait). While each fits an equal share they are equal.
/// Spare room goes to the shortest first; when there is too little, the tallest give way first and scroll inside.
struct NativePlannerSectionStack: Layout {
    var spacing: CGFloat = 14
    static func heights(ideal: [CGFloat], available: CGFloat) -> [CGFloat] {
        let spare = ideal.reduce(0, +) <= available
        var result = ideal, remaining = available, open = Array(ideal.indices)
        while !open.isEmpty {
            // Whoever is already on the right side of an even split keeps its own height; the rest split what is left.
            let share = remaining / CGFloat(open.count), settled = open.filter { spare ? ideal[$0] >= share : ideal[$0] <= share }
            if settled.isEmpty { open.forEach { result[$0] = share }; break }
            settled.forEach { remaining -= ideal[$0] }
            open.removeAll(where: settled.contains)
        }
        return result
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { proposal.replacingUnspecifiedDimensions() }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = subviews.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height }
        let heights = Self.heights(ideal: ideal, available: max(0, bounds.height - spacing * CGFloat(max(subviews.count - 1, 0))))
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights) {
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }
}
