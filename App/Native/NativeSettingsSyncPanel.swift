import SwiftUI
import UIKit

/// Settings › 동기화 (design §4.1–4.5). Independent of the Bandal login and of any subscription,
/// so nothing here mentions either. Choosing iCloud or Google Drive reads the root first and asks
/// only when it already holds data (the connection sheet); Drive asks for a Google account first.
/// While on, the other storage is reached by moving (spec v2.7), never by connecting again.
/// The page is the design's (Figma 132:3879): a status card, the iCloud switch and the linked folders.
/// `detail` is its 더 보기: Google Drive, moving, this device's name and disconnecting.
struct NativeSettingsSyncPanel: View {
    var store: NativeWorkspaceStore
    var detail = false
    var openDetail: () -> Void = {}
    /// Courses that are folders of the Files app (연결한 폴더), and the one being asked about.
    @State private var linked: [[String: Any]] = []
    @State private var unlinking: String?
    @State private var status: [String: Any] = [:]
    @State private var deviceName = ""
    @State private var preview: [String: Any]?
    @State private var startConfirmation = false
    @State private var offConfirmation = false
    /// A move under way here (spec v2.7): the storage it goes to, whether it moves as soon as that storage holds
    /// the data another device moved there (the offer), the Google account that device named, and what was found.
    @State private var moveTarget: String?
    @State private var oneStep = false
    @State private var moveHint: String?
    @State private var movePlan: [String: Any]?
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?

    private var provider: String { status["provider"] as? String ?? "off" }
    private var on: Bool { CloudSyncService.kinds.contains(provider) }
    private var phase: String { status["phase"] as? String ?? "off" }
    private var reason: String? { phase == "paused" ? status["reason"] as? String : nil }
    /// The provider being shown: the one on, or the one a preview is for.
    private var shown: String { preview?["provider"] as? String ?? provider }
    /// The storage a move goes to: the one not on now.
    private var other: String { provider == "drive" ? "icloud" : "drive" }
    /// The provider whose root another device is still filling (spec v2.6).
    private var waitingFor: String? { (preview?["initialUpload"] as? [String: Any])?["going"] as? Bool == true ? shown : nil }
    /// A move waiting for the other storage: another device still fills it, or it is still coming down.
    private var moveWaits: Bool { (movePlan?["initialUpload"] as? [String: Any])?["going"] as? Bool == true || movePlan?["downloading"] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let error { NativeToolError(message: error) }
            if let notice { Label(notice, systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(NativeSettingsRowMetrics.green) }
            if detail { details } else { overview }
        }
        .disabled(busy)
        .task { await load(); await loadLinked() }
        .task(id: waitingFor) {
            // Another device's first upload is looked at again every 30 s (spec v2.6); the sheet opens once it is done or stopped.
            while let kind = waitingFor {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                turnOn(kind)
            }
        }
        .task(id: moveWaits) {
            // So is the storage a move waits for, while this screen is open; the offer moves once it is ready.
            while moveWaits, let kind = moveTarget {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                look(kind, quietly: true)
            }
        }
        .onReceive(store.events) { event in
            guard event.channel == "runtime:cloudSyncChanged", let value = event.payload as? [String: Any] else { return }
            status = status.filter { ["provider", "deviceName", "previousProfile", "lastSuccessAt", "driveEmail"].contains($0.key) }.merging(value) { $1 }
        }
    }

    /// Start, turn off and the connection choice all hang off the control that asked for them.
    private func asking(_ control: some View) -> some View {
        control
            .bandalConfirm(startMessage, isPresented: $startConfirmation, action: "올리기", identifier: "native-sync-start-confirm") { connect(["mode": "start"]) }
            .background(Color.clear.bandalConfirm(offMessage, isPresented: $offConfirmation, action: "끄기", destructive: true, identifier: "native-sync-off-confirm") {
                run { status = try await invoke("cloudSync:disconnect"); preview = nil }
            })
            .overlay(Color.clear.allowsHitTesting(false).bandalPopover(isPresented: Binding(get: { preview?["sameName"] != nil && preview?["empty"] as? Bool == false }, set: { if !$0 { preview = nil } }), width: 380) {
                if let preview { NativeSyncConnectSheet(preview: preview, connect: connect) }
            })
    }

