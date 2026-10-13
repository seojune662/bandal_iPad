/**
 * [M3-F] Pure webview hardening policy (no electron imports — unit-testable).
 *
 * Recipe source: docs/orca-analysis.md §1 (Orca's hardened-<webview> approach,
 * re-implemented here — no verbatim Orca code):
 *  - fail-closed `will-attach-webview`: partition allowlist + forced
 *    sandbox/contextIsolation/webSecurity + preload removal
 *  - navigation guard shared by `will-navigate` AND `will-redirect`
 *  - a tiered permission policy (./permissionPolicy.ts)
 *  - `setWindowOpenHandler` → preserve Chromium-created browsing contexts
 *
 * The wiring against real electron objects lives in ./hardenWebviews.ts.
 */

import { classifyExternalScheme } from './externalScheme'
import { isEmbeddedAuthProviderUrl } from '../../../shared/browserAuth'
import {
  chordFromKeyboardEvent,
  SHORTCUT_SPECS,
  type ShortcutActionId
} from '../../../shared/keymap'
import type { ShortcutPassthrough } from '../../../shared/ipc/events'
import type { ShortcutPriority } from '../../../shared/types/settings'

/** Normal browsing persists; private browsing lives only for this app run. */
export const BROWSING_PARTITION = 'persist:browsing'
export const PRIVATE_BROWSING_PARTITION = 'bandal-private'
export const BROWSING_PARTITIONS = [
  BROWSING_PARTITION,
  PRIVATE_BROWSING_PARTITION
] as const

function isHttpUrl(url: string): boolean {
  try {
    const parsed = new URL(url)
    return parsed.protocol === 'https:' || parsed.protocol === 'http:'
  } catch {
    return false
  }
}

/**
 * Fail-closed attach check: only guests declaring the browsing partition and
 * an http(s) (or about:blank) src may attach. Anything else — file://,
 * custom schemes, missing/foreign partitions — is denied.
 */
export function isAllowedAttach(params: {
  src?: unknown
  partition?: unknown
}): boolean {
  const src = typeof params.src === 'string' ? params.src : ''
  const partition = typeof params.partition === 'string' ? params.partition : ''
  if (!(BROWSING_PARTITIONS as readonly string[]).includes(partition)) return false
  return src === 'about:blank' || isHttpUrl(src)
}

/**
 * Guard for `will-navigate` and `will-redirect`: http(s) and about:blank
 * only. http(s)-origin blob: URLs stay allowed (bot-check challenges load
 * resources through them); `file:` and every other scheme is denied.
 */
export function isNavigationAllowed(url: string): boolean {
  if (url === 'about:blank') return true
  if (url.startsWith('blob:https://') || url.startsWith('blob:http://')) {
    return true
  }
  return isHttpUrl(url)
}

/** window.open target worth forwarding to the renderer as a new tab. */
export function popupForwardUrl(url: string): string | null {
  return isHttpUrl(url) ? url : null
}

/** Only an explicit refusal from a known provider offers an external fallback. */
export const isBlockedEmbeddedAuthUrl = isEmbeddedAuthProviderUrl

/**
 * [M6-A] Shortcuts that must keep working while a guest page has keyboard
 * focus. Two families qualify:
 *  - tab lifecycle (⌘T/⌘W/⌘9), which is the app's, not the page's
 *  - browser chrome (⌘R/⌘L/zoom), which every browser takes from the page too
 *
 * Everything else is intentionally dead inside a guest: the page owns its own
 * keymap. Chord matching itself comes exclusively from the resolved keymap.
 */
export type PassthroughAction = ShortcutPassthrough['action']

const GUEST_ALLOWED: ReadonlySet<ShortcutActionId> = new Set(
  SHORTCUT_SPECS.filter((spec) => spec.guestAllowed).map((spec) => spec.id)
)

function isTabLifetimeAction(action: ShortcutActionId): boolean {
  return (
    action === 'toggle-left-rail' ||
    action === 'new-tab' ||
    action === 'new-markdown' || action === 'new-browser-tab' ||
    action === 'new-ai-tab' || action === 'new-recording-tab' ||
    action === 'new-whiteboard' || action === 'open-study-board' ||
    action === 'close-tab' ||
    action === 'activate-last-tab' ||
    action === 'reopen-tab' ||
    action === 'cycle-tab-prev' ||
    action === 'cycle-tab-next' ||
    action.startsWith('activate-tab-')
  )
}

