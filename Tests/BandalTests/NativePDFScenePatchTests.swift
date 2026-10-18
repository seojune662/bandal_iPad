import XCTest
@testable import Bandal

final class NativePDFScenePatchTests: XCTestCase {
    private func row(_ id: String, updatedAt: String) -> [String: Any] { ["id": id, "page": 1, "kind": "ink", "updatedAt": updatedAt] }

    func testFirstPublishResetsAndSendsEveryRow() {
        let result = NativePDFScenePatch.patch(rows: [row("a", updatedAt: "1"), row("b", updatedAt: "1")], previous: nil, baseRevision: 7, revision: 8)
        XCTAssertEqual(result.patch["reset"] as? Bool, true)
        XCTAssertEqual(result.patch["baseRevision"] as? Int, 0)
        XCTAssertEqual(result.patch["revision"] as? Int, 8)
        XCTAssertEqual(result.patch["order"] as? [String], ["a", "b"])
        XCTAssertEqual((result.patch["upserts"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(result.fingerprints, ["a": "1", "b": "1"])
    }

    func testOnlyChangedVolatileAndFormerlyVolatileRowsTravelAgain() {
        let first = NativePDFScenePatch.patch(rows: [row("a", updatedAt: "1"), row("b", updatedAt: "1"), row("c", updatedAt: "1")],
                                              previous: nil, baseRevision: 0, revision: 1)
        // b moves (preview), c was edited elsewhere, a is untouched and stays home.
        let second = NativePDFScenePatch.patch(rows: [row("a", updatedAt: "1"), row("b", updatedAt: "1"), row("c", updatedAt: "2")],
                                               previous: first.fingerprints, baseRevision: 1, revision: 2, volatile: ["b"])
        XCTAssertEqual(second.patch["reset"] as? Bool, false)
        XCTAssertEqual(second.patch["baseRevision"] as? Int, 1)
        XCTAssertEqual((second.patch["upserts"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["b", "c"])
        XCTAssertEqual(second.patch["order"] as? [String], ["a", "b", "c"])
        // The gesture ends: b's canonical row must replace the preview even though updatedAt never changed.
        let third = NativePDFScenePatch.patch(rows: [row("a", updatedAt: "1"), row("b", updatedAt: "1")],
                                              previous: second.fingerprints, baseRevision: 2, revision: 3)
        XCTAssertEqual((third.patch["upserts"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["b"])
        XCTAssertEqual(third.patch["order"] as? [String], ["a", "b"])
    }
}
