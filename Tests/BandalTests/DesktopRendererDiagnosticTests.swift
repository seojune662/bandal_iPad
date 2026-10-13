import XCTest
@testable import Bandal

final class DesktopRendererDiagnosticTests: XCTestCase {
    func testNativeRevalidatesRendererMetadataWithoutPersistingRawContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-diagnostic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DesktopLog(root: root)
        log.recordRendererDiagnostic([
            "errorClass": "TypeError", "expression": "t.trim",
            "frames": ["index-AbCd12.js:414:872", "https://example.com/secret.js:1:2", "/Documents/private-note.md:1:2", "index.js:0:9"],
            "message": "private document content", "stack": "Authorization: Bearer credential"
        ])
        log.recordRendererDiagnostic(["errorClass": "private-user-name", "expression": "secret.trim", "frames": ["../private.js:1:2"]])
        await log.flush()
        let text = try String(contentsOf: root.appendingPathComponent("Logs/bandal.log"), encoding: .utf8)
        XCTAssertTrue(text.contains("renderer.error code=TypeError"))
        XCTAssertTrue(text.contains("renderer.expression code=t.trim"))
        XCTAssertTrue(text.contains("renderer.frame channel=0 code=index-AbCd12.js:414:872"))
        XCTAssertTrue(text.contains("renderer.error code=UnknownError"))
        for forbidden in ["private", "secret", "Authorization", "Bearer", "credential", "https", "Documents", "index.js:0"] { XCTAssertFalse(text.contains(forbidden)) }
    }
}
