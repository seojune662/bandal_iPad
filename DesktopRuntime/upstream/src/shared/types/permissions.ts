/**
 * [v0.41] OS privacy permissions the app depends on, for settings > 시스템 권한.
 * Only what a Bandal feature actually uses is listed; there is no microphone
 * or camera row because nothing records.
 */
export const SYSTEM_PERMISSIONS = [
  'screen',
  'accessibility',
  'notifications',
  'documents'
] as const
export type SystemPermissionId = (typeof SYSTEM_PERMISSIONS)[number]

export function isSystemPermissionId(value: unknown): value is SystemPermissionId {
  return SYSTEM_PERMISSIONS.some((id) => id === value)
}

/**
 * - granted / denied: the OS answered.
 * - not-determined: never asked; `request` will prompt.
 * - unknown: the OS does not report this permission (mac notifications, local
 *   network); the UI shows "직접 확인" with a settings deep link.
 * - not-applicable: this platform has no such permission (Windows screen).
 */
export type SystemPermissionState =
  | 'granted'
  | 'denied'
  | 'not-determined'
  | 'unknown'
  | 'not-applicable'

export interface SystemPermissionStatus {
  id: SystemPermissionId
  state: SystemPermissionState
  /** True when `permissions:request` can trigger an OS prompt right now. */
  canRequest: boolean
  /** True when there is an OS settings page to deep-link to. */
  canOpenSettings: boolean
}

export interface SystemPermissionsReport {
  platform: NodeJS.Platform
  permissions: SystemPermissionStatus[]
  checkedAt: string
}

/** What `app:diagnostics` wrote, for the privacy panel to reveal in Finder. */
export interface DiagnosticsBundle {
  path: string
  bytes: number
  /** Human-readable list of what went in, shown before the user shares it. */
  contents: string[]
}
