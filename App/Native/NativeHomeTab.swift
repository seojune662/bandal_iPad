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
    @State private var renaming = false
    @State private var deleting = false
    @State private var showingMenu = false
    @AppStorage(NativeLibraryPresentation.sortKey) private var sort = NativeLibraryPresentation.Sort.name.rawValue

    /// The most recently changed note, PDF or text file of this subject.
    private var recent: NativeMaterial? {
        NativeLibraryIndex.flatten(store.materials).filter { !$0.isDirectory && ($0.mtime ?? 0) > 0 }.max { ($0.mtime ?? 0) < ($1.mtime ?? 0) }
    }
    private var subjects: [NativeCourse] { store.courses.filter { $0.workspaceKind != "study-space" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let recent, let courseID = store.selectedCourseID {
                title("이어서 쓰기")
                // Not a Button: a long press opens the card's menu and must not also open the note when the finger lifts.
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) { ForEach([46, 36, 50, 26], id: \.self) { RoundedRectangle(cornerRadius: 2).fill(NativeDesktopTheme.border).frame(width: $0, height: 4) } }
                        .padding(10).frame(width: 72, height: 92, alignment: .topLeading).background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        if renaming {
                            BandalInlineEditor(text: recent.name, isEditing: $renaming, font: NativeDesktopTheme.font(18, weight: .semibold), identifier: "native-home-rename") { name in
                                run { try await store.rename(recent, to: name) }
                            }
                        } else { Text((recent.name as NSString).deletingPathExtension).font(NativeDesktopTheme.font(18, weight: .semibold)).lineLimit(1) }
                        Text(courseTitle + " · " + Self.ago(recent.mtime ?? 0)).font(NativeDesktopTheme.font(14)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 15)).foregroundStyle(NativeDesktopTheme.muted)
                }.padding(14)
                    // Lifted while its menu is open (Figma 129:3094): paper white, shadow 0/10/30 at 14%.
                    .background(showingMenu ? NativeDesktopTheme.bgApp : NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(showingMenu ? 0.14 : 0), radius: 15, y: 10)
                    .contentShape(Rectangle())
                    .onTapGesture { if !renaming { onOpen(recent.document(in: courseID)) } }
                    .onLongPressGesture(minimumDuration: 0.4) { showingMenu = true }
                    .accessibilityElement(children: renaming ? .contain : .combine).accessibilityAddTraits(.isButton).accessibilityIdentifier("native-home-continue")
                    .accessibilityAction(named: "메뉴") { showingMenu = true }
                    .nativeLongPressMenu(isPresented: $showingMenu, radius: 16, tiles: [
                        .init(title: "이름 변경", symbol: "pencil") { renaming = true },
                        .init(title: "공유", symbol: "square.and.arrow.up") { run { _ = try await store.invoke("materials:share", ["courseId": courseID, "relPath": recent.relPath]) } },
                        .init(title: "삭제", symbol: "trash", kind: .destructive) { deleting = true }
                    ], groups: NativeLongPressItem.materialGroups(sort: $sort))
                    .modifier(NativeDeleteConfirm(name: recent.name, directory: false, isPresented: $deleting) { run { try await store.delete(recent) } })
            }
            title("과목")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(subjects) { course in
                    Button { onSelectCourse(course.id) } label: { tile(course.name, "folder", height: 85, icon: NativeDesktopTheme.accent).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 14)) }
                        .buttonStyle(.plain).accessibilityIdentifier("native-home-course-" + course.id)
                }
                Button(action: onNewCourse) {
                    tile("새 과목", "plus", height: 88, icon: NativeDesktopTheme.secondary).foregroundStyle(NativeDesktopTheme.secondary)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(NativeDesktopTheme.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                }.buttonStyle(.plain).accessibilityIdentifier("native-home-new-course")
            }
            HStack(spacing: 18) {
                Button(action: onNewNote) {
                    HStack(spacing: 8) { Image(systemName: "square.and.pencil").font(.system(size: 18)); Text("새 노트").font(NativeDesktopTheme.font(17, weight: .semibold)) }
                        .foregroundStyle(NativeDesktopTheme.onAccent)
                        .padding(.horizontal, 26).frame(height: 49).background(NativeDesktopTheme.accent, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 8).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("새 노트 쓰기").accessibilityIdentifier("native-home-new-note")
                Button("PDF · 폴더에서 추가") { importing = true }.buttonStyle(.plain).font(NativeDesktopTheme.font(15, weight: .medium)).foregroundStyle(NativeDesktopTheme.accent).frame(minHeight: 44)
                    .accessibilityIdentifier("native-home-import")
            }.frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 560).foregroundStyle(NativeDesktopTheme.text)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .folder, .plainText, .image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { do { try await store.importFiles(urls) } catch { store.errorMessage = error.localizedDescription } }
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await store.flushDocuments(); try await action() } catch { store.errorMessage = error.localizedDescription } }
    }
    private func title(_ text: LocalizedStringKey) -> some View {
        Text(text).font(NativeDesktopTheme.font(15, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityAddTraits(.isHeader)
    }
    private func tile(_ title: String, _ symbol: String, height: CGFloat, icon: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(icon).frame(height: 26)
            Text(title).font(NativeDesktopTheme.font(14, weight: .medium)).lineLimit(1)
        }.padding(16).frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading).contentShape(Rectangle())
    }
    static func ago(_ mtime: Double) -> String {
        // Repository mtimes are Unix milliseconds; accept seconds for legacy data.
        let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: "ko_KR")
        return formatter.localizedString(for: Date(timeIntervalSince1970: mtime > 100_000_000_000 ? mtime / 1000 : mtime), relativeTo: Date())
    }
}
