/**
 * Pages that want to launch a program.
 *
 * Korean university and government sites routinely hand off to a local helper
 * — the OZ report viewer, WIZVERA's certificate bridge, nProtect, a print
 * agent. Until now every one of those was a silent `event.preventDefault()`
 * with no output anywhere, so the page simply stopped and the student had no
 * way to learn why. Safari asks; so do we.
 *
 * Asking is not the same as trusting. Two gates run before the question:
 *
 *  1. **Shape.** A launcher URL is short and boring. Length and control
 *     characters are how `ms-msdt:` and `search-ms:` were weaponised, and a
 *     newline or a quote in the URL is also how you spoof the dialog body.
 *  2. **Name.** A blocklist of schemes that either execute code, reach the
 *     local filesystem, drive the browser itself, or leak credentials to a
 *     network share. Those are refused outright — never offered.
 *
 * There is deliberately no allowlist fast-path and no "always allow" memory:
 * launching a program should never be one click, and a remembered approval is
 * an attack surface that grows quietly.
 */

/** Long enough for any real launcher, short enough to defuse the LPE payloads. */
export const EXTERNAL_SCHEME_MAX_URL = 2048
/** How much of the URL the dialog shows before it stops being readable. */
const DISPLAY_MAX = 300

const SCHEME_SHAPE = /^[a-z][a-z0-9+.-]{1,31}$/
// Anything that is not printable ASCII plus the quoting characters that would
// let a URL forge extra lines in the dialog or extra arguments to a handler.
const UNSAFE_CHARS = /[\x00-\x20\x7f"'`\\]/

const BLOCKED_SCHEMES: ReadonlySet<string> = new Set([
  // local file access / code execution
  'file', 'javascript', 'vbscript', 'data', 'jar', 'res', 'mhtml', 'shell',
  'view-source', 'filesystem',
  // the browser's own internals
  'about', 'blob', 'chrome', 'chrome-extension', 'chrome-search',
  'chrome-untrusted', 'devtools', 'edge',
  // Windows local-privilege-escalation / RCE families
  'ms-msdt', 'search-ms', 'search', 'ms-officecmd', 'ms-appinstaller',
  'ms-cxh', 'ms-cxh-full', 'ms-settings', 'ms-windows-store',
  'ms-availablenetworks', 'ms-word', 'ms-excel', 'ms-powerpoint', 'ms-visio',
  'ms-access', 'ms-publisher', 'ms-infopath', 'ms-spd', 'ms-project',
  'ie.http', 'ie.https',
  // network file systems — a silent credential leak / SMB relay
  'smb', 'nfs', 'afp', 'ftp', 'sftp', 'dav', 'davs',
  // our own deep links: web content must never be able to drive the app
  'bandal'
])

/**
 * Schemes every OS already owns and every browser opens with at most a
 * one-line notice. Warning about 교수님 이메일 링크 in the same red-toned box
 * used for an unknown installer teaches the student to ignore the box.
 */
const EVERYDAY_SCHEMES: ReadonlySet<string> = new Set([
  'mailto',
  'tel',
  'sms',
  'facetime',
  'facetime-audio',
  'webcal'
])

export type ExternalSchemeVerdict =
  | { kind: 'blocked'; reason: 'scheme' | 'shape' | 'length' }
  /** An everyday handoff: confirm once, quietly. */
  | { kind: 'everyday'; scheme: string }
  | { kind: 'ask'; scheme: string }

export function classifyExternalScheme(url: string): ExternalSchemeVerdict {
  if (url.length > EXTERNAL_SCHEME_MAX_URL) {
    return { kind: 'blocked', reason: 'length' }
  }
  if (UNSAFE_CHARS.test(url)) return { kind: 'blocked', reason: 'shape' }
  const separator = url.indexOf(':')
  if (separator <= 0) return { kind: 'blocked', reason: 'shape' }
  const scheme = url.slice(0, separator).toLowerCase()
  if (!SCHEME_SHAPE.test(scheme)) return { kind: 'blocked', reason: 'shape' }
  if (scheme === 'http' || scheme === 'https') {
    // Not an external scheme at all; the caller routed this wrongly.
    return { kind: 'blocked', reason: 'scheme' }
  }
  if (BLOCKED_SCHEMES.has(scheme)) return { kind: 'blocked', reason: 'scheme' }
  if (EVERYDAY_SCHEMES.has(scheme)) return { kind: 'everyday', scheme }
  return { kind: 'ask', scheme }
}

/** The URL as the dialog shows it: trimmed to something a person can read. */
export function externalSchemeDisplay(url: string): string {
  const cleaned = url.replace(/[\x00-\x1f\x7f]/g, '')
  return cleaned.length > DISPLAY_MAX
    ? `${cleaned.slice(0, DISPLAY_MAX)}…`
    : cleaned
}

/**
 * Which site asked — origin only.
 *
 * The path is attacker-controlled and can be written to read like prose
 * ("…/이것은-안전한-요청입니다"), so it never reaches the dialog.
 */
export function requestingOriginOf(committedUrl: string): string {
  try {
    return new URL(committedUrl).origin
  } catch {
    return '알 수 없는 사이트'
  }
}
