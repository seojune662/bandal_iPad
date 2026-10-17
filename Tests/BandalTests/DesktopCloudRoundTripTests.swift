import XCTest
import BandalCore
import CryptoKit
import PDFKit
@testable import Bandal

/// Explicit opt-in integration check. The credential file is provisioned only
/// into the separate validation bundle; normal unit runs skip this test.
@MainActor
final class DesktopCloudRoundTripTests: XCTestCase {
    func testPhysicalCloudRoundTripWithIsolatedQAAccount() async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fixtureURL = documents.appendingPathComponent("bandal-cloud-qa.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else { throw XCTSkip("Explicit isolated cloud QA fixture is not installed") }
        guard Bundle.main.bundleIdentifier == "app.bandal.ipad.validation.Bandal" else { throw DesktopRuntimeError("Cloud QA requires the separate validation bundle") }
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        func field(_ key: String) throws -> String { try XCTUnwrap(value[key] as? String, "Missing QA fixture field \(key)") }
        let runID = try field("runID"), userID = try field("userID"), courseID = try field("courseID")
        guard [runID, userID, courseID].allSatisfy({ UUID(uuidString: $0) != nil }) else { throw DesktopRuntimeError("Invalid isolated QA identity") }
        let windowsInkID = value["windowsInkID"] as? String
        if let windowsInkID, UUID(uuidString: windowsInkID) == nil { throw DesktopRuntimeError("Invalid Windows QA ink identity") }
        let projectURL = try field("projectURL"), publicKey = try field("publishableKey")
        let session = try XCTUnwrap(value["session"] as? [String: Any]), user = try XCTUnwrap(session["user"] as? [String: Any])
        guard user["id"] as? String == userID, (user["user_metadata"] as? [String: Any])?["validationRun"] as? String == runID,
              (user["user_metadata"] as? [String: Any])?["purpose"] as? String == "Bandal isolated sync validation",
              (user["email"] as? String)?.hasSuffix("@example.invalid") == true else { throw DesktopRuntimeError("The fixture must name its own QA account") }
        let url = try XCTUnwrap(URL(string: projectURL))
        guard projectURL == "https://ukacrkcwiqafwpppshxb.supabase.co" else { throw DesktopRuntimeError("Invalid QA project URL") }
        let expiry = try XCTUnwrap(session["expires_at"] as? Double)
        guard expiry > Date().timeIntervalSince1970, expiry <= Date().timeIntervalSince1970 + 3660 else { throw DesktopRuntimeError("QA session must be short-lived and unexpired") }
        var verifyRequest = URLRequest(url: url.appendingPathComponent("auth/v1/user"))
        verifyRequest.setValue(publicKey, forHTTPHeaderField: "apikey")
        verifyRequest.setValue("Bearer " + (try XCTUnwrap(session["access_token"] as? String)), forHTTPHeaderField: "Authorization")
        let (verifiedBytes, verifiedResponse) = try await URLSession.shared.data(for: verifyRequest)
        guard (verifiedResponse as? HTTPURLResponse)?.statusCode == 200,
              let verifiedUser = try JSONSerialization.jsonObject(with: verifiedBytes) as? [String: Any], verifiedUser["id"] as? String == userID,
              (verifiedUser["user_metadata"] as? [String: Any])?["validationRun"] as? String == runID,
              (verifiedUser["user_metadata"] as? [String: Any])?["purpose"] as? String == "Bandal isolated sync validation",
              (verifiedUser["email"] as? String)?.hasSuffix("@example.invalid") == true else { throw DesktopRuntimeError("Server did not confirm the isolated QA identity") }
        let credential = String(decoding: try JSONSerialization.data(withJSONObject: session), as: UTF8.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bandal-cloud-qa-" + runID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The short-lived QA token is never written to Keychain. Always remove
        // its device transfer file, including when a network assertion fails.
        let runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        try await runtime.start()
        var accountEnvironment = DesktopAccountEnvironment()
        accountEnvironment.configuration = { (projectURL, publicKey) }
        accountEnvironment.readCredential = { credential }
        accountEnvironment.writeCredential = { _ in }
        let account = DesktopAccountService(root: root, environment: accountEnvironment)
        let state = try await account.handle(channel: "auth:getState", request: [:]) as? [String: Any]
        if (state?["localAccess"] as? [String: Any])?["requiresBindingConfirmation"] as? Bool == true {
            _ = try await account.handle(channel: "auth:confirmProfile", request: ["userID": userID])
        }
        let store = try RecordStore(url: root.appendingPathComponent("CommonSync/bandal.sqlite"))
        try await store.setPreference("syncEnabled", value: "true")
        let sync = try DesktopSyncService(runtime: runtime, account: account)
        try await sync.synchronizeNow(force: true)
        let coursesValue = try await runtime.invoke("courses:list")
        let courses = try XCTUnwrap(coursesValue as? [[String: Any]])
        XCTAssertEqual(courses.count, 1)
        XCTAssertEqual(courses.first?["id"] as? String, courseID)
        let notePath = try field("notePath"), pdfPath = try field("pdfPath")
        let expectedDesktop = try field("expectedDesktopMarkdown"), expectedNative = try field("expectedNativeMarkdown")
        let note = try await runtime.readMaterial(courseID: courseID, relativePath: notePath)
        XCTAssertEqual(String(decoding: note, as: UTF8.self), expectedDesktop)
        let originalPDF = try await runtime.readMaterial(courseID: courseID, relativePath: pdfPath)
        let originalSHA = SHA256.hash(data: originalPDF).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(originalSHA, try field("pdfSHA")); XCTAssertEqual(PDFDocument(data: originalPDF)?.pageCount, 2)
        let rowsValue = try await runtime.invoke("drawings:listForFile", request: ["courseId": courseID, "relPath": pdfPath, "documentRevision": originalSHA])
        let rows = try XCTUnwrap(rowsValue as? [[String: Any]])
        let desktopInkID = try field("desktopInkID")
        XCTAssertEqual(rows.first { $0["id"] as? String == desktopInkID }?["page"] as? Int, 1)
        if let windowsInkID {
            let windowsInk = try XCTUnwrap(rows.first { $0["id"] as? String == windowsInkID })
            XCTAssertEqual(windowsInk["page"] as? Int, 1)
            XCTAssertEqual((windowsInk["data"] as? [String: Any])?["inkVersion"] as? Int, 5)
        }
        _ = try await runtime.invoke("notes:write", request: ["courseId": courseID, "relPath": notePath, "markdown": expectedNative])
        _ = try await runtime.invoke("pdf:restructure", request: ["courseId": courseID, "relPath": pdfPath, "expectedRevision": originalSHA, "pages": [["source": 2], ["source": 1], ["source": NSNull()]]])
        let changedPDF = try await runtime.readMaterial(courseID: courseID, relativePath: pdfPath)
        let changedSHA = SHA256.hash(data: changedPDF).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(changedSHA, originalSHA); XCTAssertEqual(PDFDocument(data: changedPDF)?.pageCount, 3)
        let createdValue = try await runtime.invoke("drawings:create", request: ["courseId": courseID, "relPath": pdfPath, "documentRevision": changedSHA, "page": 3, "kind": "ink", "data": ["inkVersion": 5, "points": [["x": 0.2, "y": 0.3, "p": 0.6, "t": 0], ["x": 0.5, "y": 0.7, "p": 0.8, "t": 10]]], "style": ["color": "blue", "width": 0.004, "opacity": 1]])
        let created = try XCTUnwrap(createdValue as? [String: Any])
        let nativeInkID = try XCTUnwrap(created["id"] as? String)
        try await sync.synchronizeNow(force: true)
        let conflicts = try await sync.conflictSummaries(); XCTAssertEqual(conflicts.count, 0)
        let finalRowsValue = try await runtime.invoke("drawings:listForFile", request: ["courseId": courseID, "relPath": pdfPath, "documentRevision": changedSHA])
        let finalRows = try XCTUnwrap(finalRowsValue as? [[String: Any]])
        XCTAssertEqual(finalRows.first { $0["id"] as? String == desktopInkID }?["page"] as? Int, 2)
        XCTAssertEqual(finalRows.first { $0["id"] as? String == nativeInkID }?["page"] as? Int, 3)
        if let windowsInkID { XCTAssertEqual(finalRows.first { $0["id"] as? String == windowsInkID }?["page"] as? Int, 2) }
        var result: [String: Any] = ["runID": runID, "courseID": courseID, "pdfSHA": changedSHA, "nativeInkID": nativeInkID, "expectedNativeMarkdown": expectedNative, "pdfPageCount": 3, "conflicts": conflicts.count, "nativeStatus": try await sync.status()]
        if let windowsInkID { result["windowsInkID"] = windowsInkID }
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: documents.appendingPathComponent("bandal-cloud-qa-result.json"), options: .atomic)
    }
}