    /// What stands in the way of turning sync on, under the control that tried.
    @ViewBuilder private var notes: some View {
            if shown == "icloud", preview?["available"] as? Bool == false || reason == "signed-out" { signedOut }
            if provider == "drive" && (reason == "drive-signed-out" || status["message"] as? String == GoogleDriveAuth.signedOut.localizedDescription)
                || error == GoogleDriveAuth.signedOut.localizedDescription {
                Button("Google에 다시 연결") { run { status = try await invoke("cloudSync:signInDrive") } }
            }
            if let count = preview?["downloading"] as? Int {
                Text("\(CloudSyncService.name(shown))에서 반달 폴더를 내려받는 중이에요(\(count)개). 잠시 뒤 다시 켜 주세요.").font(.caption).foregroundStyle(NativeDesktopTheme.secondary)
            }
            if preview?["blocked"] != nil { Text("새 버전의 반달이 만든 폴더예요. 앱을 업데이트한 뒤 켜 주세요.").font(.caption).foregroundStyle(.orange) }
            if let uploading = preview?["initialUpload"] as? [String: Any], waitingFor != nil {
                Text("‘\(uploading["device"] as? String ?? "")’에서 \(CloudSyncService.name(shown))에 처음 올리는 중이에요. 30초마다 다시 확인해요.").font(.caption).foregroundStyle(NativeDesktopTheme.secondary)
            }
    }

    /// The status card's four parts.
    private var summary: (symbol: String, tint: Color, title: String, detail: String) {
        let place = CloudSyncService.name(provider)
        guard on else { return ("icloud.slash", NativeDesktopTheme.muted, "동기화 꺼짐", "켜면 같은 계정의 기기끼리 과목과 자료를 맞춰요") }
        switch phase {
        case "idle": return ("checkmark.circle.fill", NativeSettingsRowMetrics.green, "모두 동기화됨", (relative ?? "방금 전") + " · " + place)
        case "paused", "error": return ("exclamationmark.circle.fill", phase == "error" ? NativeSettingsRowMetrics.red : .orange, phaseText, status["message"] as? String ?? place)
        default: return ("arrow.triangle.2.circlepath.circle.fill", NativeDesktopTheme.secondary, phaseText, place)
        }
    }

