import SwiftUI

enum NativePaper: String, CaseIterable, Identifiable {
    case blank, lines, grid, dots
    var id: String { rawValue }
    var title: String {
        switch self { case .blank: return "빈 종이"; case .lines: return "줄"; case .grid: return "모눈"; case .dots: return "점" }
    }
}

struct NativeNewNoteSheet: View {
    @ObservedObject var store: NativeWorkspaceStore
    var parentPath: String = ""
    var onCreated: (NativeDocumentReference) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var paper: NativePaper = .lines
    @State private var landscape = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("제목") {
                    TextField("새 노트", text: $title)
                        .accessibilityIdentifier("native-new-note-title")
                        .submitLabel(.done)
                        .onSubmit(create)
                }
                Section("종이") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 16)], spacing: 16) {
                        ForEach(NativePaper.allCases) { option in
                            Button { paper = option } label: {
                                VStack(spacing: 8) {
                                    NativePaperPreview(paper: option)
                                        .frame(height: 112)
                                        .overlay(alignment: .topTrailing) {
                                            if paper == option {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, Color.accentColor)
                                                    .padding(8)
                                            }
                                        }
                                    Text(option.title).font(.subheadline.weight(paper == option ? .semibold : .regular))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.title)
                            .accessibilityAddTraits(paper == option ? .isSelected : [])
                        }
                    }.padding(.vertical, 8)
                }
                Section("방향") {
                    Picker("방향", selection: $landscape) {
                        Label("세로", systemImage: "rectangle.portrait").tag(false)
                        Label("가로", systemImage: "rectangle").tag(true)
                    }.pickerStyle(.segmented)
                }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("native-creation-error") } }
            }
            .disabled(busy)
            .navigationTitle("새 노트")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: create) {
                        if busy { ProgressView() } else { Text("만들기").fontWeight(.semibold) }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("native-new-note-create")
                }
            }
            .interactiveDismissDisabled(busy)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func create() {
        guard !busy else { return }
        busy = true; error = nil
        Task { @MainActor in
            do {
                let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let document = try await store.createNote(title: name.isEmpty ? "새 노트" : name, paper: paper.rawValue, orientation: landscape ? "landscape" : "portrait",parentPath:parentPath)
                onCreated(document)
                dismiss()
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}

private struct NativePaperPreview: View {
    let paper: NativePaper
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 10), with: .color(Color(uiColor: .secondarySystemGroupedBackground)))
            var path = Path()
            let step: CGFloat = 12
            if paper == .dots {
                for x in stride(from: step, to: size.width, by: step) {
                    for y in stride(from: step, to: size.height, by: step) {
                        path.addEllipse(in: CGRect(x: x, y: y, width: 1.6, height: 1.6))
                    }
                }
                context.fill(path, with: .color(.secondary.opacity(0.4)))
            } else if paper != .blank {
                for y in stride(from: step, to: size.height, by: step) {
                    path.move(to: CGPoint(x: 8, y: y)); path.addLine(to: CGPoint(x: size.width - 8, y: y))
                }
                if paper == .grid {
                    for x in stride(from: step, to: size.width, by: step) {
                        path.move(to: CGPoint(x: x, y: 8)); path.addLine(to: CGPoint(x: x, y: size.height - 8))
                    }
                }
                context.stroke(path, with: .color(.secondary.opacity(0.3)), lineWidth: 0.6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// A sheet owns its asynchronous operation until completion; an older request
/// cannot dismiss a newly presented sheet or lose a validation error.
struct NativeNameSheet: View {
    let title: String
    let prompt: String
    let actionTitle: String
    let defaultValue: String?
    let action: @MainActor (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(title: String, prompt: String, initialValue: String = "", actionTitle: String = "만들기", defaultValue: String? = nil, action: @escaping @MainActor (String) async throws -> Void) {
        self.title = title; self.prompt = prompt; self.actionTitle = actionTitle; self.action = action
        self.defaultValue = defaultValue
        _name = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(prompt, text: $name).focused($focused).submitLabel(.done)
                    .onSubmit(submit).disabled(busy).accessibilityIdentifier("native-name-input")
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if busy { ProgressView() } else { Text(actionTitle).fontWeight(.semibold) }
                    }.disabled(busy || (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && defaultValue == nil))
                }
            }
            .interactiveDismissDisabled(busy)
            .task { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = typed.isEmpty ? defaultValue ?? "" : typed
        guard !busy, !value.isEmpty else { return }
        busy = true; error = nil
        Task { @MainActor in
            do { try await action(value); dismiss() }
            catch { self.error = error.localizedDescription; busy = false }
        }
    }
}
