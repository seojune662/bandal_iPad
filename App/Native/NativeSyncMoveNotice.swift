import SwiftUI

/// Another device moved this profile's sync to the other storage (spec v2.7): a notice once per move and launch,
/// wherever the user is, leading to Settings › 동기화, where the offer moves this iPad too in one step.
struct NativeSyncMoveNotice: View {
    var store: NativeWorkspaceStore
    let openSettings: () -> Void
    @State private var shown: (text: String, t: Int64)?
    /// Moves already told this launch, by their time.
    @MainActor private static var told = Set<Int64>()

    var body: some View {
        Group {
            if let shown {
                HStack(spacing: 12) {
                    Text(shown.text).font(NativeDesktopTheme.font(13))
                    Button("동기화 설정") { self.shown = nil; openSettings() }.accessibilityIdentifier("native-sync-move-notice")
                    Button("닫기", systemImage: "xmark") { self.shown = nil }.labelStyle(.iconOnly)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: shown.t) {
                    try? await Task.sleep(for: .seconds(8))
                    if self.shown?.t == shown.t { withAnimation { self.shown = nil } }
                }
            }
        }
        .task { if let status = try? await store.invoke("cloudSync:status", [:]) as? [String: Any] { tell(status) } }
        .onReceive(store.events) { event in
            guard event.channel == "runtime:cloudSyncChanged", let value = event.payload as? [String: Any] else { return }
            tell(value)
        }
    }

    private func tell(_ status: [String: Any]) {
        guard let moved = status["moved"] as? [String: Any], let kind = moved["provider"] as? String,
              let t = (moved["t"] as? NSNumber)?.int64Value, !Self.told.contains(t) else { return }
        Self.told.insert(t)
        let account = (moved["account"] as? String).map { "(\($0))" } ?? ""
        withAnimation { shown = ("\(moved["device"] as? String ?? "")에서 \(CloudSyncService.name(kind))\(account)로 옮겼어요. 이 iPad도 옮길까요?", t) }
    }
}