function passthroughActionFor(
  action: ShortcutActionId
): PassthroughAction | null {
  if (action.startsWith('activate-tab-')) {
    return action as PassthroughAction
  }
  switch (action) {
    case 'new-markdown':
    case 'new-browser-tab':
    case 'new-ai-tab':
    case 'new-recording-tab':
    case 'new-whiteboard':
    case 'open-study-board':
    case 'toggle-left-rail':
    case 'new-tab':
    case 'close-tab':
    case 'activate-last-tab':
    case 'browser-back':
    case 'browser-forward':
    case 'reopen-tab':
      return action
    case 'browser-reload':
      return 'reload'
    case 'browser-reload-hard':
      return 'reload-hard'
    case 'browser-focus-address':
      return 'focus-address'
    case 'browser-find':
      return 'find'
    case 'browser-bookmark':
      return 'bookmark'
    case 'cycle-tab-prev':
      return 'prev-tab'
    case 'cycle-tab-next':
      return 'next-tab'
    case 'browser-zoom-in':
      return 'zoom-in'
    case 'browser-zoom-out':
      return 'zoom-out'
    case 'browser-zoom-reset':
      return 'zoom-reset'
    default:
      return null
  }
}

export function passthroughShortcut(
  input: {
    type: string
    key: string
    code?: string | undefined
    meta: boolean
    control: boolean
    alt: boolean
    shift: boolean
  },
  keymap: ReadonlyMap<string, ShortcutActionId>,
  priority: ShortcutPriority = 'bandal'
): PassthroughAction | null {
  if (input.type !== 'keyDown') return null
  const chord = chordFromKeyboardEvent({
    key: input.key,
    code: input.code,
    metaKey: input.meta,
    ctrlKey: input.control,
    altKey: input.alt,
    shiftKey: input.shift
  })
  if (chord === null) return null
  const action = keymap.get(chord)
  if (action === undefined || !GUEST_ALLOWED.has(action)) return null
  if (priority === 'site' && !isTabLifetimeAction(action)) return null
  return passthroughActionFor(action)
}

/**
 * Registrable site for a Korean academic host.
 *
 * `ac.kr` is a public suffix, so `inha.ac.kr` — not `ac.kr` — is the unit that
 * means "the same university". Everything else falls back to the last two
 * labels, which is right for `example.com` and wrong for nothing we care about.
 */
export function academicSite(url: string): string | null {
  let host: string
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return null
    host = parsed.hostname.toLowerCase()
  } catch {
    return null
  }
  const labels = host.split('.')
  if (labels.length < 2) return null
  // `*.ac.kr`, `*.edu`, `*.go.kr` … anything with a two-label public suffix.
  const twoLabelSuffixes = ['ac.kr', 'go.kr', 'or.kr', 're.kr', 'co.kr']
  const lastTwo = labels.slice(-2).join('.')
  if (twoLabelSuffixes.includes(lastTwo)) {
    return labels.length >= 3 ? labels.slice(-3).join('.') : null
  }
  return lastTwo
}

/**
 * Whether a `window.open` may become a REAL popup window rather than a Bandal
 * tab.
 *
 * Forwarding every popup to a tab severs `window.opener`, and an SSO popup
 * that reports back with `window.opener.postMessage` then waits forever —
 * 인하대·아주대·세종대·경희대 portals all use `window.open` for login, ID
 * lookup and menu navigation (docs/university-sites.md §7.2.10).
 *
 * The exception is deliberately narrow: same university, http(s) only. A
 * popup to anywhere else is still denied and forwarded, because the opener
 * relationship is exactly what an attacker would want to keep.
 *
 * Note the port is NOT part of the comparison here on purpose — 인하대's IdP
 * is `:8443` and its portal is `:443`, and they are the same institution.
 *
 * 같은 대학이라도 실제로 REAL WINDOW 가 되는 건 인증성 대상뿐이다 — 아래
 * `isLikelyAuthPopupUrl` 참조. my.snu 마이페이지처럼 메뉴 내비게이션을
 * window.open 으로 여는 포털은 반달 탭(주소창·뒤로가기 있는 일반 브라우저
 * 모습)으로 간다.
 */
