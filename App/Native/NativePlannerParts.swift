import SwiftUI

/// The study board's own surfaces (Surface/Paper · Surface/Tool · Glass/패널 in the design file).
/// Text, hairlines and the dark chips come from `NativeDesktopTheme`.
enum NativePlannerPalette {
    static let paper = NativeDesktopTheme.adaptive(0xffffff, 0x181818)
    static let tool = NativeDesktopTheme.adaptive(0xf7f7f7, 0x1f1f1f)
    /// A column or the month grid: glass on the sheet's glass, inside a 7% line.
    static let panel = NativeGlass.panel
    static let panelStroke = Color(uiColor: UIColor { ($0.userInterfaceStyle == .dark ? UIColor.white : .black).withAlphaComponent(0.07) })
    /// The card popover: `Glass/팝업` as it reads over the sheet (the presenter's glass has only the dim behind it).
    static let popover = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255, alpha: 0.96) : UIColor(white: 0.975, alpha: 0.96) })
    /// The day before a deadline and later (#FF3B30 in both appearances).
    static let urgent = Color(red: 1, green: 0x3b / 255, blue: 0x30 / 255)
}

extension NativeCourse {
    /// The colour picked when the course was made. Blue, orange and green are the board's drawn colours;
    /// the others have no drawn counterpart and stay the system's.
    var tint: Color {
        switch color {
        case "red": .red
        case "orange": Color(red: 0xf0 / 255, green: 0x91 / 255, blue: 0x2b / 255)
        case "yellow", "gold": .yellow
        case "green": Color(red: 0x34 / 255, green: 0xa8 / 255, blue: 0x53 / 255)
        case "purple": .purple
        case "pink": .pink
        case "gray": Color(red: 0x6b / 255, green: 0x6b / 255, blue: 0x6b / 255)
        default: Color(red: 0x3b / 255, green: 0x6f / 255, blue: 0xe0 / 255)
        }
    }
}

extension NativePlannerTask {
    static let statuses = ["todo", "in-progress", "done"]
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
    /// From the chip's edge to its content: 14 on the board, 13 in 새 할 일.
    var inset: CGFloat = 14
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let tint { Circle().fill(tint).frame(width: 8, height: 8) }
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if clears && selected { Image(systemName: "xmark").font(.system(size: 10)) }
            }
            // The outlined chip is its hairline larger all round, as drawn.
            .padding(.horizontal, selected ? inset : inset + 1).frame(height: selected ? 34 : 36)
            .foregroundStyle(selected ? NativePlannerPalette.paper : NativeDesktopTheme.text)
            .background(selected ? NativeDesktopTheme.secondary : NativePlannerPalette.paper, in: Capsule())
            .overlay { if !selected { Capsule().strokeBorder(NativeDesktopTheme.border) } }
            .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The mark of a status as drawn: an open ring, the ring half filled, a filled tick.
struct NativePlannerStatusGlyph: View {
    let status: String
    var color = NativeDesktopTheme.text
    var body: some View {
        Group {
            if status == "done" {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15))
            } else {
                Circle().strokeBorder(lineWidth: 1.6).frame(width: 14, height: 14)
                    .background { if status == "in-progress" { Circle().trim(from: 0, to: 0.5).rotation(.degrees(-90)) } }
            }
        }.foregroundStyle(color).frame(width: 18, height: 18).accessibilityHidden(true)
    }
}

