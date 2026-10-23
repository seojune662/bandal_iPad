import Foundation

/// Can only be created by detaching and validating the complete JSON value.
/// Native consumers share this immutable value instead of copying every point again.
struct NativePDFValidatedDrawingJSON {
    let value: [String: Any]
    private init(_ value: [String: Any]) { self.value = value }
    static func freeze(_ source: [String: Any]) throws -> Self {
        guard let value = try DesktopJSON.immutableCopy(source) as? [String: Any] else {
            throw NativePDFError.invalid("PDF 필기 데이터를 확인하지 못했습니다.")
        }
        return Self(value)
    }
}

/// Owns immutable, validated JSON rows. Bridge payloads cannot manufacture the
/// native visual identity used by the compositor's unchanged-row fast path.
@MainActor
final class NativePDFDrawingSnapshotStore {
    @MainActor final class Row {
        let id: String
        let page: Int
        let object: [String: Any]
        let visualToken: NativePDFCommittedVisualToken
        private var encoded: Data?
        private var preparedAspect: Double?
        // Visible overlays and the bounded path LRU own geometry strongly.
        // A document's visited rows must never retain every prepared path.
        private weak var preparedInk: NativePDFPreparedInk?
        private var preparedWithoutInk = false
        private(set) var preparationCount = 0

        fileprivate init(id: String, page: Int, json: NativePDFValidatedDrawingJSON, encoded: Data?, previous: Row?) {
            self.id = id; self.page = page; self.object = json.value; self.encoded = encoded
            visualToken = NativePDFCommittedVisualToken(validatedJSON: json)
            preparedInk = previous?.preparedInk
        }

        fileprivate func canonicalBytes() throws -> Data {
            if let encoded { return encoded }
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            encoded = bytes; return bytes
        }

        /// Only a new/changed row or a changed physical aspect parses points.
        /// Scrolling, ACKs, tool changes and later strokes reuse this payload.
        func prepared(aspect: Double) -> [String: Any] {
            var result = object
            if preparedAspect == aspect, preparedInk != nil || preparedWithoutInk {
                result["_nativeInk"] = preparedInk; return result
            }
            result["_nativeInk"] = NativePDFObjectRenderer.prepareInk(object, aspect: aspect, reusing: preparedInk)
            preparedInk = result["_nativeInk"] as? NativePDFPreparedInk
            preparedWithoutInk = preparedInk == nil
            preparedAspect = aspect; preparationCount += 1
            return result
        }
        func releasePreparedInk() { preparedInk = nil; preparedAspect = nil; preparedWithoutInk = false }
    }

    private(set) var revision = 0
    private(set) var order: [String] = []
    private var rows: [String: Row] = [:]
    private(set) var replacementCount = 0
    private(set) var fastReuseCount = 0
    private(set) var fullPreparationCount = 0
    var orderedRows: [Row] { order.compactMap { rows[$0] } }
    func row(id: String) -> Row? { rows[id] }
    private(set) var rowsByPage: [Int: [Row]] = [:]
    func rows(page: Int) -> [Row] { rowsByPage[page] ?? [] }

    /// A failed patch never changes rows, order, revision, or retained tokens.
    /// Legacy full snapshots remain accepted for older renderers. Returns the
    /// pages whose row identities changed (upsert, removal or reorder).
    @discardableResult
    func apply(_ request: [String: Any], pageCount: Int) throws -> Set<Int> {
        guard request["drawingPatch"] == nil || request["drawings"] == nil else { throw invalid() }
        let nextRevision: Int, nextOrder: [String], upserts: [[String: Any]], reset: Bool
        if let rawPatch = request["drawingPatch"] {
            guard let patch = rawPatch as? [String: Any], let rawReset = patch["reset"] as? NSNumber,
                  CFGetTypeID(rawReset) == CFBooleanGetTypeID(),
                  let base = integer(patch["baseRevision"]), let next = integer(patch["revision"]),
                  let ids = patch["order"] as? [String], let updates = patch["upserts"] as? [[String: Any]],
                  next > 0 else { throw invalid() }
            reset = rawReset.boolValue
            guard reset ? (base == 0 && next > revision) : (base == revision && next == base + 1) else { throw invalid() }
            nextRevision = next; nextOrder = ids; upserts = updates
        } else if let full = request["drawings"] {
            guard let values = full as? [[String: Any]] else { throw invalid() }
            let ids = values.compactMap { $0["id"] as? String }
            guard ids.count == values.count else { throw invalid() }
            nextRevision = 0; nextOrder = ids; upserts = values; reset = true
        } else { return [] }
        guard nextOrder.count <= 100_000, nextOrder.allSatisfy({ !$0.isEmpty }),
              Set(nextOrder).count == nextOrder.count else { throw invalid() }
        let retained = Set(nextOrder)
        var nextRows = reset ? [:] : rows
        var seen: Set<String> = [], replacements = 0
        for object in upserts {
            guard let id = object["id"] as? String, !id.isEmpty, seen.insert(id).inserted,
                  retained.contains(id) else { throw invalid() }
            let row = try makeRow(object, pageCount: pageCount, previous: rows[id])
            if row !== rows[id] { replacements += 1 }
            nextRows[id] = row
        }
        guard nextOrder.allSatisfy({ nextRows[$0] != nil }) else { throw invalid() }
        // Build first, then publish the whole scene in one synchronous step.
        rows = nextRows.filter { retained.contains($0.key) }
        order = nextOrder; revision = nextRevision; replacementCount += replacements
        var next: [Int: [Row]] = [:]
        for id in order { if let row = rows[id] { next[row.page, default: []].append(row) } }
        let changed = Set(rowsByPage.keys).union(next.keys).filter { page in
            let before = rowsByPage[page] ?? [], after = next[page] ?? []
            return before.count != after.count || !zip(before, after).allSatisfy { $0 === $1 }
        }
        rowsByPage = next
        return changed
    }

