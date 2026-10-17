import Foundation

/// One editor transaction in original Markdown coordinates. Rebasing keeps a
/// second pane's disjoint edits intact, including when Undo runs much later.
struct NativeMarkdownTextChange {
    let range: NSRange
    let replacement: String
    private let translationHunks: [Self]?
    var delta: Int { replacement.utf16.count - range.length }
    private init(range: NSRange, replacement: String) { self.range = range; self.replacement = replacement; translationHunks = nil }

    init(from before: String, to after: String) {
        let old = Array(before.utf16), new = Array(after.utf16)
        var start = 0, suffix = 0
        while start < min(old.count, new.count), old[start] == new[start] { start += 1 }
        while suffix < min(old.count - start, new.count - start), old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        if start > 0, start < old.count, (0xDC00...0xDFFF).contains(old[start]) { start -= 1 }
        if suffix > 0, old.count - suffix < old.count, (0xDC00...0xDFFF).contains(old[old.count - suffix]) { suffix -= 1 }
        range = NSRange(location: start, length: old.count - start - suffix)
        replacement = String(decoding: new[start..<(new.count - suffix)], as: UTF16.self)
        translationHunks = Self.changes(from: before, to: after)
    }

    static func rebase(from base: String, to desired: String, onto current: String) throws -> String {
        if base == current { return desired }
        if desired == base || desired == current { return current }
        let locals = changes(from: base, to: desired), remotes = changes(from: base, to: current)
        var transformed: [Self] = []
        for local in locals {
            var shift = 0, alreadyApplied = false
            for remote in remotes {
                if local.range == remote.range, local.replacement == remote.replacement { alreadyApplied = true; break }
                if local.range.location >= NSMaxRange(remote.range) { shift += remote.delta }
                else if NSMaxRange(local.range) > remote.range.location { throw Conflict() }
            }
            if !alreadyApplied { transformed.append(Self(range: NSRange(location: local.range.location + shift, length: local.range.length), replacement: local.replacement)) }
        }
        var value = current
        for edit in transformed.reversed() { value = (value as NSString).replacingCharacters(in: edit.range, with: edit.replacement) }
        return value
    }

    /// Character-level hunks keep Unicode graphemes intact and avoid treating
    /// untouched text between two edits as though the peer had replaced it.
    static func changes(from before: String, to after: String) -> [Self] {
        if before == after { return [] }
        let old = Array(before), new = Array(after), difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change { case .remove(let offset, _, _): removed.insert(offset); case .insert(let offset, _, _): inserted.insert(offset) }
        }
        var offsets = [0]
        for character in old { offsets.append(offsets.last! + String(character).utf16.count) }
        var i = 0, j = 0, result: [Self] = []
        while i < old.count || j < new.count {
            if removed.contains(i) || inserted.contains(j) {
                let start = i
                var replacement = ""
                while removed.contains(i) || inserted.contains(j) {
                    if removed.contains(i) { i += 1 }
                    if inserted.contains(j) { replacement.append(new[j]); j += 1 }
                }
                result.append(Self(range: NSRange(location: offsets[start], length: offsets[i] - offsets[start]), replacement: replacement))
            } else { i += 1; j += 1 }
        }
        return result
    }

    func translate(_ selected: NSRange) -> NSRange {
        func offset(_ value: Int) -> Int {
            if let translationHunks {
                var shift = 0
                for change in translationHunks {
                    if value < change.range.location { break }
                    if value >= NSMaxRange(change.range) { shift += change.delta }
                    else { return change.range.location + shift + min(value - change.range.location, change.replacement.utf16.count) }
                }
                return max(0, value + shift)
            }
            if value < range.location { return value }
            if value >= NSMaxRange(range) { return max(0, value + delta) }
            return range.location + min(value - range.location, replacement.utf16.count)
        }
        let start = offset(selected.location), end = offset(NSMaxRange(selected))
        return NSRange(location: start, length: max(0, end - start))
    }

    struct Conflict: LocalizedError {
        var errorDescription: String? { "다른 탭에서 같은 부분을 편집했어요. 겹친 편집은 사본으로 보관할 수 있습니다." }
    }
}
