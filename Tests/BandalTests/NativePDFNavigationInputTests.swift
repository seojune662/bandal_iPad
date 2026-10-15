import XCTest
import UIKit
import PDFKit
@testable import Bandal

/// Same-page input lifecycle and measured values. These call production input
/// methods with synthetic touches; they do not establish UIKit arbitration,
/// compositor presentation, or physical Apple Pencil latency.
@MainActor
final class NativePDFNavigationInputTests: XCTestCase {
    func testLiftedEstimatedStrokeKeepsCorrectionAfterNavigation() throws {
        let f = try Fixture(); defer { f.close() }
        let a = f.touch(index: 11, properties: .force)
        XCTAssertTrue(f.surface.beginPencilGesture(a, with: nil))
        f.surface.endPencilGesture(a, with: nil)
        let original = try XCTUnwrap(f.checkpoints.first?.points.first)
        try f.surface.prepareForNavigation()
        XCTAssertTrue(f.completed.isEmpty, "Finger navigation must not finalize a lifted estimated stroke")
        f.pan()
        a.pressure = 0.8; a.expecting = []; a.altitude = 0.2; a.azimuth = 1.1
        f.surface.updatePencilGestureProperties([a])
        XCTAssertEqual(f.completed.count, 1)
        let final = try XCTUnwrap(f.completed.last?.points.first)
        assertPositionBits(final, original)
        XCTAssertEqual(final.tiltX?.bitPattern, original.tiltX?.bitPattern)
        XCTAssertEqual(final.tiltY?.bitPattern, original.tiltY?.bitPattern)
        XCTAssertEqual(final.p, 0.8)
        try f.assertStoredExactly()
    }

    func testActivePencilKeepsAllSamplesAcrossNavigationAndMixedBases() throws {
        let f = try Fixture(); defer { f.close() }
        let a = f.touch(index: 21, properties: .force)
        let b = f.touch(index: 22, properties: .force, point: CGPoint(x: 240, y: 160), time: 10.01)
        XCTAssertTrue(f.surface.beginPencilGesture(a, with: nil))
        f.surface.movePencilGesture(a, with: SamplesEvent(contact: a, samples: [b]))
        let expectedA = f.point(a), expectedB = f.point(b)
        try f.surface.prepareForNavigation()
        XCTAssertTrue(f.completed.isEmpty)
        f.pan()
        let c = f.touch(point: CGPoint(x: 260, y: 170), time: 10.02)
        let d = f.touch(point: CGPoint(x: 280, y: 175), time: 10.03)
        let expectedC = f.point(c), expectedD = f.point(d)
        f.surface.movePencilGesture(a, with: SamplesEvent(contact: a, samples: [c]))
        a.pressure = 0.7; a.expecting = []; b.pressure = 0.9; b.expecting = []
        f.surface.updatePencilGestureProperties([a, b])
        XCTAssertTrue(f.completed.isEmpty, "Navigation and estimates cannot end an active contact")
        f.surface.endPencilGesture(a, with: SamplesEvent(contact: a, samples: [d]))
        XCTAssertEqual(f.completed.count, 1)
        let points = try XCTUnwrap(f.completed.first?.points)
        XCTAssertEqual(points.count, 4)
        guard points.count == 4 else { return }
        for (actual, expected) in zip(points, [expectedA, expectedB, expectedC, expectedD]) {
            XCTAssertEqual(actual.x.bitPattern, expected.x.bitPattern)
            XCTAssertEqual(actual.y.bitPattern, expected.y.bitPattern)
        }
        XCTAssertEqual(points.map(\.p), [0.7, 0.9, 0.1, 0.1])
        XCTAssertEqual(points.map(\.t), [0, (10.01-10)*1000, (10.02-10)*1000, (10.03-10)*1000])
        try f.assertStoredExactly()
    }