/// 상태 as segments on a `Surface/Tool` track; the chosen one is paper, without a shadow.
struct NativePlannerStatusSwitch: View {
    let statuses: [String]
    @Binding var selection: String
    let identifierPrefix: String
    /// The row in 새 할 일: 28 pt segments as wide as their titles, no marks. Otherwise the card popover's:
    /// 34 pt with the status marks, sharing the width.
    var compact = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(statuses, id: \.self) { status in
                let on = selection == status, title = NativePlannerTask.statusTitle(status)
                Button { selection = status } label: {
                    HStack(spacing: 6) {
                        if !compact { NativePlannerStatusGlyph(status: status) }
                        Text(title).font(.system(size: compact ? 13 : 14, weight: on ? .semibold : .regular)).lineLimit(1)
                    }
                    .padding(.horizontal, compact ? 12 : 0).frame(maxWidth: compact ? nil : .infinity).frame(height: compact ? 28 : 34)
                    .background(on ? NativeDesktopTheme.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: compact ? 7 : 8)).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("상태 " + title).accessibilityIdentifier(identifierPrefix + status).accessibilityAddTraits(on ? .isSelected : [])
            }
        }.padding(compact ? 2 : 3).background(NativePlannerPalette.tool, in: RoundedRectangle(cornerRadius: compact ? 9 : 10))
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
                if task.completed { NativePlannerStatusGlyph(status: "done", color: NativeDesktopTheme.muted) }
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
                        Text(badge.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(badge.urgent ? NativePlannerPalette.urgent : NativeDesktopTheme.secondary)
                            .padding(.horizontal, 8).frame(height: 23)
                            .background(badge.urgent ? NativePlannerPalette.urgent.opacity(0.12) : NativePlannerPalette.tool, in: Capsule())
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

/// The popover beside a tapped card: what it is for, when it is due, its reminder, its status, and delete.
struct NativePlannerTaskDetail: View {
    let task: NativePlannerTask
    let course: NativeCourse?
    let setStatus: (String) -> Void
    let delete: () -> Void
    @State private var confirmingDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(task.title).font(.system(size: 20, weight: .bold)).fixedSize(horizontal: false, vertical: true).frame(minHeight: 28)
            if let course {
                row("과목") {
                    Circle().fill(course.tint).frame(width: 8, height: 8)
                    Text(course.name).lineLimit(1)
                }
            }
            if let due = task.dueText() {
                row("마감") { Text(due).foregroundStyle(task.dueBadge()?.urgent == true ? NativePlannerPalette.urgent : NativeDesktopTheme.text) }
                let reminder = NativePlannerReminder.choice(for: task.id)
                if reminder != .off { row("알림") { Text(reminder.title) } }
            }
            NativePlannerStatusSwitch(statuses: NativePlannerTask.statuses, selection: Binding(get: { task.status }, set: { if $0 != task.status { setStatus($0) } }),
                                      identifierPrefix: "native-task-status-")
            // 메모 is not in the drawn popover: it shows only on a task that has one.
            if !task.notes.isEmpty {
                Text(task.notes).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 12)
                    .background(NativePlannerPalette.tool, in: RoundedRectangle(cornerRadius: 14))
            }
            Button { confirmingDelete = true } label: {
                Text("할 일 삭제").font(.system(size: 16, weight: .semibold)).foregroundStyle(NativePlannerPalette.urgent)
                    .frame(maxWidth: .infinity, minHeight: 48).background(NativePlannerPalette.urgent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).accessibilityIdentifier("native-task-delete")
                .bandalConfirm("할 일을 삭제할까요?", isPresented: $confirmingDelete, action: "삭제", destructive: true, identifier: "native-task-delete-confirm", perform: delete)
        }
        // The popover pads 18 all round; the drawn inset is 20 × 18.
        .padding(.horizontal, 2)
    }
    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary).frame(width: 50, alignment: .leading)
            value()
        }.font(.system(size: 15, weight: .medium)).frame(height: 21).accessibilityElement(children: .combine)
    }
}

/// A column's cards once they no longer fit: they scroll, with the drawn 5 pt bar in the gutter beside them
/// (the system's indicator would lie over the cards).
struct NativePlannerScroll<Content: View>: View {
    @ViewBuilder var content: Content
    /// How far down the content is, its height, and the height it is seen through.
    @State private var scroll = (offset: CGFloat(0), content: CGFloat(1), visible: CGFloat(1))
    var body: some View {
        ScrollView { content }.scrollIndicators(.hidden)
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.y + $0.contentInsets.top, $0.contentSize.height, $0.containerSize.height] } action: { _, new in
                scroll = (new[0], max(new[1], 1), new[2])
            }
            .overlay(alignment: .topTrailing) {
                let ratio = scroll.visible / scroll.content, length = max(24, scroll.visible * ratio)
                if ratio < 1 {
                    RoundedRectangle(cornerRadius: 3).fill(NativeDesktopTheme.muted.opacity(0.55)).frame(width: 5, height: length)
                        .offset(y: min(max(0, scroll.offset / max(scroll.content - scroll.visible, 1)), 1) * (scroll.visible - length))
                        .padding(.trailing, 5).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
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