    /// Also used by measured pending strokes; the caller assigns their local
    /// ID and creates a replacement only when that stroke actually changes.
    func makeRow(_ source: [String: Any], pageCount: Int, previous: Row? = nil) throws -> Row {
        guard let id = source["id"] as? String, !id.isEmpty,
              let page = integer(source["page"]), page > 0, page <= pageCount,
              source["kind"] is String, source["data"] is [String: Any], source["style"] is [String: Any] else { throw invalid() }
        var clean = source
        clean.removeValue(forKey: "_nativeInk"); clean.removeValue(forKey: "_nativeVisualToken")
        // Compare the incoming values, including every metadata key, with the
        // detached row. Never accept dictionary identity or a caller marker:
        // mutable nested containers must be reread even on the same reference.
        if let previous, Self.matchesFrozenJSON(clean, previous.object) {
            fastReuseCount += 1
            return previous
        }
        fullPreparationCount += 1
        // immutableCopy already rejects unsupported values, excessive nesting
        // and non-finite numbers. A separate isValidJSONObject walk repeated it.
        let json = try NativePDFValidatedDrawingJSON.freeze(clean)
        // First ingestion needs no equality bytes. On a real changed-row
        // comparison preserve the canonical JSON fallback used by older callers.
        var encoded: Data?
        if let previous {
            let bytes = try JSONSerialization.data(withJSONObject: json.value, options: [.sortedKeys])
            if try previous.canonicalBytes() == bytes { return previous }
            encoded = bytes
        }
        return Row(id: id, page: page, json: json, encoded: encoded, previous: previous)
    }

    /// A conservative proof that freezing would produce the same values.
    /// Unrecognized types, depth overflow and non-finite values fall through
    /// to the existing complete validation/freezing/encoding path.
    private static func matchesFrozenJSON(_ raw: Any, _ frozen: Any, depth: Int = 0) -> Bool {
        guard depth <= 512 else { return false }
        if let left = raw as? NSNumber {
            guard let right = frozen as? NSNumber else { return false }
            let leftIsBool = CFGetTypeID(left) == CFBooleanGetTypeID()
            let rightIsBool = CFGetTypeID(right) == CFBooleanGetTypeID()
            guard leftIsBool == rightIsBool else { return false }
            if leftIsBool { return left.boolValue == right.boolValue }
            guard let a = exactNumber(left), let b = exactNumber(right) else { return false }
            return a == b
        }
        if let left = raw as? String {
            guard let right = frozen as? String else { return false }
            // JSON/JavaScript distinguish canonically equivalent Unicode
            // spellings; Swift String == deliberately does not.
            return left.utf8.elementsEqual(right.utf8)
        }
        if raw is NSNull { return frozen is NSNull }
        if let left = raw as? [String: Any] {
            guard let right = frozen as? [String: Any], left.count == right.count else { return false }
            return left.allSatisfy { key, value in
                guard let index = right.index(forKey: key) else { return false }
                let entry = right[index]
                guard key.utf8.elementsEqual(entry.key.utf8) else { return false }
                return matchesFrozenJSON(value, entry.value, depth: depth + 1)
            }
        }
        if let left = raw as? [Any] {
            guard let right = frozen as? [Any], left.count == right.count else { return false }
            return zip(left, right).allSatisfy { matchesFrozenJSON($0, $1, depth: depth + 1) }
        }
        return false
    }
    private enum ExactNumber: Equatable {
        case signed(Int64)
        case unsigned(UInt64)
        case floating(type: Int8, bits: UInt64)
    }
    private static func exactNumber(_ value: NSNumber) -> ExactNumber? {
        let number: NSNumber
        if let decimal = value as? NSDecimalNumber {
            // Exactly DesktopJSON.immutableCopy's decimal normalization; using
            // decimal.doubleValue here can introduce a different binary value.
            guard let exact = Double(decimal.stringValue), exact.isFinite else { return nil }
            number = NSNumber(value: exact)
        } else { number = value }
        guard number.doubleValue.isFinite else { return nil }
        // Integer payloads avoid Double collisions above 2^53. Conservative
        // integer/float or signed/unsigned differences use the old slow path.
        let type = number.objCType.pointee
        switch type {
        case 102, 100: // f, d
            return .floating(type: type, bits: number.doubleValue.bitPattern)
        case 99, 115, 105, 108, 113: // c, s, i, l, q
            return .signed(number.int64Value)
        case 67, 83, 73, 76, 81: // C, S, I, L, Q
            return .unsigned(number.uint64Value)
        default: return nil
        }
    }

    func releasePreparedInk() { rows.values.forEach { $0.releasePreparedInk() } }
    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }
    private func invalid() -> NativePDFError { .invalid("PDF 필기 화면의 변경 순서를 확인할 수 없습니다. 전체 화면 자료를 다시 보내 주세요.") }
}
