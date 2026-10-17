import SwiftUI
import UniformTypeIdentifiers

enum NativeShortcutPreference {
    static func canonical(_ value: String) throws -> String {
        let tokens = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let key = tokens.last, key.hasPrefix("f"), Int(key.dropFirst()) != nil {
            throw DesktopRuntimeError("이 기기의 전역 단축키에는 F 기능 키를 지정할 수 없습니다. 문자·숫자·방향 키를 사용해 주세요.")
        }
        guard let key = tokens.last, !key.isEmpty, tokens.contains("mod"), Set(tokens).count == tokens.count,
              tokens.dropLast().allSatisfy({ ["mod", "alt", "shift"].contains($0) }),
              key.count == 1 || ["escape", "enter", "tab", "space", "home", "end", "pageup", "pagedown", "backspace", "delete", "arrowleft", "arrowright", "arrowup", "arrowdown"].contains(key),
              tokens.contains("alt") || !["c", "v", "x", "z", "a"].contains(key) else {
            throw DesktopRuntimeError("⌘를 포함한 키 조합을 입력하세요. 예: mod+shift+b. 복사·붙여넣기·실행 취소 같은 편집 키는 예약되어 있습니다.")
        }
        return (["mod", "alt", "shift"].filter { tokens.contains($0) } + [key]).joined(separator: "+")
    }
    static func validateImport(_ data: Data) throws -> [String: Any] {
        guard data.count <= 128 * 1024, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DesktopRuntimeError("단축키 JSON 파일을 확인하세요.") }
        let bindings = value["keybindings"] as? [String: Any] ?? value
        var result: [String: Any] = [:]
        for (id, raw) in bindings {
            // Preserve desktop actions not exposed in this platform's editor.
            guard id.count <= 100 else { throw DesktopRuntimeError("단축키 동작 이름이 너무 깁니다.") }
            if raw is NSNull { result[id] = NSNull() }
            else if let chord = raw as? String { result[id] = try canonical(chord) }
            else { throw DesktopRuntimeError("단축키 값은 키 조합 또는 null이어야 합니다.") }
        }
        return result
    }
    static func display(_ value: String) -> String { value.replacingOccurrences(of: "mod+", with: "⌘").replacingOccurrences(of: "alt+", with: "⌥").replacingOccurrences(of: "shift+", with: "⇧").uppercased() }
}

struct NativeSettingsShortcutsPanel: View {
    let settings: [String: Any]
    let save: @MainActor ([String: Any]) async throws -> Void
    @State private var query = ""
    @State private var editing: NativeBrowserShortcuts.Spec?
    @State private var chord = ""
    @State private var busy = false
    @State private var error: String?
    @State private var importing = false
    @State private var exporting = false
    @State private var document = NativeShortcutDocument(data: Data())
    @State private var resetting = false
    private var bindings: [String: Any] { settings["keybindings"] as? [String: Any] ?? [:] }
    private var matching: [NativeBrowserShortcuts.Spec] { NativeBrowserShortcuts.specs.filter { query.isEmpty || $0.label.localizedStandardContains(query) || $0.id.localizedStandardContains(query) } }
    var body: some View {
        VStack(spacing: 24) {
            if let error { NativeToolError(message: error) }
            NativeSettingsCard(title: "웹뷰 단축키 우선권", description: "외장 키보드에서 반달과 사이트가 같은 키를 사용할 때의 우선순위입니다. 탭 열기·닫기는 반달에서 처리합니다.") {
                Picker("우선권", selection: Binding(get: { settings["shortcutPriority"] as? String ?? "bandal" }, set: { persist(["shortcutPriority": $0]) })) { Text("반달 우선").tag("bandal"); Text("사이트 우선").tag("site") }
            }
            NativeSettingsCard(title: "키 조합", description: "이 기기에서 동작하는 탭·브라우저 명령입니다. ⌘는 mod, ⌥는 alt, ⇧는 shift로 입력합니다.") {
                TextField("단축키 검색", text: $query).nativeToolField()
                ForEach(matching) { spec in
                    HStack {
                        Text(spec.label); Spacer()
                        Button(bindings[spec.id] is NSNull ? "지정 안 함" : NativeShortcutPreference.display(bindings[spec.id] as? String ?? spec.chord)) { chord = bindings[spec.id] as? String ?? spec.chord; editing = spec }
                            .font(NativeDesktopTheme.font(12, design: .monospaced)).accessibilityIdentifier("native-settings-shortcut-" + spec.id)
                    }
                }
                HStack {
                    Button("JSON 가져오기") { importing = true }
                    Button("JSON 내보내기") { do { document = NativeShortcutDocument(data: try JSONSerialization.data(withJSONObject: ["keybindings": bindings], options: [.prettyPrinted, .sortedKeys])); exporting = true } catch { self.error = error.localizedDescription } }
                    Spacer(); Button("기본값 복원", role: .destructive) { resetting = true }
                }
            }
        }.disabled(busy)
            .sheet(item: $editing) { spec in
                NavigationStack {
                    Form {
                        Section(spec.label) { TextField("mod+shift+b", text: $chord).textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced()); Text("이미 사용 중인 키 조합을 지정하면 기존 동작은 해당 키에서 해제됩니다.").font(.caption) }
                        Button("저장") { update(spec, raw: chord) }
                        Button("지정 해제", role: .destructive) { update(spec, raw: nil) }
                        Button("이 동작의 기본값") { var next = bindings; next.removeValue(forKey: spec.id); editing = nil; persist(["keybindings": next]) }
                    }.navigationTitle("단축키 변경").toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { editing = nil } } }
                }.presentationDetents([.medium])
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; let value = try NativeShortcutPreference.validateImport(Data(contentsOf: url)); persist(["keybindings": value]) }
                catch { self.error = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "bandal-keybindings") { result in if case .failure(let error) = result { self.error = error.localizedDescription } }
            .confirmationDialog("모든 단축키를 기본값으로 되돌릴까요?", isPresented: $resetting) { Button("기본값 복원", role: .destructive) { persist(["keybindings": [String: Any]()]) } }
    }
    private func update(_ spec: NativeBrowserShortcuts.Spec, raw: String?) {
        do {
            var next = bindings
            if let raw {
                let value = try NativeShortcutPreference.canonical(raw)
                for other in NativeBrowserShortcuts.specs where other.id != spec.id && !(next[other.id] is NSNull) {
                    if (try? NativeShortcutPreference.canonical(next[other.id] as? String ?? other.chord)) == value { next[other.id] = NSNull() }
                }
                next[spec.id] = value
            } else { next[spec.id] = NSNull() }
            editing = nil; persist(["keybindings": next])
        } catch { editing = nil; self.error = error.localizedDescription }
    }
    private func persist(_ patch: [String: Any]) { guard !busy else { return }; busy = true; error = nil; Task { defer { busy = false }; do { try await save(patch) } catch { self.error = error.localizedDescription } } }
}
private struct NativeShortcutDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
