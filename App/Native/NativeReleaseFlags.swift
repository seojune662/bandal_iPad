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
    /// 반달 멤버십: the free allowance, the paywall and settings › 구독. On from 1.2.0, which goes to review together
    /// with the App Store subscription products; without live products free users would meet a paywall with nothing to buy.
    static let membership = true
    /// The study market uploads materials to Supabase Storage; its channels are refused while off.
    static let showsMarketplace = false
    /// Lecture recording, back with foreground-only capture: no UIBackgroundModes audio (App
    /// Review 2.5.4 rejected 1.0.0 (5) for declaring it). Recording stops and saves when the
    /// app leaves the foreground.
    static let showsRecording = true
    /// Rows and switches the design draws for features that are not built (note moves between folders, offline copies,
    /// voice input, handwriting to text, Japanese, connected services…). Off: a control that can only say "준비 중" is not shown.
    static let showsUnbuiltFeatures = false
}