    func testCoalescedReuseOfEstimateIndexRetainsOriginalPositionAndTime() throws {
        let f = try Fixture(); defer { f.close() }
        let a = f.touch(index: 31, properties: .force)
        let original = f.point(a)
        XCTAssertTrue(f.surface.beginPencilGesture(a, with: nil))
        try f.surface.prepareForNavigation(); f.pan()
        let replacement = f.touch(index: 31, properties: .force, point: a.point, time: 30)
        replacement.pressure = 0.6
        f.surface.movePencilGesture(a, with: SamplesEvent(contact: a, samples: [replacement]))
        f.surface.endPencilGesture(a, with: SamplesEvent(contact: a, samples: [replacement]))
        XCTAssertTrue(f.completed.isEmpty)
        replacement.pressure = 0.9; replacement.expecting = []
        f.surface.updatePencilGestureProperties([replacement])
        XCTAssertEqual(f.completed.count, 1)
        let points = try XCTUnwrap(f.completed.first?.points)
        XCTAssertEqual(points.count, 1)
        let point = try XCTUnwrap(points.first)
        XCTAssertEqual(point.x.bitPattern, original.x.bitPattern)
        XCTAssertEqual(point.y.bitPattern, original.y.bitPattern)
        XCTAssertEqual(point.t?.bitPattern, 0.0.bitPattern)
        XCTAssertEqual(point.p, 0.9)
        try f.assertStoredExactly()
    }

    func testPartialForceAndAltitudeKeepNonEstimatedAzimuthAfterRotation() throws {
        let f = try Fixture(); defer { f.close() }
        let a = f.touch(index: 41, properties: [.force, .altitude])
        a.altitude = .pi / 3; a.azimuth = .pi / 4
        XCTAssertTrue(f.surface.beginPencilGesture(a, with: nil))
        f.surface.endPencilGesture(a, with: nil)
        let original = try XCTUnwrap(f.checkpoints.first?.points.first)
        try f.surface.prepareForNavigation()
        f.surface.transform = CGAffineTransform(rotationAngle: .pi / 3).scaledBy(x: 1.2, y: 1.2)
        a.pressure = 0.6; a.altitude = .pi / 4; a.azimuth = -.pi / 2; a.expecting = .altitude
        f.surface.updatePencilGestureProperties([a])
        XCTAssertTrue(f.completed.isEmpty, "Altitude is still awaiting its real value")
        a.pressure = 0.99; a.altitude = .pi / 6; a.expecting = []
        f.surface.updatePencilGestureProperties([a])
        let final = try XCTUnwrap(f.completed.first?.points.first)
        assertPositionBits(final, original)
        XCTAssertEqual(final.p, 0.6, "A resolved force must not change in a later altitude-only update")
        let expected = atan(cos(Double.pi / 4) / tan(Double.pi / 6)) * 180 / Double.pi
        XCTAssertEqual(try XCTUnwrap(final.tiltX), expected, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(final.tiltY), expected, accuracy: 1e-10)
        try f.assertStoredExactly()
    }

    func testEstimatedAzimuthUsesCaptureRotationAndKeepsMeasuredAltitude() throws {
        let f = try Fixture(); defer { f.close() }
        f.surface.transform = CGAffineTransform(rotationAngle: .pi / 6)
        let a = f.touch(index: 45, properties: .azimuth)
        a.altitude = .pi / 3; a.azimuth = .pi / 4
        XCTAssertTrue(f.surface.beginPencilGesture(a, with: nil))
        f.surface.endPencilGesture(a, with: nil)
        let original = try XCTUnwrap(f.checkpoints.first?.points.first)
        try f.surface.prepareForNavigation()
        f.surface.transform = CGAffineTransform(rotationAngle: -.pi / 4)
        f.surface.center.x += 80
        a.azimuth = .pi / 2; a.altitude = .pi / 6; a.pressure = 0.9; a.expecting = []
        f.surface.updatePencilGestureProperties([a])
        let final = try XCTUnwrap(f.completed.first?.points.first)
        assertPositionBits(final, original)
        XCTAssertEqual(final.p.bitPattern, original.p.bitPattern)
        // Window azimuth 90° in the captured view's +30° basis is 60°.
        let angle = Double.pi / 3, altitude = Double.pi / 3
        XCTAssertEqual(try XCTUnwrap(final.tiltX), atan(cos(angle) / tan(altitude)) * 180 / .pi, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(final.tiltY), atan(sin(angle) / tan(altitude)) * 180 / .pi, accuracy: 1e-10)
        try f.assertStoredExactly()
    }