    @ViewBuilder private var overview: some View {
        let summary = summary
        HStack(spacing: 14) {
            Image(systemName: summary.symbol).font(.system(size: 26)).foregroundStyle(summary.tint).frame(width: 31, height: 31).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                BandalText(summary.title).font(.system(size: 18, weight: .semibold)).contextMenu { if let absolute { Text(absolute) } }.accessibilityIdentifier("native-sync-status")
                BandalText(summary.detail).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("지금 동기화") { run { status = try await invoke("cloudSync:syncNow") } }.buttonStyle(BandalButtonStyle(kind: .soft)).frame(height: 31)
                .disabled(!on || phase == "paused" || phase == "syncing").accessibilityIdentifier("native-sync-now")
        }.padding(21).background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativeDesktopTheme.border))
        // 준비 중: syncing over cellular is the system's switch, and every document already has its copy on this iPad.
        NativeSettingsGroup(description: "셀룰러 데이터 · 오프라인 설정은 준비 중이에요.") {
            asking(NativeSettingsToggle(title: "iCloud 동기화", isOn: Binding(get: { provider == "icloud" }, set: { value in
                if !value { offConfirmation = true } else if on { openDetail(); beginMove("icloud") } else { turnOn("icloud") }
            })).accessibilityIdentifier("native-sync-icloud"))
            NativeSettingsToggle(title: "셀룰러 데이터 사용", isOn: .constant(false)).disabled(true).accessibilityIdentifier("native-sync-cellular")
            NativeSettingsToggle(title: "오프라인에서도 열기", note: "기기에 사본을 저장해요", isOn: .constant(true)).disabled(true).accessibilityIdentifier("native-sync-offline")
            notes
        }
        NativeSettingsGroup(title: "연결한 폴더") {
            ForEach(Array(linked.enumerated()), id: \.offset) { _, course in
                let id = course["id"] as? String ?? ""
                NativeSettingsRow(title: course["name"] as? String ?? "", note: Self.place(course["folderPath"] as? String ?? "")) {
                    Button { unlinking = id } label: { Text("연결 해제").foregroundStyle(NativeSettingsRowMetrics.red) }.frame(height: 31).accessibilityIdentifier("native-sync-unlink-" + id)
                        // The course is put away, as 과목 보관 does: its folder and its notes stay.
                        .bandalConfirm("폴더 연결을 해제할까요?", isPresented: Binding(get: { unlinking == id }, set: { if !$0, unlinking == id { unlinking = nil } }),
                                       message: "과목을 보관해 목록에서 빼요. 폴더의 파일은 그대로 남아요.", action: "연결 해제", destructive: true, identifier: "native-sync-unlink-confirm") {
                            run { try await store.flushDocuments(); _ = try await store.invoke("courses:archive", ["courseId": id, "archived": true]); await loadLinked() }
                        }
                }
            }
            NativeSettingsActionRow(title: "＋ 폴더 연결") {
                run {
                    guard let folder = try await store.invoke("courses:pickFolder") as? [String: Any], let path = folder["path"] as? String else { return }
                    let result = try await store.invoke("courses:addFromFolder", ["folderPath": path, "name": folder["name"] as? String ?? "연결한 과목", "color": "blue"]) as? [String: Any]
                    if result?["status"] as? String == "failed" { throw DesktopRuntimeError(result?["reason"] as? String ?? "폴더를 연결하지 못했습니다.") }
                    await loadLinked()
                }
            }.accessibilityIdentifier("native-sync-link-folder")
        }
        NativeSettingsMoreRow(action: openDetail)
    }

    private static func place(_ path: String) -> String { (["파일 앱"] + URL(fileURLWithPath: path).pathComponents.suffix(2)).joined(separator: " › ") }
    private func loadLinked() async {
        linked = ((try? await store.invoke("courses:list")) as? [[String: Any]] ?? []).filter { $0["source"] as? String == "linked" }
    }

    /// 동기화 › 더 보기.
    @ViewBuilder private var details: some View {
        NativeSettingsGroup(title: "동기화", description: "같은 Apple ID 또는 Google 계정의 기기끼리 과목과 자료를 맞춰요.") {
            asking(Picker("동기화", selection: Binding(get: { on ? provider : "off" }, set: { $0 == "off" ? (offConfirmation = true) : on ? beginMove($0) : turnOn($0) })) {
                Text("끔").tag("off")
                Text("iCloud").tag("icloud")
                Text("Google Drive").tag("drive")
            }.pickerStyle(.segmented).frame(maxWidth: 400).accessibilityIdentifier("native-sync-provider"))
            if on { state }
            notes
            if on { advanced }
        }
        if on, status["moving"] == nil {
            moveOffer
            moveCard
        }
        NativeSettingsGroup(title: "이 기기") {
            LabeledContent("이름") {
                // Saved on Enter; the name labels conflict copies.
                TextField("iPad", text: $deviceName).multilineTextAlignment(.trailing).frame(maxWidth: 240).accessibilityIdentifier("native-sync-device-name")
                    .onSubmit {
                        guard !deviceName.trimmingCharacters(in: .whitespaces).isEmpty, deviceName != status["deviceName"] as? String else { return }
                        run { status = try await invoke("cloudSync:setDeviceName", ["name": deviceName]); notice = "기기 이름을 바꿨어요." }
                    }
            }
            Text("과목·PDF·필기·텍스트 노트가 동기화돼요. 하이라이트·화이트보드·연결 폴더 과목은 빠져요.").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
        }
        if status["previousProfile"] as? Bool == true {
            NativeSettingsGroup(title: "이전 자료", description: "클라우드 자료를 가져오기 전에 이 iPad에 있던 자료로 돌아갑니다. 동기화는 꺼집니다.") {
                Button("이전 자료로 돌아가기") { run { _ = try await invoke("cloudSync:returnToPrevious") } }
            }
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
        if let left = status["moving"] as? String {
            Text("\(CloudSyncService.name(provider))로 옮기는 중이에요. 다 올리면 \(CloudSyncService.name(left))에 알리고 연결을 끊어요.").font(.caption).accessibilityIdentifier("native-sync-moving")
        }
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
        case "syncing": return (status["initial"] as? Bool == true ? "처음 올리는 중" : "동기화 중") + ((status["remaining"] as? Int).map { " (\($0)개 남음)" } ?? "")
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

    // MARK: Moving (spec v2.7)

    /// Another device moved this root's sync to the other storage: this iPad moves too in one step, or not now.
    @ViewBuilder private var moveOffer: some View {
        if moveTarget == nil, let moved = status["moved"] as? [String: Any], let kind = moved["provider"] as? String, let t = (moved["t"] as? NSNumber)?.int64Value {
            let account = (moved["account"] as? String).map { "(\($0))" } ?? ""
            NativeSettingsGroup(title: "\(moved["device"] as? String ?? "")에서 \(CloudSyncService.name(kind))\(account)로 옮겼어요",
                               description: "이 iPad도 옮길까요? 같은 자료는 다시 올리지 않고, \(CloudSyncService.name(provider))의 파일은 지우지 않아요.") {
                HStack {
                    Button("나중에") { run { status = try await invoke("cloudSync:dismissMove", ["t": t]) } }.accessibilityIdentifier("native-sync-move-later")
                    Button("옮기기") { moveTarget = kind; oneStep = true; moveHint = moved["account"] as? String; look(kind) }.accessibilityIdentifier("native-sync-follow")
                }
            }
        }
    }

    /// Moving to the other storage from here: what it holds is shown first, then the move.
    private var moveCard: some View {
        NativeSettingsGroup(title: "저장소 옮기기", description: "자료를 \(CloudSyncService.name(other))로 옮기고 이 iPad를 그쪽에 연결해요. 다른 기기에는 따라 옮길지 묻는 안내가 떠요. \(CloudSyncService.name(provider))의 파일은 지우지 않아요.") {
            if let target = moveTarget {
                if let prepared = movePlan { moveStep(prepared, to: target) } else { Text("\(CloudSyncService.name(target))를 확인하는 중").foregroundStyle(NativeDesktopTheme.secondary) }
            } else {
                HStack {
                    Text("지금은 \(CloudSyncService.name(provider))와 동기화하고 있어요.")
                    Spacer()
                    Button("\(CloudSyncService.name(other))로 옮기기") { beginMove(other) }.accessibilityIdentifier("native-sync-move")
                }
            }
        }.font(NativeDesktopTheme.font(13))
    }

    @ViewBuilder private func moveStep(_ prepared: [String: Any], to target: String) -> some View {
        let name = CloudSyncService.name(target)
        if let plan = prepared["plan"] as? String {
            let local = prepared["local"] as? [String: Any] ?? [:], cloud = prepared["cloud"] as? [String: Any] ?? [:]
            Text(plan == "upload" ? "이 iPad의 과목 \(local["courses"] as? Int ?? 0)개, 자료 \(local["documents"] as? Int ?? 0)개를 \(name)로 옮깁니다. 다 올리면 \(CloudSyncService.name(provider)) 연결을 끊어요."
                 : "\(name)에 이미 과목 \(cloud["courses"] as? Int ?? 0)개가 있어요. 같은 자료는 다시 올리지 않고, 이 iPad에만 있거나 바뀐 것만 올려 합칩니다. 다 맞추면 \(CloudSyncService.name(provider)) 연결을 끊어요.")
                .accessibilityIdentifier("native-sync-move-plan")
            if oneStep, plan == "upload" {
                // Another device moved there, yet it looks empty: another Google account, or iCloud still coming down.
                let device = (status["moved"] as? [String: Any])?["device"] as? String ?? "다른 기기"
                let check = target == "drive"
                    ? "같은 Google 계정\(moveHint.map { "(\($0))" } ?? "")인지 확인해 주세요." + ((prepared["account"] as? String).map { " 지금 로그인한 계정: \($0)." } ?? "")
                    : "iCloud가 아직 내려받는 중일 수 있어요."
                Text("\(device)에서 옮긴 자료가 \(name)에 아직 보이지 않아요. \(check) 그대로 옮기면 이 iPad의 자료를 새로 올려요.").foregroundStyle(.orange)
            }
            if let unfinished = (prepared["initialUpload"] as? [String: Any])?["device"] as? String {
                Text("‘\(unfinished)’에서 \(name)에 처음 올리다 멈췄어요. 옮기면 그 자료와 합쳐요.").foregroundStyle(NativeDesktopTheme.secondary)
            }
            HStack {
                Button("취소") { endMove() }
                if oneStep, plan == "upload", target == "drive" { Button("Google 계정 다시 고르기") { look(target, again: true) }.accessibilityIdentifier("native-sync-move-account") }
                if oneStep, plan == "upload" { Button("다시 확인") { look(target) } }
                Button("옮기기") { run { try await move(target, expect: plan) } }.accessibilityIdentifier("native-sync-move-confirm")
            }
        } else {
            Text(Self.waitText(prepared, name) + (oneStep && moveWaits ? " 이 화면을 열어 두면 준비되는 대로 옮겨요." : "")).foregroundStyle(.orange)
            HStack {
                Button("취소") { endMove() }
                Button("다시 확인") { look(target) }
            }
        }
    }

    /// Why the other storage cannot take this profile now.
    private static func waitText(_ prepared: [String: Any], _ name: String) -> String {
        if let device = (prepared["initialUpload"] as? [String: Any])?["device"] as? String { return "‘\(device)’에서 \(name)에 처음 올리는 중이에요. 다 올린 뒤 옮길 수 있어요." }
        if let count = prepared["downloading"] as? Int { return "\(name)에서 반달 폴더를 내려받는 중이에요(\(count)개)." }
        if prepared["blocked"] != nil { return "새 버전의 반달이 만든 폴더예요. 앱을 업데이트한 뒤 옮겨 주세요." }
        return name == "iCloud" ? "iCloud에 로그인하고 iCloud Drive를 켜야 합니다." : "Google 계정을 연결하지 않았어요."
    }

    /// Disconnecting and connecting again is the advanced way to another storage or another Google account.
    private var advanced: some View {
        DisclosureGroup("고급") {
            VStack(alignment: .leading, spacing: 8) {
                Text("연결 해제는 이 iPad의 동기화를 끕니다. 이 iPad의 자료와 \(CloudSyncService.name(provider))의 파일은 그대로 둡니다. 다시 연결하면 처음 연결할 때처럼 합치기·덮어쓰기·가져오기를 고릅니다. 저장소를 바꿀 때는 저장소 옮기기를, 다른 Google 계정으로 바꿀 때는 연결 해제 뒤 새로 연결하세요.")
                    .font(.caption).foregroundStyle(NativeDesktopTheme.secondary)
                Button("연결 해제", role: .destructive) { offConfirmation = true }.accessibilityIdentifier("native-sync-disconnect")
            }
        }
    }

    private func beginMove(_ kind: String) {
        moveTarget = kind; oneStep = false; moveHint = nil; movePlan = nil
        look(kind)
    }

    private func endMove() { moveTarget = nil; oneStep = false; moveHint = nil; movePlan = nil }

    /// Looks at the other storage. From the offer, a storage that holds data is moved to right away; one that looks
    /// empty is shown first. A recheck nobody asked for keeps waiting when the check fails.
    private func look(_ kind: String, quietly: Bool = false, again: Bool = false) {
        run {
            do {
                var request: [String: Any] = ["provider": kind, "signInAgain": again]
                if let moveHint { request["accountHint"] = moveHint }
                let prepared = try await invoke("cloudSync:prepareMove", request)
                if oneStep, prepared["plan"] as? String == "join" { try await move(kind, expect: "join") } else { movePlan = prepared }
            } catch where quietly {
                return
            } catch {
                if oneStep { endMove() }
                throw error
            }
        }
    }

    private func move(_ kind: String, expect: String) async throws {
        try await store.flushDocuments()
        do { status = try await invoke("cloudSync:move", ["provider": kind, "expect": expect]) } catch { endMove(); throw error }
        endMove()
        notice = "\(CloudSyncService.name(kind))로 옮기기 시작했어요."
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

    private var pairs: [[String: Any]] { preview["sameName"] as? [[String: Any]] ?? [] }
    private var place: String { CloudSyncService.name(preview["provider"] as? String ?? "icloud") }
    /// Another device's first upload stopped partway (spec v2.6): what is there is not all of it.
    private var unfinished: String? { (preview["initialUpload"] as? [String: Any])?["device"] as? String }

    /// Popover under the sync picker. 계속 asks once more, in place, before an overwrite or import.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BandalSectionHeader("\(place)에 반달 자료가 있어요")
            LabeledContent("클라우드", value: Self.summary(preview["cloud"]))
            LabeledContent("이 iPad", value: Self.summary(preview["local"]))
            if let unfinished { Text("‘\(unfinished)’에서 처음 올리다 멈춘 폴더라 합치기나 가져오기만 할 수 있어요.").font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if !pairs.isEmpty {
                BandalMenuDivider()
                Text("이름이 같은 과목 \(pairs.count)개 · 켜면 하나로 합쳐요").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary)
                ForEach(pairs.indices, id: \.self) { index in
                    let pair = pairs[index], remote = pair["remote"] as? String ?? ""
                    // A course this iPad shared with this root before is always joined.
                    Toggle(pair["name"] as? String ?? "", isOn: Binding(get: { checked.contains(remote) }, set: { if $0 { checked.insert(remote) } else { checked.remove(remote) } }))
                        .disabled(pair["fixed"] as? Bool == true)
                }
            }
            BandalMenuDivider()
            BandalMenuRow("합치기", detail: "두 쪽 자료를 모두 유지 (권장)", checked: mode == "merge") { mode = "merge" }
            if unfinished == nil {
                BandalMenuRow("이 iPad 자료로 덮어쓰기", detail: "클라우드에만 있는 과목 \(deletes.courses)개·자료 \(deletes.documents)개·필기 \(deletes.ink)개가 다른 기기에서도 지워져요", checked: mode == "overwrite") { mode = "overwrite" }
            }
            BandalMenuRow("클라우드 자료 가져오기", detail: "이 iPad 자료는 따로 보관하고 클라우드로 시작", checked: mode == "import") { mode = "import" }
            if confirming {
                Text(mode == "overwrite" ? "다른 기기에서 과목 \(deletes.courses)개, 자료 \(deletes.documents)개, 필기 \(deletes.ink)개가 지워져요. 파일은 \(place)에 남아요." : "새 프로필에서 클라우드 자료로 시작해요. 지금 자료는 보관되고 설정 › 동기화에서 돌아올 수 있어요.")
                    .font(.system(size: 12)).foregroundStyle(mode == "overwrite" ? .red : NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(confirming ? (mode == "overwrite" ? "덮어쓰기" : "가져오기") : "계속") {
                    if mode == "merge" || confirming { finish() } else { confirming = true }
                }.font(.system(size: BandalMetrics.bodySize, weight: .semibold)).foregroundStyle(confirming && mode == "overwrite" ? .red : NativeDesktopTheme.text)
                    .accessibilityIdentifier("native-sync-connect")
            }
        }
        .font(.system(size: BandalMetrics.bodySize))
        .onChange(of: mode) { _, _ in confirming = false }
        .onAppear { checked = Set(pairs.compactMap { $0["remote"] as? String }) }
    }
    @State private var confirming = false

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
