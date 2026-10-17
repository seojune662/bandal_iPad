import Foundation
import CoreFoundation

/// JSON boundary helpers shared by the Swift repositories. Numbers remain
/// binary doubles; no JavaScript or decimal conversion participates in storage.
enum NativeValue {
    static let null = NSNull()
    static let ok: [String: Any] = ["ok": true]
    static func string(_ value: Any?, _ name: String) throws -> String {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains("\0"), value.count <= 1_000_000 else { throw DesktopRuntimeError("올바르지 않은 \(name)입니다.", code: "VALIDATION_ERROR") }
        return value
    }
    static func int(_ value: Any?, _ name: String, min: Int = 0, max: Int = Int.max) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue, number.doubleValue >= Double(min),
              number.doubleValue < Double(Int.max), number.doubleValue <= Double(max) else { throw DesktopRuntimeError("올바르지 않은 \(name)입니다.", code: "VALIDATION_ERROR") }
        return number.intValue
    }
    static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    static func decode(_ value: Any?) throws -> Any {
        guard let string = value as? String else { throw DesktopRuntimeError("저장된 데이터를 읽을 수 없습니다.") }
        return try DesktopJSON.decode(Data(string.utf8))
    }
    static func object(_ value: Any?) throws -> [String: Any] {
        guard let result = try decode(value) as? [String: Any] else { throw DesktopRuntimeError("저장된 데이터 형식이 올바르지 않습니다.") }
        return result
    }
    static func now() -> String {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: Date())
    }
    static func date(_ value: String) -> Date? {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func mapped(_ row: [String: Any], _ fields: [String: String]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.value, row[$0.key] ?? null) })
    }
}