    func testLocationCorrectionsUseTheirOwnCaptureBeforeAndAfterNavigation() throws {
        let f = try Fixture(); defer { f.close() }
        // .location exercises the coordinate contract; predictions still never
        // enter measured storage. This is not evidence of hardware location estimates.
        let a = f.touch(index: 51, properties: [.location, .force])
        XCTAssertTrue(f.surface.beginPencilGesture(a, with: nil))
        let expectedA = f.surface.mapper!.normalized(f.surface.convert(CGPoint(x: 150, y: 160), from: f.window), pressure: 0.8)
        try f.surface.prepareForNavigation(); f.pan()
        let b = f.touch(index: 52, properties: .location, point: CGPoint(x: 220, y: 160), time: 10.01)
        f.surface.movePencilGesture(a, with: SamplesEvent(contact: a, samples: [b]))
        let expectedB = f.surface.mapper!.normalized(f.surface.convert(CGPoint(x: 230, y: 160), from: f.window), pressure: 0.1)
        f.surface.endPencilGesture(a, with: SamplesEvent(contact: a, samples: [b]))
        a.point.x = 150; a.pressure = 0.8; a.expecting = .force
        f.surface.updatePencilGestureProperties([a])
        XCTAssertTrue(f.completed.isEmpty)
        // Location has resolved; another force update must keep the earlier correction.
        a.point.x = 190; a.pressure = 0.9; a.expecting = []
        b.point.x = 230; b.expecting = []
        f.surface.updatePencilGestureProperties([a, b])
        let points = try XCTUnwrap(f.completed.first?.points)
        XCTAssertEqual(points.count, 2)
        guard points.count == 2 else { return }
        XCTAssertEqual(points[0].x, expectedA.x, accuracy: 1e-12)
        XCTAssertEqual(points[1].x, expectedB.x, accuracy: 1e-12)
        XCTAssertEqual(points[0].p, 0.9)
        XCTAssertEqual(points[0].t, 0)
        XCTAssertEqual(points[1].t, (10.01-10)*1000)
        try f.assertStoredExactly()
    }

    func testFailedCheckpointNavigationKeepsGateAndExactRetry() throws {
        let f = try Fixture(); defer { f.close() }
        let a = f.touch(index: 61, properties: .force)
        XCTAssertTrue(f.surface.beginPencilGesture(a, with: nil))
        f.failCheckpoint = true
        f.surface.endPencilGesture(a, with: nil)
        XCTAssertEqual(f.surface.inputDiagnostics["journalBlocked"] as? Bool, true)
        f.failCheckpoint = false
        let attempts = f.checkpointAttempts
        try f.surface.prepareForNavigation(); f.pan()
        XCTAssertEqual(f.checkpointAttempts, attempts)
        XCTAssertTrue(f.completed.isEmpty)
        XCTAssertEqual(f.surface.inputDiagnostics["journalBlocked"] as? Bool, true)
        a.pressure = 0.8; a.expecting = []
        f.surface.updatePencilGestureProperties([a])
        XCTAssertEqual(f.completed.count, 1)
        XCTAssertEqual(f.completed.first?.points.first?.p, 0.8)
        XCTAssertEqual(f.surface.inputDiagnostics["journalBlocked"] as? Bool, false)
        try f.assertStoredExactly()
    }

    func testNavigationCannotReorderEarlierUnresolvedAndLaterCompletedStrokes() throws {
        let f = try Fixture(); defer { f.close() }
        let a = f.touch(index: 71, properties: .force)
        XCTAssertTrue(f.surface.beginPencilGesture(a, with: nil)); f.surface.endPencilGesture(a, with: nil)
        try f.surface.prepareForNavigation(); f.pan()
        let b = f.touch(index: 72, properties: .force, point: CGPoint(x: 200, y: 200), time: 11)
        XCTAssertTrue(f.surface.beginPencilGesture(b, with: nil)); f.surface.endPencilGesture(b, with: nil)
        let ids = f.checkpoints.prefix(2).map(\.mutationID)
        b.pressure = 0.9; b.expecting = []
        f.surface.updatePencilGestureProperties([b])
        XCTAssertTrue(f.completed.isEmpty)
        try f.surface.prepareForNavigation()
        XCTAssertTrue(f.completed.isEmpty)
        a.pressure = 0.8; a.expecting = []
        f.surface.updatePencilGestureProperties([a])
        XCTAssertEqual(f.completed.map(\.mutationID), ids)
        XCTAssertEqual(f.completed.map { $0.points.first!.p }, [0.8, 0.9])
        try f.assertStoredExactly()
    }

