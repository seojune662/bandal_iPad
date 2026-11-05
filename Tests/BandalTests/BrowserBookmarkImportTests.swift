import XCTest
@testable import Bandal

final class BrowserBookmarkImportTests: XCTestCase {
    func testChromeExportFlattensFoldersAndKeepsOnlyWebLinks() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
          <DT><H3 ADD_DATE="1">북마크바</H3>
          <DL><p>
            <DT><A HREF="https://myetl.snu.ac.kr/" ADD_DATE="1" ICON="data:image/png;base64,AA">eTL &amp; 강의</A>
            <DT><A HREF="javascript:alert(1)">bookmarklet</A>
            <DT><A HREF="https://myetl.snu.ac.kr/">duplicate</A>
          </DL><p>
          <DT><a href="http://example.com/a?x=1&amp;y=2"></a>
          <DT><A HREF="file:///etc/passwd">local</A>
        </DL><p>
        """
        XCTAssertEqual(try BrowserBookmarkImport.links(html), [
            .init(title: "eTL & 강의", url: "https://myetl.snu.ac.kr/"),
            .init(title: "example.com", url: "http://example.com/a?x=1&y=2"),
        ])
    }

    func testCapsTheNumberOfImportedLinks() throws {
        let html = (0..<2_500).map { "<DT><A HREF=\"https://site.test/\($0)\">\($0)</A>" }.joined(separator: "\n")
        XCTAssertEqual(try BrowserBookmarkImport.links(html).count, BrowserBookmarkImport.maxLinks)
    }

    @MainActor func testPasswordCSVAcceptsSafariAndPasswordsAppHeaders() throws {
        let rows = try DesktopCredentialsService.csvRows("Title,URL,Username,Password,Notes,OTPAuth\nSNU,https://myetl.snu.ac.kr/login,student,pw,,\n")
        let header = rows[0].map { $0.lowercased() }
        XCTAssertNotNil(header.firstIndex(of: "url")); XCTAssertNotNil(header.firstIndex(of: "username")); XCTAssertNotNil(header.firstIndex(of: "password"))
        XCTAssertEqual(try DesktopCredentialsService.origin(rows[1][1]), "https://myetl.snu.ac.kr")
    }
}
