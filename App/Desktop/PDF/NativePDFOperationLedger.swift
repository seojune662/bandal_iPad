import Foundation
import CryptoKit

/// Native display identity. A pending Pencil row may have only its mutation ID;
/// the desktop receipt supplies its canonical drawing ID before ordered erase.
struct NativePDFEraseTarget: Equatable {
    let drawingID: String?
    let mutationID: String?
    init(drawingID: String? = nil, mutationID: String? = nil) {
        self.drawingID = drawingID; self.mutationID = mutationID
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        same(lhs.drawingID, rhs.drawingID) && same(lhs.mutationID, rhs.mutationID)
    }
    private static func same(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) { case let (.some(a), .some(b)): return a.utf8.elementsEqual(b.utf8)
        case (nil, nil): return true; default: return false }
    }
    var json: [String: Any] {
        var value: [String: Any] = [:]
        if let drawingID { value["drawingId"] = drawingID }
        if let mutationID { value["clientMutationId"] = mutationID }
        return value
    }
    var identifiers: [String] { [drawingID, mutationID].compactMap { $0 } }
}

/// One opened generation's presentation/transport ordering. Stroke durability
/// remains in NativePDFJournal; this ledger never replaces the backend's
/// mutation receipt or considers a JS erase request durable by itself.
@MainActor
final class NativePDFOperationLedger {
    private struct StrokeReceipt {
        let sequence: Int
        var fingerprint: Data?
        var reservedInput: NativePDFStrokeInput?
        var drawingID: String?
    }
    private struct Erase {
        let id: String, sequence: Int, epoch: Int, page: Int
        let targets: [NativePDFEraseTarget]
        var resolved: [NativePDFEraseTarget]?
        var committed = false
        var unknown = false
        var canonicalBarrier = 0, editorBarrier = 0
        var resultFingerprint: Data?
    }
    let documentRevision: String
    private(set) var throughOperationSequence = 0
    private(set) var eraseOperationCount = 0
    private var strokes: [Data: StrokeReceipt] = [:]
    private var strokePayloads: [Int: [String: Any]] = [:]
    private var erases: [Data: Erase] = [:]
    private var completedEraseResults: [Data: Data] = [:]
    private var canonicalObservation = 0, editorObservation = 0
    private var canonicalIDs: [Int: Set<Data>] = [:]
    private var seenCanonicalIDs: [Int: Set<Data>] = [:]
    private var editorIDs: [Int: Set<Data>] = [:]
    private var editorPageObservations: [Int: Int] = [:]
    private var editorRetirementObservation = 0

    init(documentRevision: String) { self.documentRevision = documentRevision }
    func containsLiveStroke(_ mutationID: String) -> Bool { strokes[Data(mutationID.utf8)] != nil }
    func drawingID(for mutationID: String) -> String? { strokes[Data(mutationID.utf8)]?.drawingID }
    var pendingOperations: [[String: Any]] {
        var values = strokePayloads.map { ($0.key, $0.value.merging(["type": "stroke"]) { _, new in new }) }
        values += erases.values.filter { !$0.committed }.map { ($0.sequence, erasePayload($0).merging(["type": "eraseCommit"]) { _, new in new }) }
        return values.sorted { $0.0 < $1.0 }.map(\.1)
    }
    var pendingEraseCount: Int { erases.values.filter { !$0.committed }.count }
    var tombstoneCount: Int { erases.count }
    func excludedIdentifiers(page: Int) -> [String] {
        var seen = Set<Data>()
        return erases.values.filter { $0.page == page }.sorted { $0.sequence < $1.sequence }
            .flatMap { ($0.resolved ?? $0.targets).flatMap(identifiers) }
            .filter { seen.insert(Data($0.utf8)).inserted }
    }
    /// An erase recorded before the stroke's ACK names only the mutation; once
    /// the ACK assigns the drawing id, the canonical row (which carries no
    /// mutation id) must stay hidden until the erase result resolves both.
    private func identifiers(_ target: NativePDFEraseTarget) -> [String] {
        guard target.drawingID == nil, let mutation = target.mutationID, let saved = drawingID(for: mutation) else { return target.identifiers }
        return [saved, mutation]
    }

