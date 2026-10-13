/**
 * Auto-update state shared between main and renderer.
 *
 * Modelled as a discriminated union rather than a bag of booleans so the UI
 * cannot render impossible combinations (downloading *and* idle, "ready" with
 * no version to restart into).
 */

export type UpdateStatus =
  /**
   * No update feed for this build: `pnpm dev`, or a copy that was never
   * packaged. The UI hides the update controls entirely rather than offering a
   * button that can only fail.
   */
  | { phase: 'unsupported'; currentVersion: string }
  /** Up to date as of the last check. */
  | { phase: 'idle'; currentVersion: string; lastCheckedAt: number | null }
  | { phase: 'checking'; currentVersion: string }
  /** A newer release exists; nothing downloaded yet (autoDownload is off). */
  | { phase: 'available'; currentVersion: string; version: string; notes: string | null }
  | { phase: 'downloading'; currentVersion: string; version: string; percent: number }
  /** Downloaded and staged. Restarting applies it. */
  | { phase: 'ready'; currentVersion: string; version: string; restartCancelled?: true }
  /**
   * The check or download failed. `message` is already user-facing Korean —
   * the raw electron-updater error is logged in main, not surfaced here.
   */
  | { phase: 'error'; currentVersion: string; message: string }
