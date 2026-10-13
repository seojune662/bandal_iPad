import XCTest
@testable import Bandal

final class DesktopDictionaryTests: XCTestCase {
    func testExactDesktopNormalizationAndBundledAliasesPreserveAttribution() async throws {
        XCTAssertEqual(DesktopDictionaryService.key("  “Ｒｕｎｎｉｎｇ!” "), "running")
        XCTAssertEqual(DesktopDictionaryService.key("runner’s"), "runner's")
        XCTAssertNil(DesktopDictionaryService.key("<script>"))
        let service = DesktopDictionaryService()
        let result = await service.lookup("Running")
        XCTAssertEqual(result["status"] as? String, "found")
        let entries = try XCTUnwrap(result["entries"] as? [[String: Any]])
        XCTAssertTrue(entries.contains { $0["headword"] as? String == "run" })
        let source = try XCTUnwrap(entries.first?["source"] as? [String: Any])
        XCTAssertEqual(source["datasetVersion"] as? String, "koreader-dicts-en-ko-v1.2.0")
        XCTAssertNotNil(source["url"] as? String)
    }
    func testMissingResourceReportsUnavailableWithoutInventingMeaning() async {
        let service = DesktopDictionaryService(directory: URL(fileURLWithPath: "/nonexistent-dictionary"))
        let result = await service.lookup("study")
        XCTAssertEqual(result["status"] as? String, "unavailable")
        XCTAssertEqual((result["entries"] as? [Any])?.count, 0)
    }
}