    func testNavigationEndsObjectEditWithOneUpWithoutInkCommit() throws {
        let f = try Fixture(); defer { f.close() }
        f.surface.tool = .init(name: "rect", style: f.surface.tool.style)
        var phases: [String] = []
        f.surface.onPointer = { if let phase = $0["phase"] as? String { phases.append(phase) } }
        let a = f.touch()
        XCTAssertTrue(f.surface.beginPencilGesture(a, with: nil))
        try f.surface.prepareForNavigation(); try f.surface.prepareForNavigation()
        a.point.x += 10; a.time += 0.01
        f.surface.movePencilGesture(a, with: nil); f.surface.endPencilGesture(a, with: nil)
        XCTAssertEqual(phases, ["down", "up"])
        XCTAssertTrue(f.completed.isEmpty); XCTAssertTrue(f.checkpoints.isEmpty)
    }

    func testExplicitToolSwitchStillFinalizesPendingStrokeOnce() throws {
        let f = try Fixture(); defer { f.close() }
        let a = f.touch(index: 81, properties: .force)
        XCTAssertTrue(f.surface.beginPencilGesture(a, with: nil)); f.surface.endPencilGesture(a, with: nil)
        f.surface.tool = .init(name: "select", style: f.surface.tool.style)
        XCTAssertEqual(f.completed.count, 1)
        try f.surface.prepareForNavigation()
        XCTAssertEqual(f.completed.count, 1)
        try f.assertStoredExactly()
    }

    private func assertPositionBits(_ lhs: NativePDFPoint, _ rhs: NativePDFPoint,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.x.bitPattern, rhs.x.bitPattern, file: file, line: line)
        XCTAssertEqual(lhs.y.bitPattern, rhs.y.bitPattern, file: file, line: line)
        XCTAssertEqual(lhs.t?.bitPattern, rhs.t?.bitPattern, file: file, line: line)
    }
}

