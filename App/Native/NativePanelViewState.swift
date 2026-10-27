import CryptoKit
import Foundation

/// Presentation state is profile-local and keyed by panel identity, never by the
/// document's shared content ID. A duplicate starts from the file default and
/// subsequently restores its own position after relaunch.
@MainActor
final class NativePanelViewStateStore {
    private let directory: URL
    init(root: URL) { directory = root.appendingPathComponent("native-panel-view-state", isDirectory: true) }
    private func url(_ id: String, kind: String) -> URL {
        let hash = SHA256.hash(data: Data((kind + "\u{0}" + id).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    func read<Value: Decodable>(_ type: Value.Type, id: String, kind: String) -> Value? {
        guard let data = try? Data(contentsOf: url(id, kind: kind)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    func write<Value: Encodable>(_ value: Value, id: String, kind: String) throws {
        let data = try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(id, kind: kind), options: .atomic)
    }
}

struct NativeMediaPanelState: Codable, Equatable {
    var position: Double
    var rate: Float
    var isValid: Bool { position.isFinite && position >= 0 && rate.isFinite && (0.25...3).contains(rate) }
}

struct NativeWhiteboardPanelState: Codable, Equatable {
    var page: Int
    var zoom: Double
    var offsetX: Double
    var offsetY: Double
    var isValid: Bool { page > 0 && zoom.isFinite && zoom > 0 && offsetX.isFinite && offsetY.isFinite }
}
