import Foundation
import CoreGraphics
import Darwin

/// Transport only. Canonical objects and history continue to live in the
/// desktop drawing repository, not in PDFKit annotations or PKDrawing blobs.
struct NativePDFPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var p: Double
    var t: Double?
    var tiltX: Double?
    var tiltY: Double?
    var isValid: Bool {
        [x, y, p].allSatisfy(\.isFinite) && (0...1).contains(x) && (0...1).contains(y)
            && (0...1).contains(p) && [t, tiltX, tiltY].compactMap { $0 }.allSatisfy(\.isFinite)
    }
}

struct NativePDFInkStyle: Codable, Equatable {
    var color: String
    var width: Double
    var opacity: Double
    var isValid: Bool {
        ["ink", "red", "orange", "yellow", "green", "blue", "violet"].contains(color)
            && width.isFinite && width > 0 && width <= 1
            && opacity.isFinite && (0...1).contains(opacity)
    }
}

struct NativePDFStrokeData: Codable, Equatable {
    var points: [NativePDFPoint]
    var inkVersion = 2
}

struct NativePDFStrokeInput: Codable, Equatable {
    var courseId: String
    var relPath: String
    var page: Int
    var kind: String
    var data: NativePDFStrokeData
    var style: NativePDFInkStyle
    /// The backend commits this key and the drawing in the same transaction.
    /// Replaying after a lost renderer acknowledgement cannot duplicate ink.
    var clientMutationId: String
    /// Optional only to decode journals written by earlier diagnostic builds.
    /// Every new native stroke binds to its immutable opened PDF snapshot.
    var documentRevision: String? = nil

    func validate() throws {
        guard !courseId.isEmpty, !relPath.isEmpty, page > 0,
              ["ink", "highlighter"].contains(kind), data.inkVersion == 2,
              !data.points.isEmpty, data.points.count <= 250_000,
              data.points.allSatisfy(\.isValid), style.isValid,
              UUID(uuidString: clientMutationId) != nil else {
            throw NativePDFError.invalid("필기 자료를 확인할 수 없습니다.")
        }
    }
}

struct NativePDFPendingStroke: Codable, Equatable {
    var version = 1
    var createdAt: Date
    var documentRevision: String
    var input: NativePDFStrokeInput
    /// Only an unsubmitted checkpoint can be refined by UIKit's late measured
    /// force/location estimates. A finalized receipt payload is immutable.
    var provisional: Bool? = nil
}

enum NativePDFError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

/// Durable completion journal, separate from canonical storage. A completed
/// stroke remains here until the desktop repository confirms the same mutation
/// ID. The journal survives renderer/process recreation and app upgrades.
final class NativePDFJournal {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    init(root: URL) throws {
        directory = root.appendingPathComponent("PendingNativePDFInk", isDirectory: true)
        encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func append(_ input: NativePDFStrokeInput, documentRevision: String) throws {
        try write(input, documentRevision: documentRevision, provisional: false)
    }
    func checkpoint(_ input: NativePDFStrokeInput, documentRevision: String) throws {
        try write(input, documentRevision: documentRevision, provisional: true)
    }
    private func write(_ input: NativePDFStrokeInput, documentRevision: String, provisional: Bool) throws {
        try input.validate()
        let url = file(input.clientMutationId)
        var createdAt = Date()
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try decoder.decode(NativePDFPendingStroke.self, from: Data(contentsOf: url))
            guard previous.documentRevision == documentRevision else { throw NativePDFError.invalid("필기 작업 식별자가 충돌했습니다.") }
            if previous.provisional != true {
                guard previous.input == input, !provisional else { throw NativePDFError.invalid("완료된 필기 내용을 변경할 수 없습니다.") }
                try synchronize(url)
                return
            }
            var unchanged = previous.input; unchanged.data.points = input.data.points
            guard unchanged == input, previous.input.data.points.count == input.data.points.count,
                  zip(previous.input.data.points, input.data.points).allSatisfy({ $0.t == $1.t }) else {
                throw NativePDFError.invalid("필기 보정 정보가 원래 획과 다릅니다.")
            }
            createdAt = previous.createdAt
        }
        let record = NativePDFPendingStroke(createdAt: createdAt, documentRevision: documentRevision, input: input, provisional: provisional ? true : nil)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try encoder.encode(record).write(to: temporary, options: [.completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try synchronizeDirectory()
    }
    func pending(courseID: String, relativePath: String) throws -> [NativePDFPendingStroke] {
        // Corrupt records are not deleted or skipped: recovering the journal
        // must fail visibly rather than silently losing a completed stroke.
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                let record = try decoder.decode(NativePDFPendingStroke.self, from: Data(contentsOf: url))
                guard record.version == 1, url.lastPathComponent == record.input.clientMutationId + ".json" else {
                    throw NativePDFError.invalid("보관된 필기 작업을 확인할 수 없습니다.")
                }
                try record.input.validate(); return record
            }
            .filter { $0.input.courseId == courseID && $0.input.relPath == relativePath }
            .sorted { $0.createdAt < $1.createdAt }
    }
    func acknowledge(_ mutationID: String, courseID: String, relativePath: String) throws {
        guard UUID(uuidString: mutationID) != nil else { throw NativePDFError.invalid("잘못된 필기 작업 식별자입니다.") }
        let url = file(mutationID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let record = try decoder.decode(NativePDFPendingStroke.self, from: Data(contentsOf: url))
        guard record.input.courseId == courseID, record.input.relPath == relativePath else {
            throw NativePDFError.invalid("다른 자료의 필기 작업을 완료할 수 없습니다.")
        }
        try FileManager.default.removeItem(at: url)
        try synchronizeDirectory()
    }
    private func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
        try synchronizeDirectory()
    }
    private func synchronizeDirectory() throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func file(_ mutationID: String) -> URL { directory.appendingPathComponent(mutationID + ".json") }
}

enum NativePDFInkGeometry {
    static let circleSegments = 24
    /// Same normalized polygons as renderer/nativePDF's shared ink v2: circles
    /// and pressure-varying quads. All triangles are filled as one union before
    /// opacity is composited, so a highlighter never darkens itself.
    static func polygons(points: [NativePDFPoint], width: Double, aspect: Double, highlighter: Bool) -> [[CGPoint]] {
        guard !points.isEmpty, width.isFinite, width > 0, aspect.isFinite, aspect > 0,
              points.allSatisfy(\.isValid) else { return [] }
        func radius(_ p: NativePDFPoint) -> Double { width * (highlighter ? 1 : 0.35 + 0.65 * min(1, max(0, p.p))) / 2 }
        var output: [[CGPoint]] = []
        for (index, point) in points.enumerated() {
            let r = radius(point)
            if index > 0 {
                let previous = points[index - 1], before = radius(previous)
                let dx = point.x - previous.x, dy = (point.y - previous.y) * aspect
                let distance = hypot(dx, dy)
                if distance > 1e-12 {
                    let nx = -dy / distance, ny = dx / distance
                    output.append([
                        CGPoint(x: previous.x - nx * before, y: previous.y - ny * before / aspect),
                        CGPoint(x: point.x - nx * r, y: point.y - ny * r / aspect),
                        CGPoint(x: point.x + nx * r, y: point.y + ny * r / aspect),
                        CGPoint(x: previous.x + nx * before, y: previous.y + ny * before / aspect)
                    ])
                }
            }
            output.append((0..<circleSegments).map { step in
                let angle = Double(step) * 2 * .pi / Double(circleSegments)
                return CGPoint(x: point.x + cos(angle) * r, y: point.y + sin(angle) * r / aspect)
            })
        }
        return output
    }
}
