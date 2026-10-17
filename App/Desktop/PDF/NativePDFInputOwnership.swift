import Foundation

/// A live surface owns its measured input until ACK or close. Disk records
/// without a live owner are crash recovery; another pane's records are not.
@MainActor
final class NativePDFInputOwnership {
    static let shared = NativePDFInputOwnership()
    private final class Claim { weak var owner: AnyObject?; init(_ owner: AnyObject) { self.owner = owner } }
    private var claims: [String: Claim] = [:]
    private func key(root: URL, course: String, path: String, mutation: String) -> String {
        root.standardizedFileURL.path + "\u{0}" + course + "\u{0}" + path + "\u{0}" + mutation
    }
    func claim(root: URL, course: String, path: String, mutation: String, owner: AnyObject, replacing: AnyObject? = nil) -> Bool {
        let key = key(root: root, course: course, path: path, mutation: mutation)
        if let current = claims[key]?.owner, current !== owner, current !== replacing { return false }
        claims[key] = Claim(owner)
        return true
    }
    func release(root: URL, course: String, path: String, mutation: String, owner: AnyObject) {
        let key = key(root: root, course: course, path: path, mutation: mutation)
        if claims[key]?.owner === owner { claims.removeValue(forKey: key) }
    }
    func releaseAll(owner: AnyObject, returningTo previous: AnyObject? = nil) {
        for key in Array(claims.keys) where claims[key]?.owner === owner {
            if let previous { claims[key] = Claim(previous) } else { claims.removeValue(forKey: key) }
        }
        claims = claims.filter { $0.value.owner != nil }
    }
}

/// All Hosts in one workspace use the same serial disk queue. Two queues may
/// otherwise concurrently mutate the same journal even for different panes.
@MainActor
enum NativePDFSharedJournal {
    private final class WeakQueue { weak var value: NativePDFJournalQueue?; init(_ value: NativePDFJournalQueue) { self.value = value } }
    private static var queues: [String: WeakQueue] = [:]
    static func queue(root: URL) -> NativePDFJournalQueue {
        let key = root.standardizedFileURL.path
        if let value = queues[key]?.value { return value }
        queues = queues.filter { $0.value.value != nil }
        let value = NativePDFJournalQueue(root: root); queues[key] = WeakQueue(value); return value
    }
}
