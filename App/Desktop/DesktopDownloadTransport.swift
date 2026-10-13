import Foundation

/// Bounded downloads for native service adapters. No browser cookie jar or
/// redirect forwarding; callers validate their own configured service origin.
enum DesktopDownloadTransport {
    static func request(_ request: URLRequest, maximumBytes: Int64) async throws -> (URL, HTTPURLResponse) {
        let policy = Policy(maximumBytes: maximumBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = max(30, request.timeoutInterval + 5)
        let session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse,
              let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        if (300..<400).contains(http.statusCode) { throw URLError(.redirectToNonExistentLocation) }
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("bandal-response-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: temporary, to: owned)
        return (owned, http)
    }
    private final class Policy: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let maximumBytes: Int64
        init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes { downloadTask.cancel() }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
    }
}
