import Foundation

struct NativePDFCompletedStroke: Equatable {
    var mutationID: String
    var kind: String
    var points: [NativePDFPoint]
    var style: NativePDFInkStyle
    /// Captured at contact start; retries and late estimates preserve the renderer contract.
    var inkVersion = 4
}

/// Retains completed measured data through disk-full/protection failures.
/// A retry uses the exact same identity and payload, even if atomic write
/// succeeded but the acknowledgement path subsequently failed.
final class NativePDFCompletionBuffer {
    private(set) var pending: NativePDFCompletedStroke?
    func retain(_ stroke: NativePDFCompletedStroke) throws {
        guard pending == nil || pending == stroke else { throw NativePDFError.invalid("저장 대기 중인 필기를 먼저 복구해 주세요.") }
        pending = stroke
    }
    func flush(_ writer: (NativePDFCompletedStroke) throws -> Void) throws {
        guard let stroke = pending else { return }
        try writer(stroke)
        pending = nil
    }
}

/// Completion order is drawing order, even when the second stroke's pressure
/// correction arrives first. Removal happens after durable write success, so
/// retries preserve both the first failed identity and every later stroke.
final class NativePDFOrderedCompletions<Value> {
    private(set) var ids: [String] = []
    private var values: [String: Value] = [:]
    var isEmpty: Bool { ids.isEmpty }
    var first: Value? { ids.first.flatMap { values[$0] } }
    subscript(id: String) -> Value? {
        get { values[id] }
        set { if ids.contains(id), let newValue { values[id] = newValue } }
    }
    func append(_ value: Value, id: String) throws {
        guard values[id] == nil else { throw NativePDFError.invalid("저장 대기 필기의 순서 식별자가 겹칩니다.") }
        ids.append(id); values[id] = value
    }
    func drain(ready: (Value) -> Bool, writer: (Value) throws -> Void) rethrows {
        while let id = ids.first, let value = values[id], ready(value) {
            try writer(value)
            ids.removeFirst(); values.removeValue(forKey: id)
        }
    }
    func flush(_ writer: (Value) throws -> Void) rethrows { try drain(ready: { _ in true }, writer: writer) }
}
