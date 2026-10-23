import Foundation

/// One canonical edit lane per PDF file. Views retain their own history and
/// viewport; successful writes update every live view before the next edit.
@MainActor
final class NativePDFFileCoordinator {
    private final class WeakCoordinator { weak var value: NativePDFFileCoordinator?; init(_ value: NativePDFFileCoordinator) { self.value = value } }
    private final class Peer { weak var value: NativePDFPersistence?; init(_ value: NativePDFPersistence) { self.value = value } }
    private static var files: [String: WeakCoordinator] = [:]
    static func shared(root: URL, courseID: String, relativePath: String) -> NativePDFFileCoordinator {
        let key = root.standardizedFileURL.path + "\u{0}" + courseID + "\u{0}" + relativePath
        if let value = files[key]?.value { return value }
        files = files.filter { $0.value.value != nil }
        let value = NativePDFFileCoordinator(); files[key] = WeakCoordinator(value); return value
    }
    private var peers: [Peer] = []
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private weak var failedOwner: NativePDFPersistence?
    func register(_ owner: NativePDFPersistence) { peers.removeAll { $0.value == nil }; peers.append(Peer(owner)) }
    func perform<T>(owner: NativePDFPersistence, _ action: () async throws -> T) async throws -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        if let failedOwner, failedOwner !== owner {
            throw NativePDFError.invalid("같은 PDF의 다른 창에서 저장을 완료하지 못했습니다. 해당 창의 저장을 다시 시도해 주세요.")
        }
        do {
            let result = try await action(); failedOwner = nil; return result
        } catch {
            // Keep an uncertain partial edit owned by its original writer.
            // Another view must never replay or supersede its durable intent.
            if owner.hasUnsettledEdits { failedOwner = owner }
            throw error
        }
    }
    func publish(from owner: NativePDFPersistence, drawings: [[String: Any]]? = nil, annotations: [[String: Any]]? = nil,
                 drawingIDs: Set<String>? = nil, annotationIDs: Set<String>? = nil) {
        peers.removeAll { $0.value == nil }
        for peer in peers {
            guard let value = peer.value, value !== owner else { continue }
            value.receiveCoordinatedSnapshot(drawings: drawings, annotations: annotations,
                                             drawingIDs: drawingIDs, annotationIDs: annotationIDs)
        }
    }
}
