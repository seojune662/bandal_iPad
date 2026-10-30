import Foundation

/// Release switches. Each one maps to exactly one feature so that turning on one surface
/// can never bring back another (1.0/1.1 used a single `isLocalOnly` switch for all of them).
enum NativeReleaseFlags {
    /// Optional 반달 login (rail button and the settings account category). It never gates local files.
    static let showsAccount = true
    /// The pre-2026-10-30 Supabase record sync (CommonSync) and server-verified billing. Both upload
    /// to Supabase, which the current principles forbid; their code stays intact behind this switch.
    /// Never turn it back on as is: the account-binding confirmation it relied on is gone, so the
    /// first signed-in account would sync this device's content.
    static let legacyCloudSync = false
    /// The study market uploads materials to Supabase Storage; its channels are refused while off.
    static let showsMarketplace = false
    /// Lecture recording is left out of iPad 1.0 (App Review 2.5.4): the audio capture service,
    /// microphone permission and background audio mode were removed, so flipping this alone
    /// does not bring recording back. Restore DesktopRecordingService from git history first.
    static let showsRecording = false
}
