import AVFAudio
import EventKit
import UIKit
import UserNotifications

/// Injectable OS access, so permission recovery tests never show real prompts.
@MainActor
struct DesktopPermissionAccess {
    var state: (String) async -> String
    var request: (String) async throws -> Void
    var openSettings: () async -> Bool

    static func live(calendar: EKEventStore) -> Self {
        Self(state: { id in
            switch id {
            case "microphone":
                switch AVAudioApplication.shared.recordPermission {
                case .granted: return "granted"
                case .denied: return "denied"
                case .undetermined: return "not-determined"
                @unknown default: return "unknown"
                }
            case "calendar":
                switch EKEventStore.authorizationStatus(for: .event) {
                case .fullAccess: return "granted"
                case .denied, .restricted: return "denied"
                // Full access can upgrade an earlier write-only grant.
                case .notDetermined, .writeOnly: return "not-determined"
                default: return "unknown"
                }
            case "notifications":
                switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
                case .authorized, .provisional, .ephemeral: return "granted"
                case .denied: return "denied"
                case .notDetermined: return "not-determined"
                @unknown default: return "unknown"
                }
            default: return "not-applicable"
            }
        }, request: { id in
            switch id {
            case "microphone": _ = await AVAudioApplication.requestRecordPermission()
            case "calendar": _ = try await calendar.requestFullAccessToEvents()
            case "notifications": _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            default: break
            }
        }, openSettings: {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return false }
            return await UIApplication.shared.open(url)
        })
    }
}