    struct StrokeReservation { let sequence: Int; let admitted: Bool }
    /// Admission and sequence reservation are one MainActor transaction. A
    /// rejected queue admission consumes no operation number and owns no input.
    func reserveStroke(_ input: NativePDFStrokeInput, admit: () throws -> Void) throws -> StrokeReservation {
        guard input.documentRevision == documentRevision else { throw Self.invalid() }
        try input.validate()
        let key = Data(input.clientMutationId.utf8)
        if let old = strokes[key] {
            if let reserved = old.reservedInput {
                guard Self.sameInput(reserved, input) else { throw Self.invalid() }
            } else {
                // Only a rare retry after ACK needs a synchronous fingerprint;
                // normal input admission never builds JSON or hashes points.
                guard old.fingerprint == (try Self.fingerprint(NativePDFHost.json(input))) else { throw Self.invalid() }
            }
            return StrokeReservation(sequence: old.sequence, admitted: false)
        }
        guard throughOperationSequence < 9_007_199_254_740_991 else { throw Self.invalid() }
        try admit()
        throughOperationSequence += 1
        let sequence = throughOperationSequence
        strokes[key] = StrokeReceipt(sequence: sequence, fingerprint: nil, reservedInput: input)
        return StrokeReservation(sequence: sequence, admitted: true)
    }
    /// Called after the queue's disk watermark covers the final job. The
    /// prepared payload/fingerprint were produced by that same immutable input.
    @discardableResult
    func makeStrokeDurable(_ input: NativePDFStrokeInput, transport: NativePDFJournalQueue.StrokeTransport) throws -> [String: Any] {
        let key = Data(input.clientMutationId.utf8)
        guard var value = strokes[key] else { throw Self.invalid() }
        if let old = value.fingerprint { guard old == transport.fingerprint else { throw Self.invalid() } }
        else {
            guard let reserved = value.reservedInput, Self.sameInput(reserved, input) else { throw Self.invalid() }
            value.fingerprint = transport.fingerprint; strokes[key] = value
        }
        var payload = transport.payload; payload["operationSequence"] = value.sequence
        if value.drawingID == nil { strokePayloads[value.sequence] = payload }
        return payload
    }
    /// Synchronous compatibility path for existing ledger tests/callers whose
    /// input is already durable; production Host uses reserve + worker prepare.
    func recordStroke(_ input: NativePDFStrokeInput) throws -> [String: Any] {
        _ = try reserveStroke(input, admit: {})
        let payload = try NativePDFHost.json(input)
        return try makeStrokeDurable(input, transport: .init(payload: payload, fingerprint: Self.fingerprint(payload)))
    }
    private static func sameInput(_ a: NativePDFStrokeInput, _ b: NativePDFStrokeInput) -> Bool {
        guard a == b else { return false }
        func same(_ x: Double?, _ y: Double?) -> Bool { x?.bitPattern == y?.bitPattern }
        return zip(a.data.points, b.data.points).allSatisfy {
            $0.x.bitPattern == $1.x.bitPattern && $0.y.bitPattern == $1.y.bitPattern && $0.p.bitPattern == $1.p.bitPattern &&
                same($0.t, $1.t) && same($0.tiltX, $1.tiltX) && same($0.tiltY, $1.tiltY)
        }
    }
    func validateStrokeAcknowledgement(mutationID: String, drawingID: String) throws {
        guard !drawingID.isEmpty else { throw Self.invalid() }
        if let receipt = strokes[Data(mutationID.utf8)] {
            guard receipt.fingerprint != nil else { throw Self.invalid() }
            if let previous = receipt.drawingID, !previous.utf8.elementsEqual(drawingID.utf8) { throw Self.invalid() }
        }
    }
    func acknowledgeStroke(mutationID: String, drawingID: String) throws {
        try validateStrokeAcknowledgement(mutationID: mutationID, drawingID: drawingID)
        let key = Data(mutationID.utf8)
        guard var value = strokes[key] else { return } // Prior-generation journal recovery.
        value.drawingID = drawingID; value.reservedInput = nil; strokes[key] = value
        strokePayloads.removeValue(forKey: value.sequence)
    }
    func recordErase(operationID: String, originToolEpoch: Int, page: Int,
                     targets: [NativePDFEraseTarget]) throws -> [String: Any] {
        guard UUID(uuidString: operationID) != nil, originToolEpoch >= 0, page > 0,
              !targets.isEmpty, targets.count <= 100_000 else { throw Self.invalid() }
        try Self.validateTargets(targets)
        let key = Data(operationID.utf8)
        if let old = erases[key] {
            guard old.epoch == originToolEpoch, old.page == page, old.targets == targets else { throw Self.invalid() }
            return erasePayload(old)
        }
        guard completedEraseResults[key] == nil else { throw Self.invalid() }
        let value = Erase(id: operationID, sequence: try nextSequence(), epoch: originToolEpoch, page: page, targets: targets)
        erases[key] = value; eraseOperationCount += 1
        return erasePayload(value)
    }

