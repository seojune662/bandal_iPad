import Foundation

/// App Store 1.0 ships local-only: no sync subscription, no sync panel, no marketplace.
/// Flip to `false` to bring them back; their code stays intact behind this switch.
enum NativeReleaseFlags {
    static let isLocalOnly = true
}