export function isSameSiteAcademicPopup(
  openerUrl: string,
  targetUrl: string
): boolean {
  const opener = academicSite(openerUrl)
  const target = academicSite(targetUrl)
  if (opener === null || target === null) return false
  if (!isNavigationAllowed(targetUrl)) return false
  return opener === target
}

/**
 * Force the hardened guest webPreferences in-place. Mutation is deliberate:
 * Electron's `will-attach-webview` contract only honors changes made to the
 * `webPreferences` object it hands us.
 */
export function sanitizeGuestWebPreferences(
  webPreferences: Record<string, unknown>,
  partition = BROWSING_PARTITION
): void {
  // A guest must never inherit any preload bridge (either key variant).
  delete webPreferences['preload']
  delete webPreferences['preloadURL']
  webPreferences['nodeIntegration'] = false
  webPreferences['nodeIntegrationInSubFrames'] = false
  webPreferences['nodeIntegrationInWorker'] = false
  webPreferences['contextIsolation'] = true
  webPreferences['sandbox'] = true
  webPreferences['webSecurity'] = true
  webPreferences['allowRunningInsecureContent'] = false
  webPreferences['experimentalFeatures'] = false
  webPreferences['enableBlinkFeatures'] = ''
  webPreferences['webviewTag'] = false
  webPreferences['partition'] = partition
  // Chromium's built-in PDF viewer. Electron defaults `plugins` to false,
  // which meant a .pdf link downloaded instead of rendering and every
  // <embed type="application/pdf"> came up blank — while Safari and Chrome
  // both show it. In Electron 43 (Chromium 150) this flag enables PDFium and
  // nothing else: NPAPI went in Chromium 45, PPAPI/Flash in 88. Since Electron
  // 41, PDFs render as out-of-process iframes (OOPIFs), not as separate
  // WebContents. PDFium remains sandboxed, matching Chrome's posture. Nothing
  // here touches preload, node integration, webSecurity or the partition
  // allowlist.
  //
  // It also makes `navigator.pdfViewerEnabled` true and `navigator.plugins`
  // non-empty, which legacy Korean report viewers branch on.
  webPreferences['plugins'] = true
  // Chrome offers "이 페이지에서 추가 대화상자를 만들지 않도록 차단" after a
  // few. We had no escape hatch at all: a `while(true){alert()}` — an ad, or
  // a broken portal script — produced an unbounded chain of window-modal
  // native boxes that froze 필기, 보드 and 채팅 along with the browser.
  webPreferences['safeDialogs'] = true
  webPreferences['safeDialogsMessage'] =
    '이 페이지가 대화상자를 계속 띄우고 있어요. 더 이상 보여주지 않을게요.'
}

/**
 * A popup whose document the OPENER writes, rather than one the network
 * serves.
 *
 * There is no URL to forward to a Bandal tab, so forwarding is structurally
 * impossible — and denying it hands the page `null`, which is what killed
 * 서울대 shine's OZ Report Viewer with "Failed to create the report manager":
 * the next line was `w.document.write(...)` on null.
 *
 *   window.open('', 'printWin').document.write(...)   ← 고지서·증명서 출력
 *   window.open(URL.createObjectURL(pdfBlob))         ← PDF 미리보기
 *
 * A blob: URL is keyed to the CREATING document, so even a same-partition tab
 * would 404 on it. It has to be a real window.
 *
 * Safety rests on origin inheritance: an about:blank child IS the opener's
 * origin, and a blob: child is scoped to it. Neither gains anything the opener
 * did not already have — this is what every browser does.
 */
export function isOpenerScopedPopupTarget(url: string): boolean {
  // Chromium reports `window.open('', …)` as either form depending on how it
  // resolved the empty string.
  if (url === '' || url === 'about:blank') return true
  return url.startsWith('blob:https://') || url.startsWith('blob:http://')
}

