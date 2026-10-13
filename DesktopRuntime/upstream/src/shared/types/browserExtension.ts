export type BrowserExtensionStatus = 'loaded' | 'disabled' | 'error'

export interface BrowserExtensionSummary {
  id: string | null
  name: string
  version: string
  path: string
  enabled: boolean
  status: BrowserExtensionStatus
  error: string | null
}
