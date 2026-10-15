import Foundation
import WebKit

/// Rebuildable display data only. This deliberately names the cache directory
/// rather than walking Documents: originals, journals and browser state live
/// beside it and must survive a rendering reset.
enum DesktopRenderCacheReset {
    static func removePDFCopies(root: URL, fileManager: FileManager = .default) throws -> Bool {
        let cache = root.appendingPathComponent("NativePDFCache", isDirectory: true)
        guard fileManager.fileExists(atPath: cache.path) ||
                (try? cache.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return false }
        // removeItem unlinks a symbolic link; it never traverses its target.
        try fileManager.removeItem(at: cache)
        return true
    }

    @MainActor
    static func clearWebResources(in store: WKWebsiteDataStore) async {
        URLCache.shared.removeAllCachedResponses()
        await store.removeData(ofTypes: [WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache], modifiedSince: .distantPast)
    }
}
