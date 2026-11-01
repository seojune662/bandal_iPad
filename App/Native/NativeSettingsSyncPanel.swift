import SwiftUI
import UIKit

/// Settings › 동기화 (design §4.1–4.5). Independent of the Bandal login and of any subscription,
/// so nothing here mentions either. Choosing iCloud or Google Drive reads the root first and asks
/// only when it already holds data (the connection sheet); Drive asks for a Google account first.
struct NativeSettingsSyncPanel: View {
    @ObservedObject var store: NativeWorkspaceStore
    @State private var status: [String: Any] = [:]
    @State private var deviceName = ""
    @State private var preview: [String: Any]?
    @State private var startConfirmation = false
    @State private var offConfirmation = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?

    private var provider: String { status["provider"] as? String ?? "off" }
    private var on: Bool { CloudSyncService.kinds.contains(provider) }
    private var phase: String { status["phase"] as? String ?? "off" }
    private var reason: String? { phase == "paused" ? status["reason"] as? String : nil }
    /// The provider being shown: the one on, or the one a preview is for.
    private var shown: String { preview?["provider"] as? String ?? provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let error { NativeToolError(message: error) }
            if let notice { Label(notice, systemImage: "checkmark.circle").font(NativeDesktopTheme.font(13)).foregroundStyle(.green) }
            NativeSettingsCard(title: "동기화", description: "다른 기기의 과목과 자료를 맞춥니다. iCloud는 같은 Apple ID, Google Drive는 같은 Google 계정을 쓰는 기기끼리입니다.") {
                Picker("동기화", selection: Binding(get: { on ? provider : "off" }, set: { $0 == "off" ? (offConfirmation = true) : turnOn($0) })) {
                    Text("끔").tag("off")
                    Text("iCloud").tag("icloud")
                    Text("Google Drive").tag("drive")
                }.pickerStyle(.segmented).frame(maxWidth: 400).accessibilityIdentifier("native-sync-provider")
                if on { state }
                if shown == "icloud", preview?["available"] as? Bool == false || reason == "signed-out" { signedOut }
                if provider == "drive" && (reason == "drive-signed-out" || status["message"] as? String == GoogleDriveAuth.signedOut.localizedDescription)
                    || error == GoogleDriveAuth.signedOut.localizedDescription {
                    Button("Google에 다시 연결") { run { status = try await invoke("cloudSync:signInDrive") } }
                }
                if let count = preview?["downloading"] as? Int {
                    Text("\(CloudSyncService.name(shown))에서 반달 폴더를 내려받는 중이에요(\(count)개). 잠시 뒤 다시 켜 주세요.").font(.caption).foregroundStyle(NativeDesktopTheme.secondary)
                }
                if preview?["blocked"] != nil { Text("새 버전의 반달이 만든 폴더예요. 앱을 업데이트한 뒤 켜 주세요.").font(.caption).foregroundStyle(.orange) }
            }
            NativeSettingsCard(title: "이 기기 이름", description: "충돌 사본 이름에 쓰입니다.") {
                HStack {
                    TextField("iPad", text: $deviceName).textFieldStyle(.roundedBorder).frame(maxWidth: 280).accessibilityIdentifier("native-sync-device-name")
                    Button("저장") { run { status = try await invoke("cloudSync:setDeviceName", ["name": deviceName]); notice = "기기 이름을 저장했어요." } }
                        .disabled(deviceName.trimmingCharacters(in: .whitespaces).isEmpty || deviceName == status["deviceName"] as? String)
                }
            }
            NativeSettingsCard(title: "동기화되는 것") {
                Text("과목, PDF, 필기, 텍스트 노트")
                Text("동기화되지 않는 것: 텍스트 하이라이트, 화이트보드, 그 밖의 파일, 연결 폴더 과목").foregroundStyle(NativeDesktopTheme.secondary)
                Text("동기화 중인 문서는 페이지 순서를 바꾸거나 지울 수 없어요. 끝에 페이지를 덧붙이는 것은 됩니다.").foregroundStyle(NativeDesktopTheme.secondary)
            }.font(NativeDesktopTheme.font(13))
            if status["previousProfile"] as? Bool == true {
                NativeSettingsCard(title: "이전 자료", description: "클라우드 자료를 가져오기 전에 이 iPad에 있던 자료로 돌아갑니다. 동기화는 꺼집니다.") {
                    Button("이전 자료로 돌아가기") { run { _ = try await invoke("cloudSync:returnToPrevious") } }
                }
            }
        }
        .disabled(busy)
        .task { await load() }
        .onReceive(store.events) { event in
            guard event.channel == "runtime:cloudSyncChanged", let value = event.payload as? [String: Any] else { return }
            status = status.filter { ["provider", "deviceName", "previousProfile", "lastSuccessAt", "driveEmail"].contains($0.key) }.merging(value) { $1 }
        }
        .confirmationDialog(startMessage, isPresented: $startConfirmation, titleVisibility: .visible) {
            Button("올리기") { connect(["mode": "start"]) }
        }
        .confirmationDialog(offMessage, isPresented: $offConfirmation, titleVisibility: .visible) {
            Button("끄기", role: .destructive) { run { status = try await invoke("cloudSync:disconnect"); preview = nil } }
        }
        .sheet(isPresented: Binding(get: { preview?["sameName"] != nil && preview?["empty"] as? Bool == false }, set: { if !$0 { preview = nil } })) {
            if let preview { NativeSyncConnectSheet(preview: preview, connect: connect) }
        }
    }

    @ViewBuilder private var state: some View {
        HStack(spacing: 12) {
            Text(phaseText).contextMenu { if let absolute { Text(absolute) } }.accessibilityIdentifier("native-sync-status")
            Spacer()
            Button("지금 동기화", systemImage: "arrow.triangle.2.circlepath") { run { status = try await invoke("cloudSync:syncNow") } }
                .disabled(phase == "paused" || phase == "syncing")
        }
        LabeledContent("위치", value: provider == "drive" ? "Google Drive › Bandal" : "iCloud Drive › 반달")
        if provider == "drive", let email = status["driveEmail"] as? String, !email.isEmpty { LabeledContent("Google 계정", value: email) }
        if let uploads = status["uploads"] as? Int, uploads > 0 { Text("업로드 대기 \(uploads)개").font(.caption).foregroundStyle(NativeDesktopTheme.secondary) }
        switch status["reason"] as? String {
        case "account-changed"?:
            Text("다른 \(provider == "drive" ? "Google" : "iCloud") 계정입니다. 이 계정의 반달 폴더와 연결할까요?").font(.caption)
            Button("이 계정에 연결") { turnOn(provider) }
        case "root-missing"?:
            Text("클라우드의 반달 폴더가 없어졌습니다. 이 iPad 자료로 다시 만들까요?").font(.caption)
            Button("다시 만들기") { run { status = try await invoke("cloudSync:recreateRoot") } }
        case "update-required"?, "unsupported-format"?:
            Text("새 버전의 반달이 만든 폴더예요. 앱을 업데이트해 주세요.").font(.caption).foregroundStyle(.orange)
        default: EmptyView()
        }
        if phase == "error" || phase == "waiting", let message = status["message"] as? String {
            Text(message).font(.caption).foregroundStyle(phase == "error" ? .red : NativeDesktopTheme.secondary)
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iCloud에 로그인하고 iCloud Drive를 켜야 합니다. 설정 › [이름] › iCloud에서 반달을 켜 주세요.").font(.caption)
            Button("설정 열기") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
        }
    }

    private var phaseText: String {
        switch phase {
        case "idle": return "최신 상태" + (relative.map { " · \($0)에 동기화" } ?? "")
        case "syncing": return "동기화 중" + ((status["remaining"] as? Int).map { " (\($0)개 남음)" } ?? "")
        case "downloading": return "내려받는 중" + ((status["remaining"] as? Int).map { " (\($0)개)" } ?? "")
        case "waiting": return "열린 문서를 저장한 뒤 이어서 맞춥니다"
        case "paused":
            switch reason {
            case "signed-out"?: return "일시 중지 · iCloud 로그인 필요"
            case "drive-signed-out"?: return "일시 중지 · Google 연결 필요"
            default: return "일시 중지"
            }
        case "error": return "오류"
        default: return relative.map { "준비 중 · 마지막 동기화 \($0)" } ?? "준비 중"
        }
    }

    private var lastSuccess: Date? { (status["lastSuccessAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
    private var relative: String? { lastSuccess.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } }
    private var absolute: String? { lastSuccess.map { $0.formatted(date: .abbreviated, time: .standard) } }

    private var startMessage: String {
        let local = preview?["local"] as? [String: Any] ?? [:]
        return "이 iPad의 과목 \(local["courses"] as? Int ?? 0)개와 자료 \(local["documents"] as? Int ?? 0)개(\(Self.bytes(local["bytes"])))를 \(CloudSyncService.name(shown))에 올립니다."
    }

    private var offMessage: String {
        "동기화를 끌까요? 이 iPad와 \(CloudSyncService.name(provider))의 자료는 그대로 남습니다." + (provider == "drive" ? " Google 연결도 해제됩니다." : "")
    }

    static func bytes(_ value: Any?) -> String { ByteCountFormatter.string(fromByteCount: (value as? NSNumber)?.int64Value ?? 0, countStyle: .file) }

    private func turnOn(_ kind: String) {
        run {
            let value = try await invoke("cloudSync:preview", ["provider": kind])
            preview = value
            if value["available"] as? Bool == true, value["empty"] as? Bool == true { startConfirmation = true }
        }
    }

    private func connect(_ request: [String: Any]) {
        run {
            try await store.flushDocuments()
            let kind = shown
            status = try await invoke("cloudSync:connect", request.merging(["provider": kind]) { $1 })
            preview = nil
            if request["mode"] as? String != "import" { notice = "\(CloudSyncService.name(kind)) 동기화를 켰어요." }
        }
    }

    private func load() async {
        do {
            status = try await invoke("cloudSync:status")
            deviceName = status["deviceName"] as? String ?? "iPad"
        } catch { self.error = error.localizedDescription }
    }

    private func invoke(_ channel: String, _ request: [String: Any] = [:]) async throws -> [String: Any] {
        guard let value = try await store.invoke(channel, request) as? [String: Any] else { throw DesktopRuntimeError("동기화 상태를 확인하지 못했습니다.") }
        return value
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; notice = nil
        Task {
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

/// The connection sheet (design §4.2) for a root that already holds data.
struct NativeSyncConnectSheet: View {
    let preview: [String: Any]
    let connect: ([String: Any]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "merge"
    @State private var checked: Set<String> = []
    @State private var overwriteConfirmation = false
    @State private var importConfirmation = false

    private var pairs: [[String: Any]] { preview["sameName"] as? [[String: Any]] ?? [] }
    private var place: String { CloudSyncService.name(preview["provider"] as? String ?? "icloud") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("클라우드", value: Self.summary(preview["cloud"]))
                    LabeledContent("이 iPad", value: Self.summary(preview["local"]))
                } header: { Text("클라우드에 반달 자료가 있습니다") }
                if !pairs.isEmpty {
                    Section("이름이 같은 과목 \(pairs.count)개") {
                        ForEach(pairs.indices, id: \.self) { index in
                            let pair = pairs[index], remote = pair["remote"] as? String ?? ""
                            // A course this iPad shared with this root before is always joined.
                            Toggle("\(pair["name"] as? String ?? "") ↔ \(pair["name"] as? String ?? "")", isOn: Binding(get: { checked.contains(remote) }, set: { if $0 { checked.insert(remote) } else { checked.remove(remote) } }))
                                .disabled(pair["fixed"] as? Bool == true)
                        }
                    }
                }
                Section {
                    Picker("방법", selection: $mode) {
                        Text("합치기 — 두 쪽 자료를 모두 유지합니다 (권장)").tag("merge")
                        Text("이 iPad 자료로 덮어쓰기 — 클라우드에만 있는 과목 \(deletes.courses)개, 자료 \(deletes.documents)개, 필기 \(deletes.ink)개가 다른 기기에서도 삭제됩니다").tag("overwrite")
                        Text("클라우드 자료 가져오기 — 이 iPad 자료는 따로 보관하고 클라우드 자료로 시작합니다").tag("import")
                    }.pickerStyle(.inline).labelsHidden()
                }
            }
            .navigationTitle("\(place) 연결").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("계속") {
                        switch mode {
                        case "overwrite": overwriteConfirmation = true
                        case "import": importConfirmation = true
                        default: finish()
                        }
                    }.accessibilityIdentifier("native-sync-connect")
                }
            }
            .confirmationDialog("과목 \(deletes.courses)개, 자료 \(deletes.documents)개, 필기 \(deletes.ink)개가 다른 기기에서도 삭제됩니다. 파일은 \(place)에 남습니다. 계속할까요?", isPresented: $overwriteConfirmation, titleVisibility: .visible) {
                Button("덮어쓰기", role: .destructive) { finish() }
            }
            .confirmationDialog("새 프로필에서 클라우드 자료로 시작합니다. 지금 자료는 그대로 보관되고, 설정 › 동기화에서 돌아올 수 있어요.", isPresented: $importConfirmation, titleVisibility: .visible) {
                Button("가져오기") { finish() }
            }
        }
        .onAppear { checked = Set(pairs.compactMap { $0["remote"] as? String }) }
    }

    /// What an overwrite deletes elsewhere: every cloud course not joined here and its documents; in a
    /// joined course the documents this iPad does not have; and cloud ink on the PDFs both hold.
    private var deletes: (courses: Int, documents: Int, ink: Int) {
        let courses = preview["remoteCourses"] as? [[String: Any]] ?? []
        let joined = courses.filter { checked.contains($0["id"] as? String ?? "") }, dropped = courses.filter { !checked.contains($0["id"] as? String ?? "") }
        let chosen = pairs.filter { checked.contains($0["remote"] as? String ?? "") }
        let matched = chosen.map { $0["matched"] as? Int ?? 0 }.reduce(0, +)
        let total = dropped.map { $0["documents"] as? Int ?? 0 }.reduce(0, +) + joined.map { $0["documents"] as? Int ?? 0 }.reduce(0, +) - matched
        return (dropped.count, total, chosen.map { $0["ink"] as? Int ?? 0 }.reduce(0, +) + (preview["sharedInk"] as? Int ?? 0))
    }

    private func finish() {
        let chosen = pairs.filter { checked.contains($0["remote"] as? String ?? "") }.map { ["local": $0["local"] ?? "", "remote": $0["remote"] ?? ""] }
        dismiss()
        // The overwrite is refused if the root changed after this sheet showed it.
        connect(["mode": mode, "pairs": chosen, "fingerprint": preview["fingerprint"] ?? ""])
    }

    private static func summary(_ value: Any?) -> String {
        let value = value as? [String: Any] ?? [:]
        return "과목 \(value["courses"] as? Int ?? 0) · 자료 \(value["documents"] as? Int ?? 0) (\(NativeSettingsSyncPanel.bytes(value["bytes"])))"
    }
}
