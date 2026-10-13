// browser feature (main process) — hardened `<webview>` policies (M3-F)
// plus the browsing-partition user agent (backlog §6.1).
export { hardenWindowWebviews, useSitePermissions } from './hardenWebviews'
export { fetchLinkForMaterials } from './linkDownload'
export { BROWSING_PARTITION } from './webviewPolicy'
export { createBrowserSessionStore } from './sessionStore'
export {
  attachDownloadHandler,
  downloadControls
} from './downloads'
export { createHistoryRepo } from './historyRepo'
export { createFaviconFetcher } from './favicon'
export { createPermissionsRepo } from './permissionsRepo'
export { parseBookmarkHtml, parsePasswordCsv } from './browserImport'
export { createBrowserExtensionManager } from './extensionManager'
