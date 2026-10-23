import Foundation

/// Raw SQLite rows contain scalar columns, including already-encoded ink JSON.
/// Compare those strings byte-for-byte instead of serializing tens of MB again.
/// This is deliberately as strict as the persisted canonical JSON comparison:
/// Boolean/number types, signed zero and Unicode spelling remain distinct.
enum NativePDFPageStateEquality {
    static func rows(_ left: Any, _ right: Any) throws -> Bool {
        guard let left = left as? [[String: Any]], let right = right as? [[String: Any]], left.count == right.count else { return false }
        for (a, b) in zip(left, right) { if try !row(a, b) { return false } }
        return true
    }
    static func row(_ left: [String: Any], _ right: [String: Any]) throws -> Bool {
        guard left.count == right.count else { return false }
        for (key, value) in left {
            // Swift Dictionary lookup treats canonically equivalent Unicode
            // keys as equal; the old canonical JSON bytes do not.
            guard let index = right.index(forKey: key), string(key, right[index].key),
                  try scalar(value, right[index].value) else { return false }
        }
        return true
    }
    static func scalar(_ left: Any, _ right: Any) throws -> Bool {
        if let a = left as? String, let b = right as? String { return string(a, b) }
        if left is NSNull || right is NSNull { return left is NSNull && right is NSNull }
        if let a = left as? NSNumber, let b = right as? NSNumber {
            guard a.doubleValue.isFinite, b.doubleValue.isFinite else { return false }
            // Tiny scalar encoding preserves JSONSerialization's numeric rules
            // exactly (NSNumber equality would equate true/1 and -0/0).
            return try NativeSyncFormat.canonical(a) == NativeSyncFormat.canonical(b)
        }
        // No nested containers exist in the page-history SQL schema. An unknown
        // future column type must not grant permission to overwrite newer data.
        return false
    }
    private static func string(_ left: String, _ right: String) -> Bool {
        // NSString equality is literal UTF-16 equality (unlike Swift String's
        // canonical-equivalence equality) and avoids transcoding Cocoa strings.
        (left as NSString).isEqual(to: right)
    }

}
