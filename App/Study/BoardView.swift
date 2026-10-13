import SwiftUI
import EventKit
import UserNotifications

struct BoardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var title = ""
    @State private var withDate = false
    @State private var due = Date().addingTimeInterval(86400)
    @State private var showCompleted = false
    private var items: [StudyTask] { model.tasks.filter { $0.courseID == model.courseID && ($0.completed == showCompleted) }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { VStack(alignment: .leading, spacing: 4) { Text("한 걸음씩, 차근차근").font(.title2.bold()); Text("과제와 할 일을 한곳에서 관리하세요.").font(.subheadline).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "checklist").font(.largeTitle).foregroundStyle(BandalTheme.accent) }
                VStack(alignment: .leading, spacing: 12) {
                    TextField("새로운 할 일", text: $title).textFieldStyle(.roundedBorder).onSubmit(add)
                    Toggle("마감일과 알림", isOn: $withDate).font(.subheadline)
                    if withDate { DatePicker("마감", selection: $due).font(.subheadline) }
                    Button(action: add) { Label("할 일 추가", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 36) }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }.padding(16).background(BandalTheme.background, in: RoundedRectangle(cornerRadius: 14))
                Picker("상태", selection: $showCompleted) { Text("진행 중").tag(false); Text("완료").tag(true) }.pickerStyle(.segmented)
                if items.isEmpty { ContentUnavailableView(showCompleted ? "완료한 일이 여기에 모여요" : "할 일을 정리해 보세요", systemImage: "checkmark.circle", description: Text("작은 목표부터 시작해도 좋아요.")) }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Button { var updated = item; updated.completed.toggle(); model.saveTask(updated); if updated.completed { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [item.id]) } } label: { Image(systemName: item.completed ? "checkmark.circle.fill" : "circle").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel(item.completed ? "완료 취소" : "완료")
                        VStack(alignment: .leading, spacing: 6) { Text(item.title).strikethrough(item.completed); if let due = item.due { Text(due, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(due < Date() && !item.completed ? .red : .secondary) } }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                        Menu {
                            if item.due != nil { Button("Apple 캘린더에 추가", systemImage: "calendar.badge.plus") { Task { do { var updated = item; updated.calendarID = try await CalendarService.shared.add(item); model.saveTask(updated) } catch { model.error = error.localizedDescription } } } }
                            Button("삭제", role: .destructive) { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [item.id]); model.tasks.removeAll { $0.id == item.id }; model.deleteRecord("task:\(item.id)") }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    }.padding(8).background(BandalTheme.background, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(24)
        }
    }
    private func add() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { return }
        let task = StudyTask(courseID: model.courseID, title: value, due: withDate ? due : nil); model.saveTask(task); title = ""
        if withDate { Task { await CalendarService.scheduleReminder(task) } }
    }
}

@MainActor
final class CalendarService {
    static let shared = CalendarService()
    let store = EKEventStore()
    func authorize() async throws {
        guard try await store.requestFullAccessToEvents() else { throw CalendarError.denied }
    }
    func events(on date: Date) async throws -> [EKEvent] {
        try await authorize()
        let start = Calendar.current.startOfDay(for: date)
        return store.events(matching: store.predicateForEvents(withStart: start, end: Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400), calendars: nil)).sorted { $0.startDate < $1.startDate }
    }
    func add(_ task: StudyTask) async throws -> String {
        try await authorize()
        guard let due = task.due, let calendar = store.defaultCalendarForNewEvents else { throw CalendarError.noCalendar }
        let event = task.calendarID.flatMap { store.event(withIdentifier: $0) } ?? EKEvent(eventStore: store)
        event.title = task.title; event.startDate = due; event.endDate = due.addingTimeInterval(1800); event.calendar = calendar
        event.notes = "반달 과제 · \(task.id)"
        try store.save(event, span: .thisEvent); return event.eventIdentifier
    }
    static func scheduleReminder(_ task: StudyTask) async {
        guard let due = task.due, due > Date() else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
        let content = UNMutableNotificationContent(); content.title = "반달 · 과제 알림"; content.body = task.title; content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: task.id, content: content, trigger: trigger))
    }
    enum CalendarError: LocalizedError {
        case denied, noCalendar
        var errorDescription: String? { self == .denied ? "설정에서 반달의 캘린더 접근을 허용해 주세요." : "일정을 추가할 기본 캘린더가 없습니다." }
    }
}

struct CalendarWorkspaceView: View {
    @EnvironmentObject var model: AppModel
    @State private var date = Date()
    @State private var events: [EKEvent] = []
    @State private var connected = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("학업 캘린더").font(.title2.bold())
                DatePicker("날짜", selection: $date, displayedComponents: .date).datePickerStyle(.graphical)
                Text("선택한 날의 과제").font(.headline)
                let tasks = model.tasks.filter { $0.courseID == model.courseID && $0.due.map { Calendar.current.isDate($0, inSameDayAs: date) } == true }
                if tasks.isEmpty { Text("예정된 과제가 없어요.").foregroundStyle(.secondary) }
                ForEach(tasks) { task in Label(task.title, systemImage: task.completed ? "checkmark.circle.fill" : "circle").padding(.vertical, 8) }
                Divider()
                if connected {
                    Text("Apple 캘린더").font(.headline)
                    ForEach(events, id: \.eventIdentifier) { event in HStack { Text(event.startDate, style: .time).font(.caption).foregroundStyle(.secondary); Text(event.title) }.padding(.vertical, 8) }
                } else { Button("Apple 캘린더 연결") { connected = true; refresh() }.buttonStyle(.bordered) }
            }.padding(24)
        }.onChange(of: date) { _, _ in if connected { refresh() } }
    }
    private func refresh() { Task { do { events = try await CalendarService.shared.events(on: date) } catch { model.error = error.localizedDescription; connected = false } } }
}
