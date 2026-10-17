import Foundation
import CoreGraphics
import Darwin
import QuartzCore

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
        ["ink", "red", "orange", "yellow", "green", "blue", "violet", "canvasLightInk"].contains(color)
            && width.isFinite && width > 0 && width <= 1
            && opacity.isFinite && (0...1).contains(opacity)
    }
}

struct NativePDFStrokeData: Codable, Equatable {
    var points: [NativePDFPoint]
    var inkVersion = 4
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
    /// The fit is journaled before ACK so a restart cannot lose a confirmed correction.
    var heldShape: NativePDFHeldShape? = nil

    func validate() throws {
        guard !courseId.isEmpty, !relPath.isEmpty, page > 0,
              ["ink", "highlighter"].contains(kind), [2, 3, 4, 5].contains(data.inkVersion),
              !data.points.isEmpty, data.points.count <= 250_000,
              data.points.allSatisfy(\.isValid), style.isValid, heldShape?.isValid != false,
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

/// Bounded diagnostics shared by input, persistence, and overlay stages.
struct NativePDFLatencySamples {
    private var samples: [Double] = []
    private var nextIndex = 0
    private(set) var count = 0
    private(set) var lastMS = 0.0
    private(set) var maxMS = 0.0
    private(set) var slowCount = 0
    var retainedSampleCount: Int { samples.count }
    var p95MS: Double {
        guard !samples.isEmpty else { return 0 }
        let ordered = samples.sorted()
        return ordered[max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)]
    }
    mutating func record(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        count += 1; lastMS = milliseconds; maxMS = max(maxMS, milliseconds)
        if milliseconds >= 24 { slowCount += 1 }
        if samples.count < 240 { samples.append(milliseconds) }
        else { samples[nextIndex] = milliseconds; nextIndex = (nextIndex + 1) % 240 }
    }
    var shouldLog: Bool {
        count <= 3 || count.isMultiple(of: 50) ||
            (lastMS >= 24 && (slowCount <= 20 || slowCount.isMultiple(of: 50)))
    }
    var diagnostics: [String: Any] { ["count": count, "lastMS": lastMS, "maxMS": maxMS, "p95MS": p95MS] }
    var logCode: String {
        func rounded(_ value: Double) -> Int { Int(min(value.rounded(), Double(Int.max / 2))) }
        return "n.\(count).last.\(rounded(lastMS))ms.max.\(rounded(maxMS))ms.p95.\(rounded(p95MS))ms"
    }
    /// UIKit timestamps share the monotonic uptime clock. Synthetic fixtures
    /// can use arbitrary epochs; do not misreport those as physical input lag.
    static func inputDeliveryMS(timestamp: TimeInterval, enteredAt: CFTimeInterval) -> Double? {
        guard timestamp.isFinite, enteredAt.isFinite, timestamp > 0 else { return nil }
        let seconds = enteredAt - timestamp
        guard seconds >= 0, seconds <= 60 else { return nil }
        return seconds * 1000
    }
}

/// Durable completion journal, separate from canonical storage. A completed
/// stroke remains here until the desktop repository confirms the same mutation
/// ID. The journal survives renderer/process recreation and app upgrades.
final class NativePDFJournal {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private struct FileIdentity: Equatable {
        let device: dev_t, inode: ino_t, size: off_t
        let modifiedSeconds: Int, modifiedNanoseconds: Int
        let changedSeconds: Int, changedNanoseconds: Int
        init(_ url: URL) throws {
            var value = stat()
            guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }
    private struct DurableRecord {
        let mutationID: String
        let bytes: Data
        let identity: FileIdentity
    }
    // Late Pencil estimates can resolve without changing their measured values.
    // Retain only the last successful barrier, not a second copy of every stroke.
    private var lastDurableRecord: DurableRecord?
    private var pendingAcknowledgementBarriers: [String: (courseID: String, relativePath: String)] = [:]
    private let beforeDirectorySynchronization: (() throws -> Void)?
    private(set) var synchronizationCount = 0
    private(set) var timingStatistics: [String: NativePDFLatencySamples] = [:]
    init(root: URL, beforeDirectorySynchronization: (() throws -> Void)? = nil) throws {
        directory = root.appendingPathComponent("PendingNativePDFInk", isDirectory: true)
        self.beforeDirectorySynchronization = beforeDirectorySynchronization
        encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func append(_ input: NativePDFStrokeInput, documentRevision: String) throws {
        let started = CACurrentMediaTime(); defer { recordTiming("commit", startedAt: started) }
        try write(input, documentRevision: documentRevision, provisional: false)
    }
    func checkpoint(_ input: NativePDFStrokeInput, documentRevision: String) throws {
        let started = CACurrentMediaTime(); defer { recordTiming("checkpoint", startedAt: started) }
        try write(input, documentRevision: documentRevision, provisional: true)
    }
    private func write(_ input: NativePDFStrokeInput, documentRevision: String, provisional: Bool) throws {
        try input.validate()
        let url = file(input.clientMutationId)
        var createdAt = Date()
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            let previous = try decoder.decode(NativePDFPendingStroke.self, from: bytes)
            guard previous.version == 1, previous.input.clientMutationId == input.clientMutationId else {
                throw NativePDFError.invalid("보관된 필기 작업을 확인할 수 없습니다.")
            }
            try previous.input.validate()
            guard previous.documentRevision == documentRevision else { throw NativePDFError.invalid("필기 작업 식별자가 충돌했습니다.") }
            if previous.provisional != true {
                guard previous.input == input, !provisional else { throw NativePDFError.invalid("완료된 필기 내용을 변경할 수 없습니다.") }
                try synchronizeUnchanged(url, bytes: bytes, mutationID: input.clientMutationId)
                return
            }
            var unchanged = previous.input; unchanged.data.points = input.data.points
            guard unchanged == input, previous.input.data.points.count == input.data.points.count,
                  zip(previous.input.data.points, input.data.points).allSatisfy({ $0.t == $1.t }) else {
                throw NativePDFError.invalid("필기 보정 정보가 원래 획과 다릅니다.")
            }
            if provisional, previous.input == input {
                try synchronizeUnchanged(url, bytes: bytes, mutationID: input.clientMutationId)
                return
            }
            createdAt = previous.createdAt
        }
        let record = NativePDFPendingStroke(createdAt: createdAt, documentRevision: documentRevision, input: input, provisional: provisional ? true : nil)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bytes = try encoder.encode(record)
        try bytes.write(to: temporary, options: [.completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: temporary)
        do { try synchronizeFile(handle); try handle.close() } catch { try? handle.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try synchronizeDirectory()
        lastDurableRecord = DurableRecord(mutationID: input.clientMutationId, bytes: bytes, identity: try FileIdentity(url))
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
        let started = CACurrentMediaTime(); defer { recordTiming("ack", startedAt: started) }
        guard UUID(uuidString: mutationID) != nil else { throw NativePDFError.invalid("잘못된 필기 작업 식별자입니다.") }
        let url = file(mutationID)
        if let barrier = pendingAcknowledgementBarriers[mutationID] {
            guard barrier.courseID.utf8.elementsEqual(courseID.utf8),
                  barrier.relativePath.utf8.elementsEqual(relativePath.utf8) else {
                throw NativePDFError.invalid("다른 자료의 필기 작업을 완료할 수 없습니다.")
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // An earlier unlink can succeed before its directory fsync fails.
            // That retry must finish the same owner's barrier before ACK succeeds.
            if pendingAcknowledgementBarriers[mutationID] != nil {
                try synchronizeDirectory()
                pendingAcknowledgementBarriers.removeValue(forKey: mutationID)
            }
            return
        }
        let record = try decoder.decode(NativePDFPendingStroke.self, from: Data(contentsOf: url))
        guard record.input.courseId == courseID, record.input.relPath == relativePath else {
            throw NativePDFError.invalid("다른 자료의 필기 작업을 완료할 수 없습니다.")
        }
        try FileManager.default.removeItem(at: url)
        pendingAcknowledgementBarriers[mutationID] = (courseID, relativePath)
        if lastDurableRecord?.mutationID == mutationID { lastDurableRecord = nil }
        try synchronizeDirectory()
        pendingAcknowledgementBarriers.removeValue(forKey: mutationID)
    }
    private func synchronizeUnchanged(_ url: URL, bytes: Data, mutationID: String) throws {
        let identity = try FileIdentity(url)
        // Always read and validate the actual file first. A new journal, failed
        // barrier, external replacement, or changed bytes must synchronize again.
        if let durable = lastDurableRecord, durable.mutationID == mutationID,
           durable.identity == identity, durable.bytes == bytes { return }
        try synchronize(url)
        lastDurableRecord = DurableRecord(mutationID: mutationID, bytes: bytes, identity: try FileIdentity(url))
    }
    private func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        do { try synchronizeFile(handle); try handle.close() } catch { try? handle.close(); throw error }
        try synchronizeDirectory()
    }
    private func synchronizeFile(_ handle: FileHandle) throws {
        let started = CACurrentMediaTime(); defer { recordTiming("fileSync", startedAt: started) }
        try handle.synchronize()
    }
    private func synchronizeDirectory() throws {
        let started = CACurrentMediaTime(); defer { recordTiming("directorySync", startedAt: started) }
        try beforeDirectorySynchronization?()
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        synchronizationCount += 1
    }
    private func recordTiming(_ phase: String, startedAt: CFTimeInterval) {
        timingStatistics[phase, default: NativePDFLatencySamples()].record(milliseconds: (CACurrentMediaTime() - startedAt) * 1000)
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
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.p.isFinite }) else { return [] }
        // A canonical stroke can move outside the page through selection.
        // Rendering follows the shared v2 finite-coordinate/pressure-clamp
        // contract; NativePDFStrokeInput.validate still guards new input.
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
