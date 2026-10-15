import Foundation

/// JSON numbers cross the JavaScript bridge as IEEE-754 doubles. Foundation
/// can parse a decimal token into NSDecimalNumber whose doubleValue rounds
/// differently from the token itself. Parse that decimal spelling directly
/// before a renderer or another JavaScript bridge consumes the value.
enum DesktopJSON {
    static func decode(_ data: Data, options: JSONSerialization.ReadingOptions = []) throws -> Any {
        try immutableCopy(JSONSerialization.jsonObject(with: data, options: options))
    }

    /// Detaches mutable JSON containers without a write/parse round trip.
    /// Ordinary integer and Boolean boxes retain their JSON types.
    static func immutableCopy(_ value: Any) throws -> Any {
        try copy(value, depth: 0)
    }

    private static func copy(_ value: Any, depth: Int) throws -> Any {
        guard depth <= 512 else { throw invalid() }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return NSNumber(value: number.boolValue) }
            if let decimal = number as? NSDecimalNumber {
                guard let exact = Double(decimal.stringValue), exact.isFinite else { throw invalid() }
                return NSNumber(value: exact)
            }
            guard number.doubleValue.isFinite, let frozen = number.copy() as? NSNumber else { throw invalid() }
            return frozen
        }
        if let string = value as? String { return string }
        if value is NSNull { return NSNull() }
        if let dictionary = value as? [String: Any] {
            return try dictionary.mapValues { try copy($0, depth: depth + 1) }
        }
        if let array = value as? [Any] { return try array.map { try copy($0, depth: depth + 1) } }
        throw invalid()
    }

    private static func invalid() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: 3840,
                userInfo: [NSLocalizedDescriptionKey: "JSON contains an unsupported or non-finite value."])
    }
}
