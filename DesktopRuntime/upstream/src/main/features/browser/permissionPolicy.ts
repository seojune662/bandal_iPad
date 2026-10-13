/**
 * What a site may do, and whether we ask first.
 *
 * The old policy was one allowlist containing `fullscreen` and nothing else,
 * wired to BOTH `setPermissionRequestHandler` and `setPermissionCheckHandler`.
 * That is a defensible default for an app that embeds a page it does not
 * trust — and completely wrong for a browser a student uses as their browser.
 * It silently broke:
 *
 *   - `navigator.clipboard.writeText` → every "복사" button on an LMS
 *   - the Storage Access API → SSO flows Safari's own prompt would satisfy
 *   - pointer lock → nothing in a study app, but it costs nothing
 *   - notifications, location, camera/mic → 화상 수업, 도서관 좌석 지도
 *
 * Three tiers, because "ask" is not free. Every prompt a student cannot act
 * on meaningfully is a prompt that teaches them to click 허용, so the ones
 * with no plausible academic use are refused outright rather than asked.
 */

export type PermissionTier = 'grant' | 'ask' | 'deny'

/**
 * Granted without asking: observable only while the student is already
 * looking at the page, and reversible by navigating away.
 */
const AUTO_GRANT: ReadonlySet<string> = new Set([
  'fullscreen',
  // Chrome auto-grants this on a user gesture. Refusing it is what makes an
  // LMS "복사" button do nothing at all.
  'clipboard-sanitized-write',
  'pointerLock',
  // Safari satisfies these with its own prompt; refusing outright breaks SSO
  // that runs inside an iframe.
  'storage-access',
  'top-level-storage-access',
  // Chromium asks the embedder before letting a page keep working offline.
  'background-sync'
])

/** Worth a prompt: a real capability with a real academic use. */
const ASK: ReadonlySet<string> = new Set([
  'notifications',
  'geolocation',
  'media',
  'clipboard-read',
  'display-capture',
  'midi',
  'midiSysex',
  'window-management'
])

/**
 * Never, and never asked about either.
 *
 * Physical device access has no academic use we can name, and `openExternal`
 * has its own dedicated flow (externalScheme.ts) that shows the URL — routing
 * it through a generic yes/no would hide exactly the detail that matters.
 */
const HARD_DENY: ReadonlySet<string> = new Set([
  // Stock Electron ships no Widevine CDM, so a granted `mediaKeySystem` still
  // cannot play protected video. Asking would produce the worst failure shape
  // there is: a prompt the student answers and nothing happens. Playing DRM
  // lecture video needs the castlabs Electron fork, which is a build and
  // signing decision, not a permission one.
  'mediaKeySystem',
  'hid',
  'serial',
  'usb',
  'fileSystem',
  'idle-detection',
  'openExternal',
  'speaker-selection'
])

export function permissionTier(permission: string): PermissionTier {
  if (AUTO_GRANT.has(permission)) return 'grant'
  if (ASK.has(permission)) return 'ask'
  if (HARD_DENY.has(permission)) return 'deny'
  // Unknown permissions are refused. Chromium adds them faster than we can
  // review them, and a default of "ask" would put a question in front of the
  // student that neither of us understands.
  return 'deny'
}

/** Korean label for the prompt. Unknown permissions never reach it. */
export function permissionLabel(permission: string): string {
  switch (permission) {
    case 'notifications':
      return '알림 보내기'
    case 'geolocation':
      return '현재 위치 확인'
    case 'media':
      return '카메라와 마이크 사용'
    case 'clipboard-read':
      return '클립보드 읽기'
    case 'display-capture':
      return '화면 공유'
    case 'midi':
    case 'midiSysex':
      return 'MIDI 기기 사용'
    case 'window-management':
      return '창 위치 관리'
    default:
      return permission
  }
}
