import Foundation
import Darwin

/// Repository-queue-only cache of immutable JSON payloads. SQLite and binding
/// checks still run for every request; neither timestamps nor object IDs are
/// evidence that ink is unchanged. Exact stored bytes authorize reuse.
final class NativePDFDrawingDecodeCache {
    struct Payload { let data: Any; let style: Any }
    private final class Entry {
        let id: String
        let dataJSON: String, styleJSON: String
        let payload: Payload
        let cost: Int
        weak var previous: Entry?
        var next: Entry?
        init(id: String, dataJSON: String, styleJSON: String, payload: Payload, cost: Int) {
            self.id = id; self.dataJSON = dataJSON; self.styleJSON = styleJSON
            self.payload = payload; self.cost = cost
        }
    }
    private var entries: [String: Entry] = [:]
    private var oldest: Entry?, newest: Entry?
    private(set) var retainedCost = 0
    private(set) var decodeCount = 0
    let costLimit: Int, countLimit: Int

    // JSON object graphs cost more than their source text. Budget four times
    // encoded bytes and at most 12,000 rows; pressure evicts all cached payloads.
    init(costLimit: Int = 256 * 1024 * 1024, countLimit: Int = 12_000) {
        self.costLimit = max(0, costLimit); self.countLimit = max(0, countLimit)
    }
    deinit { removeAll() }
    func removeAll() {
        // Break the chain iteratively; large documents must not recurse through
        // thousands of `next` owners while responding to memory pressure.
        while let entry = oldest { detach(entry) }
        entries.removeAll(); retainedCost = 0
    }
    func decode(_ row: [String: Any]) throws -> Payload {
        guard let id = row["id"] as? String, let data = row["data_json"] as? String,
              let style = row["style_json"] as? String else {
            return Payload(data: try NativePDFRepositoryValidation.parse(row["data_json"]),
                           style: try NativePDFRepositoryValidation.parse(row["style_json"]))
        }
        if let cached = entries[id], Self.sameBytes(cached.dataJSON, data), Self.sameBytes(cached.styleJSON, style) {
            touch(cached); return cached.payload
        }
        if let old = entries.removeValue(forKey: id) { detach(old); retainedCost -= old.cost }
        let payload = Payload(data: try NativePDFRepositoryValidation.parse(data),
                              style: try NativePDFRepositoryValidation.parse(style))
        decodeCount += 1
        let cost = (data.utf8.count + style.utf8.count) * 4 + 256
        guard countLimit > 0, cost <= costLimit else { return payload }
        while entries.count >= countLimit || retainedCost > costLimit - cost {
            guard let entry = oldest else { break }
            detach(entry); entries.removeValue(forKey: entry.id); retainedCost -= entry.cost
        }
        let entry = Entry(id: id, dataJSON: data, styleJSON: style, payload: payload, cost: cost)
        entries[id] = entry; touch(entry)
        retainedCost += cost
        return payload
    }
    private func detach(_ entry: Entry) {
        if let previous = entry.previous { previous.next = entry.next }
        else if oldest === entry { oldest = entry.next }
        if let next = entry.next { next.previous = entry.previous }
        else if newest === entry { newest = entry.previous }
        entry.previous = nil; entry.next = nil
    }
    private func touch(_ entry: Entry) {
        guard newest !== entry else { return }
        detach(entry)
        entry.previous = newest; newest?.next = entry
        newest = entry
        if oldest == nil { oldest = entry }
    }
    private static func sameBytes(_ first: String, _ second: String) -> Bool {
        // String == folds canonical Unicode spellings. UTF8.elementsEqual is
        // exact but its per-byte iterator costs over a second for dense notes
        // in Debug. Swift's contiguous UTF8 buffers allow one exact libc compare.
        var first = first, second = second
        return first.withUTF8 { a in
            second.withUTF8 { b in
                guard a.count == b.count else { return false }
                return a.isEmpty || memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0
            }
        }
    }
}
