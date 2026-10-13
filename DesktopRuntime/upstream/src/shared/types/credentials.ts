/**
 * Saved site logins for the in-app browser.
 *
 * Session-cookie persistence already keeps a student signed in for as long as
 * the portal's own session lasts (see main/features/browser/sessionStore.ts).
 * This is the other half: the portals that expire nightly, where the student
 * retypes a password every single morning.
 *
 * Non-negotiables, enforced in main rather than trusted to the UI:
 *  - Secrets live only inside an OS-keychain-encrypted blob. If the platform
 *    cannot encrypt, the feature turns itself OFF — there is no plaintext
 *    fallback, because a plaintext password file is worse than retyping.
 *  - Bound to an exact https origin. A saved credential is never offered to a
 *    different origin, and never over http.
 *  - Filling is not submitting. Auto-submit is opt-in per site, because a
 *    wrong stored password submitted on every visit locks the account out of
 *    a university portal, and that is a very expensive way to fail.
 *  - Passwords never cross the IPC boundary back to the renderer, never enter
 *    a log line, and never appear in an error message.
 */

export interface SavedLoginSummary {
  /** Stable account identity within its browser profile. */
  id: string
  /** `https://portal.example.ac.kr` — scheme + host, no path. */
  origin: string
  username: string
  /** Submit the form after filling. Defaults to false. */
  autoSubmit: boolean
  updatedAt: string
}

export interface SaveLoginInput {
  /** Required for metadata edits; never changes the account's origin. */
  id?: string
  origin: string
  username: string
  /**
   * Never returned, and in practice never sent either: the browser's save
   * button goes through `credentials:capture`, which reads the typed password
   * inside main. The settings window sends `''`, meaning "keep the stored
   * password, change only the metadata".
   */
  password: string
  autoSubmit?: boolean
}

export interface CredentialsImportResult {
  imported: number
  skipped: number
  cancelled: boolean
}

/**
 * Name of the function the browser tab installs in the guest page, which
 * returns what the student typed into a login form. Main calls it directly so
 * the password goes straight from the page into the encrypted file, without
 * passing through the renderer.
 */
export const LOGIN_CAPTURE_GLOBAL = '__bandalCaptureUserEnteredLoginV1__'

/** Both the main-only secret and its renderer prompt expire together. */
export const STAGED_LOGIN_TTL_MS = 60_000

export interface FillLoginResult {
  /** False when nothing is stored for the origin, or encryption is off. */
  filled: boolean
  /** True only when the site is configured to submit automatically. */
  submitted: boolean
}

export type CredentialsAvailability =
  | { state: 'ready' }
  /** No OS keychain — the feature is off rather than insecure. */
  | { state: 'unavailable'; reason: string }
