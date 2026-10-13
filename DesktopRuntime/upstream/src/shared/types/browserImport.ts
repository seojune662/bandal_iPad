/** Only metadata crosses IPC. Source paths, cookies and passwords stay in main. */
export type BrowserImportBrowser = 'chrome' | 'edge' | 'firefox' | 'safari' | 'file'
export type BrowserImportItem = 'bookmarks' | 'history' | 'cookies' | 'passwords'
export type BrowserImportConflict = 'keep' | 'replace'
export type BrowserImportFileKind = 'passwords-csv' | 'bookmarks-html' | 'safari-zip'

export interface BrowserImportCapability {
  supported: boolean
  description: string
}

export interface BrowserImportSource {
  id: string
  browser: BrowserImportBrowser
  name: string
  profileName: string
  kind: 'profile' | BrowserImportFileKind
  capabilities: Record<BrowserImportItem, BrowserImportCapability>
}

export interface BrowserImportRequest {
  sourceId: string
  targetProfileId: string
  items: BrowserImportItem[]
  conflict: BrowserImportConflict
}

export interface BrowserImportCounts {
  imported: number
  kept: number
  unsupported: number
  failed: number
}

export interface BrowserImportJob {
  id: string
  sourceId: string
  targetProfileId: string
  state: 'running' | 'completed' | 'cancelled' | 'failed'
  currentItem: BrowserImportItem | null
  processed: number
  /** A total is known after the source snapshot has been read. */
  total: number | null
  results: Record<BrowserImportItem, BrowserImportCounts>
  /** Localized, sanitized messages. Never source errors or secret values. */
  messages: string[]
}