@MainActor
private final class Fixture {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
    let surface: NativePDFInkSurface
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("navigation-input-\(UUID())")
    let journal: NativePDFJournal
    let store = NativePDFDrawingSnapshotStore()
    var completed: [NativePDFCompletedStroke] = [], checkpoints: [NativePDFCompletedStroke] = []
    var canonical: [[String: Any]] = []
    var failCheckpoint = false, checkpointAttempts = 0
    init() throws {
        surface = try XCTUnwrap(NativePDFInkSurface())
        journal = try NativePDFJournal(root: root)
        surface.frame = CGRect(x: 20, y: 30, width: 600, height: 400)
        surface.mapper = .whiteboard(size: surface.bounds.size)
        surface.tool = .init(name: "pen", style: .init(color: "ink", width: 0.004, opacity: 1))
        surface.isLoading = false; window.addSubview(surface)
        surface.onCheckpoint = { [unowned self] stroke in
            checkpointAttempts += 1
            if failCheckpoint { throw CocoaError(.fileWriteOutOfSpace) }
            try journal.checkpoint(input(stroke), documentRevision: String(repeating: "a", count: 64))
            checkpoints.append(stroke)
        }
        surface.onStroke = { [unowned self] stroke in
            let value = input(stroke)
            try journal.append(value, documentRevision: String(repeating: "a", count: 64))
            var object = try NativePDFHost.json(value)
            object["id"] = stroke.mutationID
            canonical.append(object); try store.apply(["drawings": canonical], pageCount: 1)
            completed.append(stroke)
        }
    }
    func input(_ s: NativePDFCompletedStroke) -> NativePDFStrokeInput {
        .init(courseId: "course", relPath: "fixture.pdf", page: 1, kind: s.kind,
              data: .init(points: s.points), style: s.style, clientMutationId: s.mutationID,
              documentRevision: String(repeating: "a", count: 64))
    }
    func touch(index: NSNumber? = nil, properties: UITouch.Properties = [],
               point: CGPoint = CGPoint(x: 140, y: 160), time: TimeInterval = 10) -> NavigationTouch {
        let t = NavigationTouch(window: window); t.index = index; t.expecting = properties; t.point = point; t.time = time; return t
    }
    func point(_ t: NavigationTouch) -> InkPoint { surface.mapper!.normalized(t.preciseLocation(in: surface), pressure: Double(t.pressure)) }
    func pan() { surface.frame.origin.x -= 80; surface.refreshViewport() }
    func assertStoredExactly(file: StaticString = #filePath, line: UInt = #line) throws {
        let saved = try journal.pending(courseID: "course", relativePath: "fixture.pdf")
        XCTAssertEqual(saved.count, completed.count, file: file, line: line)
        XCTAssertEqual(store.orderedRows.count, completed.count, file: file, line: line)
        for s in completed {
            XCTAssertEqual(saved.first { $0.input.clientMutationId == s.mutationID }?.input, input(s), file: file, line: line)
            let row = try XCTUnwrap(canonical.first { $0["id"] as? String == s.mutationID }, file: file, line: line)
            let decoded = try JSONDecoder().decode(NativePDFStrokeInput.self, from: JSONSerialization.data(withJSONObject: row))
            XCTAssertEqual(decoded, input(s), file: file, line: line)
            for (a,b) in zip(decoded.data.points,s.points) {
                XCTAssertEqual(a.x.bitPattern,b.x.bitPattern,file:file,line:line)
                XCTAssertEqual(a.y.bitPattern,b.y.bitPattern,file:file,line:line)
                XCTAssertEqual(a.p.bitPattern,b.p.bitPattern,file:file,line:line)
                XCTAssertEqual(a.t?.bitPattern,b.t?.bitPattern,file:file,line:line)
                XCTAssertEqual(a.tiltX?.bitPattern,b.tiltX?.bitPattern,file:file,line:line)
                XCTAssertEqual(a.tiltY?.bitPattern,b.tiltY?.bitPattern,file:file,line:line)
            }
        }
    }
    func close() {
        // Finish the test-owned lifetime with its temporary journal still connected.
        failCheckpoint = false
        surface.removeFromSuperview()
        surface.onStroke = nil; surface.onCheckpoint = nil
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class NavigationTouch: UITouch {
    weak var sourceWindow: UIWindow?
    var point = CGPoint.zero, time: TimeInterval = 10, pressure: CGFloat = 0.1
    var altitude: CGFloat = .pi / 2, azimuth: CGFloat = 0
    var index: NSNumber?, expecting: UITouch.Properties = []
    init(window: UIWindow) { sourceWindow = window; super.init() }
    override var window: UIWindow? { sourceWindow }
    override var type: UITouch.TouchType { .pencil }
    override var timestamp: TimeInterval { time }
    override var force: CGFloat { pressure }
    override var maximumPossibleForce: CGFloat { 1 }
    override var altitudeAngle: CGFloat { altitude }
    override var estimationUpdateIndex: NSNumber? { index }
    override var estimatedProperties: UITouch.Properties { expecting }
    override var estimatedPropertiesExpectingUpdates: UITouch.Properties { expecting }
    override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: sourceWindow) ?? point }
    override func preciseLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override func azimuthUnitVector(in view: UIView?) -> CGVector {
        let a = point, b = CGPoint(x: point.x + cos(azimuth), y: point.y + sin(azimuth))
        let va = view?.convert(a, from: sourceWindow) ?? a, vb = view?.convert(b, from: sourceWindow) ?? b
        let length = hypot(vb.x-va.x,vb.y-va.y)
        return CGVector(dx: (vb.x-va.x)/length, dy: (vb.y-va.y)/length)
    }
    override func azimuthAngle(in view: UIView?) -> CGFloat {
        let v = azimuthUnitVector(in: view); return atan2(v.dy,v.dx)
    }
}
@MainActor
private final class SamplesEvent: UIEvent {
    let contact: UITouch, samples: [UITouch]
    init(contact: UITouch, samples: [UITouch]) { self.contact = contact; self.samples = samples; super.init() }
    override var type: UIEvent.EventType { .touches }
    override var allTouches: Set<UITouch>? { [contact] }
    override func coalescedTouches(for touch: UITouch) -> [UITouch]? { samples }
    override func predictedTouches(for touch: UITouch) -> [UITouch]? { nil }
}
