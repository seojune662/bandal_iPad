import Foundation

/// App Store 1.0 ships local-only: no account/login, no sync subscription, no sync panel, no marketplace.
/// Flip to `false` to bring them back; their code stays intact behind this switch.
enum NativeReleaseFlags {
    static let isLocalOnly = true
    /// Lecture recording is left out of iPad 1.0: the default on-device model did not transcribe
    /// lecture-hall (far-field) audio reliably. Its code stays; flip to bring the entry points back.
    static let showsRecording = false
}
