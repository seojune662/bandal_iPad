import XCTest
@testable import Bandal

final class PublicArticleTests: XCTestCase {
    func testPrivateAndMappedAddressesNeverPassPublicBoundary() throws {
        for address in ["127.0.0.1", "10.0.0.2", "172.31.1.2", "192.168.0.1", "169.254.169.254", "100.64.1.1", "198.51.100.2", "::1", "fe80::1", "fd00::1", "2001:db8::1", "::ffff:127.0.0.1", "::ffff:7f00:1"] {
            XCTAssertFalse(PublicArticleClient.isPublicAddress(address), address)
        }
        for address in ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"] { XCTAssertTrue(PublicArticleClient.isPublicAddress(address)) }
        for url in ["http://localhost/", "https://host.local/", "https://user:password@example.org/", "https://example.org:8443/"] { XCTAssertThrowsError(try PublicArticleClient.validateURL(url)) }
    }
    func testRebindingAndRedirectToPrivateAddressCannotFetch() async throws {
        var client = PublicArticleClient()
        client.resolve = { host in host == "public.example" ? ["1.1.1.1"] : ["127.0.0.1"] }
        client.fetch = { url, address in
            XCTAssertEqual(url.host, "public.example"); XCTAssertEqual(address, "1.1.1.1")
            return Data("HTTP/1.1 302 Found\r\nLocation: http://private.example/\r\nContent-Length: 0\r\n\r\n".utf8)
        }
        do { _ = try await client.load("https://public.example/"); XCTFail("Private redirect succeeded") } catch {}
        client.resolve = { _ in ["1.1.1.1", "192.168.1.2"] }
        client.fetch = { _, _ in XCTFail("Mixed public/private DNS must not connect"); return Data() }
        do { _ = try await client.load("https://public.example/"); XCTFail("Mixed DNS succeeded") } catch {}
    }
    func testBoundedHTTPParserHandlesEarlyHintsChunksAndRejectsTruncation() throws {
        let bytes = Data("HTTP/1.1 103 Early Hints\r\nLink: </style.css>\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;ext=value\r\npedia\r\n0\r\n\r\n".utf8)
        let result = try PublicArticleClient.parse(bytes)
        XCTAssertEqual(result.status, 200); XCTAssertEqual(String(decoding: result.body, as: UTF8.self), "Wikipedia")
        XCTAssertThrowsError(try PublicArticleClient.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort".utf8)))
        XCTAssertThrowsError(try PublicArticleClient.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nff\r\nshort\r\n".utf8)))
    }
    @MainActor
    func testOriginalReadabilityParsesDetachedHTMLWithoutRunningPageScripts() async throws {
        let paragraph = String(repeating: "The student studies the science of flight and learns how the wings work. ", count: 8)
        let html = "<html lang='en'><head><title>Flight</title></head><body><article><h1>Flight</h1><p>\(paragraph)</p><p>\(paragraph)</p></article><script>document.body.textContent='ATTACK';fetch('http://127.0.0.1')</script></body></html>"
        var client = PublicArticleClient()
        client.resolve = { _ in ["1.1.1.1"] }
        client.fetch = { _, _ in Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)".utf8) }
        let service = DesktopArticleService(client: client)
        let result = try await service.extract(["url": "https://public.example/flight"])
        let raw = try XCTUnwrap(result["raw"] as? [String: Any])
        XCTAssertEqual(result["access"] as? String, "public")
        XCTAssertTrue((raw["paragraphs"] as? [String] ?? []).joined().contains("student studies"))
        XCTAssertFalse((raw["paragraphs"] as? [String] ?? []).joined().contains("ATTACK"))
    }
}
