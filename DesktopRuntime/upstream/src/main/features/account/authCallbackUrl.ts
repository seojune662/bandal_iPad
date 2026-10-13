/**
 * `bandal://auth/callback` parsing — pure, Electron-free, dependency-free.
 *
 * This is the ONLY place allowed to look inside a deep-link URL. Everything
 * else (main/index.ts, authService) receives a classified result, which is why
 * the rest of the code can never accidentally log the raw URL:
 *
 * ⚠ THE URL CONTAINS THE AUTHORIZATION CODE. It is a single-use credential
 *   that can be exchanged for a session. It must never reach a log, a crash
 *   report or an error message. `describeAuthCallback()` exists so callers can
 *   log *something* — scheme + path, never the query.
 *
 * Classification, and why each case exists (all four are reachable in
 * practice):
 *  - `code`      → the happy path.
 *  - `cancelled` → the student closed the Google consent screen. That is a
 *                  normal outcome, NOT an error: the UI goes back to the login
 *                  card, it does not show a failure.
 *  - `failed`    → provider error, or a callback we refuse to guess at
 *                  (no code / two different codes / a code with junk in it).
 *                  Surfacing this matters: without it, a malformed callback
 *                  would leave the UI stuck on "signing-in" forever.
 *  - `ignored`   → not ours, or a future `bandal://` route. Silently dropped.
 */

/** Registered with the OS; also the Supabase dashboard Redirect URL. */
export const AUTH_CALLBACK_URL = 'bandal://auth/callback'

export const BANDAL_SCHEME = 'bandal'

/** `host + path` of the callback, after normalization. */
const CALLBACK_TARGET = 'auth/callback'

/**
 * Permissive on purpose — the exact code alphabet is the provider's business,
 * not ours. This rejects whitespace, control characters and quotes (i.e. junk
 * and injection attempts) while accepting every base64url / UUID shape.
 */
const CODE_SHAPE = /^[A-Za-z0-9._~+/=-]{1,2048}$/

/** Provider error identifiers are short tokens; anything else is untrusted. */
const ERROR_TOKEN_SHAPE = /^[A-Za-z0-9_-]{1,64}$/

export type AuthCallbackFailure =
  /** Provider said no (`error=…`), and it was not a user cancellation. */
  | 'provider'
  /** An auth callback with neither `code` nor `error`. */
  | 'missing_code'
  /** Two *different* `code` params — ambiguous, never guessed at. */
  | 'ambiguous_code'
  /** A `code` containing characters no authorization code has. */
  | 'malformed_code'

export type AuthCallbackIgnored =
  /** A different app's scheme, or no scheme at all. */
  | 'not-bandal'
  /** `bandal://` but some other route (room for future deep links). */
  | 'not-auth-callback'
  /** Not a URL at all. */
  | 'unparseable'

export type AuthCallback =
  | { kind: 'code'; code: string }
  | { kind: 'cancelled' }
  | { kind: 'failed'; reason: AuthCallbackFailure; detail: string | null }
  | { kind: 'ignored'; why: AuthCallbackIgnored }

function parseUrl(raw: string): URL | null {
  if (typeof raw !== 'string' || raw.trim().length === 0) return null
  try {
    return new URL(raw.trim())
  } catch {
    return null
  }
}

/**
 * `bandal://auth/callback`, `bandal://auth/callback/` and `bandal:auth/callback`
 * all normalize to `auth/callback`. macOS and the single-instance argv path do
 * not agree on the trailing slash, and neither form is worth failing over.
 */
function targetOf(url: URL): string {
  const path = url.pathname.replace(/\/+$/, '')
  return `${url.host}${path}`.replace(/^\/+/, '').toLowerCase()
}

function errorToken(value: string | null): string | null {
  if (value === null) return null
  return ERROR_TOKEN_SHAPE.test(value) ? value.toLowerCase() : 'unknown'
}

/** True for any URL this app should route, without inspecting the query. */
export function isBandalDeepLink(raw: string): boolean {
  const url = parseUrl(raw)
  return url !== null && url.protocol === `${BANDAL_SCHEME}:`
}

/** True only for the OAuth callback route — used to avoid waking the runtime. */
export function isAuthCallbackUrl(raw: string): boolean {
  const url = parseUrl(raw)
  if (url === null || url.protocol !== `${BANDAL_SCHEME}:`) return false
  return targetOf(url) === CALLBACK_TARGET
}

export function parseAuthCallbackUrl(raw: string): AuthCallback {
  const url = parseUrl(raw)
  if (url === null) return { kind: 'ignored', why: 'unparseable' }
  if (url.protocol !== `${BANDAL_SCHEME}:`) {
    return { kind: 'ignored', why: 'not-bandal' }
  }
  if (targetOf(url) !== CALLBACK_TARGET) {
    return { kind: 'ignored', why: 'not-auth-callback' }
  }

  // Error first: a callback carrying both is a failure, not a sign-in.
  const error = errorToken(url.searchParams.get('error'))
  const errorCode = errorToken(url.searchParams.get('error_code'))
  if (error !== null || errorCode !== null) {
    const cancelled =
      error === 'access_denied' ||
      (errorCode !== null && errorCode.includes('cancel'))
    if (cancelled) return { kind: 'cancelled' }
    return { kind: 'failed', reason: 'provider', detail: errorCode ?? error }
  }

  const codes = url.searchParams.getAll('code')
  if (codes.length === 0) {
    return { kind: 'failed', reason: 'missing_code', detail: null }
  }
  // Duplicates are only safe when they agree. Two different codes means
  // someone (or something) appended one — picking either is a coin flip on a
  // credential, so we refuse.
  const first = codes[0] ?? ''
  if (codes.some((value) => value !== first)) {
    return { kind: 'failed', reason: 'ambiguous_code', detail: null }
  }
  if (!CODE_SHAPE.test(first)) {
    return { kind: 'failed', reason: 'malformed_code', detail: null }
  }
  return { kind: 'code', code: first }
}

/**
 * A log-safe rendering of a deep link: scheme + path, query DROPPED.
 * Never build a log line from the raw URL — see the header note.
 */
export function describeAuthCallback(raw: string): string {
  const url = parseUrl(raw)
  if (url === null) return '<unparseable>'
  const path = url.pathname.replace(/\/+$/, '')
  return `${url.protocol}//${url.host}${path}`
}

/**
 * Pulls a `bandal://` URL out of a process argv vector.
 *
 * Windows/Linux deliver the deep link this way (cold start argv, and the
 * `second-instance` argv on relaunch); macOS uses `open-url` instead. Scanning
 * argv on macOS is harmless and keeps the single-instance path uniform.
 */
export function findDeepLinkArg(argv: readonly string[]): string | null {
  for (const arg of argv) {
    if (typeof arg === 'string' && isBandalDeepLink(arg)) return arg
  }
  return null
}
