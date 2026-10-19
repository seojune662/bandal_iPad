import Foundation
import CryptoKit

/// Mirrors `NativePDFRepository.checkBinding` for host fixtures: the revision is
/// the file's SHA-256 and the preserved original exists under PDFOriginals.
enum NativePDFTestBinding {
    static func respond(root: URL, file: URL, materialID: String = "fixture") throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent("PDFOriginals", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(digest + ".pdf")
        if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: .atomic) }
        return ["materialID": materialID, "documentRevision": digest]
    }
}