    /// ACK is a state transition, not a display retirement. Unknown keeps the
    /// operation replayable and hidden; retries must never invoke remove twice.
    func acceptEraseResult(_ request: [String: Any]) throws {
        guard let id = request["operationId"] as? String, UUID(uuidString: id) != nil,
              let outcome = request["outcome"] as? String, ["committed", "unknown"].contains(outcome),
              let sequence = Self.integer(request["operationSequence"]),
              let epoch = Self.integer(request["originToolEpoch"]),
              let page = Self.integer(request["page"]),
              request["documentRevision"] as? String == documentRevision,
              let raw = request["resolvedTargets"] as? [[String: Any]] else { throw Self.invalid() }
        let resolved = try raw.map(Self.target)
        try Self.validateTargets(resolved)
        let proof: [String: Any] = ["operationId": id, "operationSequence": sequence,
            "originToolEpoch": epoch, "page": page, "documentRevision": documentRevision,
            "outcome": outcome, "resolvedTargets": resolved.map(\.json)]
        let fingerprint = try Self.fingerprint(proof), key = Data(id.utf8)
        if let prior = completedEraseResults[key] {
            guard prior == fingerprint else { throw Self.invalid() }; return
        }
        guard var value = erases[key], value.sequence == sequence, value.epoch == epoch,
              value.page == page, resolved.count == value.targets.count else { throw Self.invalid() }
        if let prior = value.resultFingerprint {
            guard prior == fingerprint else { throw Self.invalid() }; return
        }
        for (original, result) in zip(value.targets, resolved) {
            if let d = original.drawingID {
                guard result.drawingID.map({ $0.utf8.elementsEqual(d.utf8) }) == true else { throw Self.invalid() }
            }
            if let m = original.mutationID {
                guard result.mutationID.map({ $0.utf8.elementsEqual(m.utf8) }) == true else { throw Self.invalid() }
                if let d = result.drawingID {
                    guard drawingID(for: m).map({ $0.utf8.elementsEqual(d.utf8) }) == true ||
                          original.drawingID.map({ $0.utf8.elementsEqual(d.utf8) }) == true else { throw Self.invalid() }
                }
            } else if result.mutationID != nil { throw Self.invalid() }
            if outcome == "committed", result.drawingID == nil { throw Self.invalid() }
        }
        value.resolved = resolved; value.resultFingerprint = fingerprint
        value.committed = outcome == "committed"; value.unknown = outcome == "unknown"
        value.canonicalBarrier = canonicalObservation
        value.editorBarrier = editorIDs[value.page] == nil ? 0 : editorObservation
        erases[key] = value
        // Never retire from snapshots that predate this response, even if the
        // newly-created row has not appeared there yet.
    }
    func observeCanonical(_ objects: [[String: Any]]) {
        canonicalObservation += 1; canonicalIDs = Self.identitiesByPage(objects)
        for (page, ids) in canonicalIDs { seenCanonicalIDs[page, default: []].formUnion(ids) }
        reconcile()
    }
    func observeEditor(page: Int, objects: [[String: Any]]) {
        editorObservation += 1
        editorIDs[page] = Self.identities(objects)
        editorPageObservations[page] = editorObservation
        reconcile()
    }
    func retireEditors() {
        editorObservation += 1; editorRetirementObservation = editorObservation
        editorIDs.removeAll(); editorPageObservations.removeAll()
        reconcile()
    }
    /// Returns retired identities for the Host to release already-ACKed native
    /// previews. No journal mutation is performed here.
    private(set) var retiredTargets: [NativePDFEraseTarget] = []
    func takeRetiredTargets() -> [NativePDFEraseTarget] { defer { retiredTargets.removeAll() }; return retiredTargets }
    private func reconcile() {
        var retired: [Data] = []
        for (key, value) in erases where value.committed {
            let targets = value.resolved ?? value.targets
            let ids = Set(targets.flatMap(\.identifiers).map { Data($0.utf8) })
            // An absent pre-create snapshot queued before the ACK is not a
            // deletion fence. IDs never observed live remain hidden for this
            // generation; a future explicit publisher fence can retire them.
            let seen = seenCanonicalIDs[value.page] ?? []
            guard targets.allSatisfy({ target in
                target.identifiers.contains { seen.contains(Data($0.utf8)) }
            }), canonicalObservation > value.canonicalBarrier,
                  (canonicalIDs[value.page] ?? []).isDisjoint(with: ids) else { continue }
            if let editor = editorIDs[value.page] {
                guard (editorPageObservations[value.page] ?? 0) > value.editorBarrier,
                      editor.isDisjoint(with: ids) else { continue }
            } else {
                // No editor scene has ever existed on this page, or its
                // authority was explicitly retired by a later ink-tool switch.
                guard value.editorBarrier == 0 || editorRetirementObservation > value.editorBarrier else { continue }
            }
            retired.append(key); retiredTargets += targets
            if let proof = value.resultFingerprint { completedEraseResults[key] = proof }
        }
        for key in retired { erases.removeValue(forKey: key) }
    }
    private func erasePayload(_ value: Erase) -> [String: Any] {
        ["operationId": value.id, "operationSequence": value.sequence, "originToolEpoch": value.epoch,
         "page": value.page, "documentRevision": documentRevision, "targets": value.targets.map(\.json)]
    }
    private func nextSequence() throws -> Int {
        guard throughOperationSequence < 9_007_199_254_740_991 else { throw Self.invalid() }
        throughOperationSequence += 1; return throughOperationSequence
    }
    private static func target(_ raw: [String: Any]) throws -> NativePDFEraseTarget {
        for key in ["drawingId", "clientMutationId"] {
            if let value = raw[key], !(value is String) { throw invalid() }
        }
        return NativePDFEraseTarget(drawingID: raw["drawingId"] as? String, mutationID: raw["clientMutationId"] as? String)
    }
    private static func validateTargets(_ targets: [NativePDFEraseTarget]) throws {
        var seen: [Data: Int] = [:]
        for (index, target) in targets.enumerated() {
            guard !target.identifiers.isEmpty else { throw invalid() }
            if let mutation = target.mutationID, UUID(uuidString: mutation) == nil { throw invalid() }
            for id in target.identifiers {
                guard !id.isEmpty, id.utf8.count < 8_192 else { throw invalid() }
                let key = Data(id.utf8)
                if let owner = seen[key], owner != index { throw invalid() }
                seen[key] = index
            }
        }
    }
    private static func identities(_ objects: [[String: Any]]) -> Set<Data> {
        Set(objects.flatMap { row in [row["id"] as? String, row["clientMutationId"] as? String].compactMap { $0 }.map { Data($0.utf8) } })
    }
    private static func identitiesByPage(_ objects: [[String: Any]]) -> [Int: Set<Data>] {
        var result: [Int: Set<Data>] = [:]
        for row in objects {
            guard let page = row["page"] as? Int else { continue }
            result[page, default: []].formUnion(identities([row]))
        }
        return result
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue >= 0, n.doubleValue <= 9_007_199_254_740_991,
              n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
        return Int(n.doubleValue)
    }
    private static func fingerprint(_ object: [String: Any]) throws -> Data {
        Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])))
    }
    private static func invalid() -> NativePDFError { .invalid("PDF 지우기 작업의 순서 또는 저장 응답을 확인하지 못했습니다.") }
}
