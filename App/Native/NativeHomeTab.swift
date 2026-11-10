import SwiftUI
import UniformTypeIdentifiers

/// The workspace with no tab open: pick up the last note, switch subject, or start a note.
struct NativeHomeTab: View {
    var store: NativeWorkspaceStore
    let courseTitle: String
    let onOpen: (NativeDocumentReference) -> Void
    let onSelectCourse: (String) -> Void
    let onNewNote: () -> Void
    let onNewCourse: () -> Void
    static let newCourse = Notification.Name("native.home.newCourse")
    @State private var importing = false

    /// The most recently changed note, PDF or text file of this subject.
    private var recent: NativeMaterial? {
        NativeLibraryIndex.flatten(store.materials).filter { !$0.isDirectory && ($0.mtime ?? 0) > 0 }.max { ($0.mtime ?? 0) < ($1.mtime ?? 0) }
    }
    private var subjects: [NativeCourse] { store.courses.filter { $0.workspaceKind != "study-space" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let recent, let courseID = store.selectedCourseID {
                section("이어서 쓰기") {
                    Button { onOpen(recent.document(in: courseID)) } label: {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) { ForEach([36, 28, 40, 22], id: \.self) { Capsule().fill(NativeDesktopTheme.border).frame(width: $0, height: 3) } }
                                .frame(width: 60, height: 76).background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text((recent.name as NSString).deletingPathExtension).font(NativeDesktopTheme.font(16, weight: .semibold)).lineLimit(1)
                                Text(courseTitle + " · " + Self.ago(recent.mtime ?? 0)).font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.muted)
                        }.padding(12).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 16)).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("native-home-continue")
                }
            }
            section("과목") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(subjects) { course in
                        Button { onSelectCourse(course.id) } label: { tile(course.name, "folder").background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 14)) }
                            .buttonStyle(.plain).accessibilityIdentifier("native-home-course-" + course.id)
                    }
                    Button(action: onNewCourse) {
                        tile("새 과목", "plus").foregroundStyle(NativeDesktopTheme.muted)
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(NativeDesktopTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    }.buttonStyle(.plain).accessibilityIdentifier("native-home-new-course")
                }
            }
            HStack(spacing: 18) {
                Button(action: onNewNote) {
                    Label("새 노트", systemImage: "square.and.pencil").font(NativeDesktopTheme.font(15, weight: .semibold)).foregroundStyle(NativeDesktopTheme.onAccent)
                        .padding(.horizontal, 22).frame(height: 48).background(NativeDesktopTheme.accent, in: Capsule())
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("새 노트 쓰기").accessibilityIdentifier("native-home-new-note")
                Button("PDF · 폴더에서 추가") { importing = true }.buttonStyle(.plain).font(NativeDesktopTheme.font(14)).frame(minHeight: 44)
                    .accessibilityIdentifier("native-home-import")
            }.frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 560).foregroundStyle(NativeDesktopTheme.text)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .folder, .plainText, .image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { do { try await store.importFiles(urls) } catch { store.errorMessage = error.localizedDescription } }
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(NativeDesktopTheme.font(13)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityAddTraits(.isHeader)
            content()
        }
    }
    private func tile(_ title: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) { Image(systemName: symbol).font(.system(size: 20)); Text(title).font(NativeDesktopTheme.font(13, weight: .medium)).lineLimit(1) }
            .padding(14).frame(maxWidth: .infinity, minHeight: 84, alignment: .leading).contentShape(Rectangle())
    }
    static func ago(_ mtime: Double) -> String {
        // Repository mtimes are Unix milliseconds; accept seconds for legacy data.
        let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: "ko_KR")
        return formatter.localizedString(for: Date(timeIntervalSince1970: mtime > 100_000_000_000 ? mtime / 1000 : mtime), relativeTo: Date())
    }
}
