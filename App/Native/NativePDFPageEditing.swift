import Foundation

/// Page-panel operations preserve the source page identities until the storage
/// transaction remaps the PDF, ink, annotations and reader position together.
enum NativePDFPageEditing {
    static func moved(count: Int, from: Int, to: Int) -> [Int]? {
        guard count > 0, (1...count).contains(from), (1...count).contains(to), from != to else { return nil }
        var pages = Array(1...count); pages.insert(pages.remove(at: from - 1), at: to - 1); return pages
    }
    static func moved(count: Int, from: Int, insertionSlot: Int) -> [Int]? {
        guard count > 0, (1...count).contains(from) else { return nil }
        guard (1...(count + 1)).contains(insertionSlot) else { return nil }
        let slot = insertionSlot
        guard slot != from, slot != from + 1 else { return nil }
        return moved(count: count, from: from, to: slot > from ? slot - 1 : slot)
    }
    /// A new page after `page` (0 = before the first). `0` in the recipe is a template copy of the preceding page.
    static func inserted(count: Int, after page: Int) -> [Int]? {
        guard count > 0, (0...count).contains(page) else { return nil }
        return Array(1...count).prefix(page) + [0] + Array(1...count).dropFirst(page)
    }
    static func deleted(count: Int, page: Int) -> [Int]? {
        guard count > 1, (1...count).contains(page) else { return nil }
        return (1...count).filter { $0 != page }
    }
    static func remapped(_ page: Int, pageMap: [[Int]]) -> Int {
        guard !pageMap.isEmpty else { return 1 }
        for candidate in stride(from: min(max(1, page), pageMap.count), through: 1, by: -1) {
            if let target = pageMap[candidate - 1].first { return target }
        }
        return 1
    }
}
