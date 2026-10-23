import Foundation

/// App Store 1.0 ships local-only: no account/login, no sync subscription, no sync panel, no marketplace.
/// Flip to `false` to bring them back; their code stays intact behind this switch.
enum NativeReleaseFlags {
    static let isLocalOnly = true
    /// Lecture recording is left out of iPad 1.0 (App Review 2.5.4): the audio capture service,
    /// microphone permission and background audio mode were removed, so flipping this alone
    /// does not bring recording back. Restore DesktopRecordingService from git history first.
    static let showsRecording = false
}
