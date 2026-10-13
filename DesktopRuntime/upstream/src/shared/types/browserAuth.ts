export type BrowserAuthReason = 'insecure-browser' | 'disallowed-useragent' | 'supervised-account'

/** A provider refusal observed in one browser document; never an account identity. */
export interface BrowserAuthStatus {
  status: 'blocked' | 'clear'
  documentId: string
  reason?: BrowserAuthReason
  restartUrl?: string
  origin: string
  path: string
}

/** A fresh service entry point with the provider’s observed refusal reason. */
export interface BrowserAuthFallback {
  restartUrl: string
  reason?: BrowserAuthReason
}