/**
 * 같은 대학 팝업 중 `window.opener` 보존이 실제로 필요한 인증성 대상.
 *
 * SSO 팝업은 로그인 완료 후 `opener.postMessage` 로 보고하므로 탭으로 보내면
 * 영영 기다린다. 반면 마이페이지·메뉴 내비게이션 팝업은 opener 가 필요 없고,
 * 맨 창(주소창도 뒤로가기도 없는)으로 뜨는 것이 사용자에겐 고장으로 보인다.
 *
 * 판정은 호스트 라벨·경로 세그먼트의 토큰 포함 검사다. 오탐('authors' 등)의
 * 비용 방향이 안전하다 — 창으로 열릴 뿐, 로그인은 절대 깨지지 않는다.
 */
const AUTH_POPUP_TOKENS = [
  'sso',
  'login',
  'signin',
  'logon',
  'auth',
  'oauth',
  'idp',
  'cas',
  'nid',
  'passni',
  'pki',
  'cert'
] as const

export function isLikelyAuthPopupUrl(url: string): boolean {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return false
  }
  const hostLabels = parsed.hostname.toLowerCase().split('.')
  const pathSegments = parsed.pathname.toLowerCase().split('/')
  const parts = [...hostLabels, ...pathSegments]
  return parts.some((part) =>
    AUTH_POPUP_TOKENS.some((token) => part.includes(token))
  )
}

export type PopupDecision =
  /** A real popup window. */
  | { kind: 'window'; scope: 'opener' | 'sso' }
  /** A custom scheme worth asking the student about. */
  | { kind: 'scheme' }
  | { kind: 'deny' }

/**
 * What `window.open` should become. Pure, so every branch is testable without
 * an Electron window.
 */
export function decidePopup(input: {
  openerUrl: string
  targetUrl: string
}): PopupDecision {
  const { targetUrl } = input
  // Let Chromium create the requested browsing context. URL-only tab
  // forwarding loses POST bodies, named-window reuse and window.opener.
  if (isOpenerScopedPopupTarget(targetUrl)) return { kind: 'window', scope: 'opener' }
  if (popupForwardUrl(targetUrl) !== null) {
    return {
      kind: 'window',
      scope: isBlockedEmbeddedAuthUrl(targetUrl) || isLikelyAuthPopupUrl(targetUrl)
        ? 'sso' : 'opener'
    }
  }
  // The scheme classifier — not this function — decides what is worth asking
  // about, so a `deny` here really does mean denied and `scheme` really does
  // mean a dialog is coming.
  const verdict = classifyExternalScheme(targetUrl).kind
  return verdict === 'ask' || verdict === 'everyday'
    ? { kind: 'scheme' }
    : { kind: 'deny' }
}

const POPUP_MIN_PX = 320
const POPUP_MAX_WIDTH_PX = 1400
const POPUP_MAX_HEIGHT_PX = 1200
/** An SSO sheet. Narrow on purpose — it is a login form. */
const SSO_SIZE = { width: 520, height: 640 } as const
/** A document the opener writes: a 고지서 at 520x640 is unreadable. */
const OPENER_SIZE = { width: 900, height: 760 } as const

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value))
}

function featureNumber(features: string, key: string): number | null {
  const match = new RegExp(`(?:^|,)\\s*${key}\\s*=\\s*(\\d+)`).exec(features)
  if (match === null) return null
  const value = Number.parseInt(match[1] ?? '', 10)
  return Number.isFinite(value) ? value : null
}

/**
 * How big a popup should be. The site's own `features` string wins when it is
 * sane, clamped so a page cannot open a 1x1 window (invisible) or one larger
 * than any screen.
 */
export function popupWindowSize(
  scope: 'opener' | 'sso',
  features: string
): { width: number; height: number } {
  const base = scope === 'sso' ? SSO_SIZE : OPENER_SIZE
  const width = featureNumber(features, 'width') ?? base.width
  const height = featureNumber(features, 'height') ?? base.height
  return {
    width: clamp(width, POPUP_MIN_PX, POPUP_MAX_WIDTH_PX),
    height: clamp(height, POPUP_MIN_PX, POPUP_MAX_HEIGHT_PX)
  }
}
