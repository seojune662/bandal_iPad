import XCTest
@testable import Bandal

@MainActor
final class WorkspacePersistenceTests: XCTestCase {
    func testNativeAppDoesNotPackageAWebApplicationShell() throws {
        let bundle = Bundle.main
        XCTAssertNil(bundle.url(forResource: "index", withExtension: "html", subdirectory: "Desktop"))
        XCTAssertNil(bundle.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
        XCTAssertNil(bundle.url(forResource:"backend",withExtension:"js",subdirectory:"NativeBackend"))
        XCTAssertEqual(bundle.infoDictionary?["UIDeviceFamily"] as? [Int], [2])
    }
    func testUnsafeFileNamesCannotEscapeApplicationStorage() {
        for name in ["../escape.pdf", "/tmp/file.pdf", "..", "", "folder\\file.pdf"] {
            let material = Material(courseID:"c",title:"t",fileName:name,revision:"v",kind:.pdf)
            XCTAssertFalse(material.hasSafePath)
        }
        XCTAssertFalse(RecordingMetadata(id:"not-a-uuid",courseID:"c",title:"t",fileName:"../../escape.wav").hasSafePath)
    }
}
