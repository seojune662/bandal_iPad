import { isManagedBrowserPage } from '../browser/managedPages'
import {
  LOGIN_CAPTURE_GLOBAL,
  STAGED_LOGIN_TTL_MS,
  type SavedLoginSummary
} from '../../../shared/types/credentials'
import type { CredentialStore, ResolvedLogin } from './credentialStore'
import { normalizeCredentialOrigin } from './credentialStore'
import {
  currentOrigin,
  defaultFromId,
  resolveGuest,
  type LoginFillerDeps,
  type LoginGuestWebContents
} from './loginFiller'

export interface LoginCaptureRequest {
  origin: string
  guestWebContentsId: number
  autoSubmit?: boolean
  /** Submitted credentials stay in main until the student confirms saving. */
  mode?: 'save' | 'stage' | 'commit' | 'discard'
}

export { STAGED_LOGIN_TTL_MS } from '../../../shared/types/credentials'

interface LoginCaptureDeps extends LoginFillerDeps {
  now?: () => number
}

interface StagedLogin {
  origin: string
  username: string
  password: string
  expiresAt: number
  timer: ReturnType<typeof setTimeout>
}

/** Enough for any real credential; a guard against a hostile page's payload. */
const MAX_USERNAME = 10_000
const MAX_PASSWORD = 100_000

/**
 * Calls the capture function the browser tab installed in the page. It only
 * answers for the top frame, and only after a trusted keystroke reached the
 * password field — so a page cannot use it to hand us a value of its choosing
 * and have it stored under its own origin.
 */
const CAPTURE_SOURCE = `(() => {
  if (window.top !== window) return null;
  const capture = window[${JSON.stringify(LOGIN_CAPTURE_GLOBAL)}];
  return typeof capture === 'function' ? capture() : null;
})()`

function parse(value: unknown): { username: string; password: string } | null {
  if (typeof value !== 'object' || value === null) return null
  const captured = value as Record<string, unknown>
  const username = captured['username']
  const password = captured['password']
  if (
    typeof username !== 'string' ||
    typeof password !== 'string' ||
    username.trim() === '' ||
    password === '' ||
    username.length > MAX_USERNAME ||
    password.length > MAX_PASSWORD
  ) {
    return null
  }
  return { username, password }
}

const COMMON_SECOND_LEVEL_SUFFIXES = new Set([
  'ac',
  'co',
  'go',
  'ne',
  'or',
  'pe',
  're'
])

function siteKey(origin: string): string | null {
  try {
    const host = new URL(normalizeCredentialOrigin(origin)).hostname
    const labels = host.split('.').filter(Boolean)
    if (labels.length < 2 || /^\d+(?:\.\d+){3}$/.test(host)) return host
    const suffixLength =
      labels.at(-1)?.length === 2 &&
      COMMON_SECOND_LEVEL_SUFFIXES.has(labels.at(-2) ?? '')
        ? 3
        : 2
    return labels.slice(-suffixLength).join('.')
  } catch {
    return null
  }
}

export function isRelatedLoginOrigin(left: string, right: string): boolean {
  const leftKey = siteKey(left)
  return leftKey !== null && leftKey === siteKey(right)
}

/**
 * Reads the login the student just typed and stores it, entirely inside main.
 * The renderer names the tab and gets back a summary; the password itself
 * never crosses the IPC boundary in either direction.
 */
export function createLoginCapturer(
  store: Pick<CredentialStore, 'save'> &
    Partial<Pick<CredentialStore, 'availability' | 'resolve' | 'list'>>,
  deps?: LoginCaptureDeps
): (request: LoginCaptureRequest) => Promise<SavedLoginSummary | null> {
  const resolved = deps ?? { fromId: defaultFromId }
  const now = deps?.now ?? Date.now
  const staged = new Map<number, StagedLogin>()

  const discard = (guestWebContentsId: number): void => {
    const existing = staged.get(guestWebContentsId)
    if (existing === undefined) return
    clearTimeout(existing.timer)
    staged.delete(guestWebContentsId)
  }

  const currentStage = (guestWebContentsId: number): StagedLogin | null => {
    const existing = staged.get(guestWebContentsId)
    if (existing === undefined) return null
    if (existing.expiresAt <= now()) {
      discard(guestWebContentsId)
      return null
    }
    return existing
  }

  const stage = (
    request: LoginCaptureRequest,
    captured: { username: string; password: string },
    origin: string,
    guest: LoginGuestWebContents
  ): SavedLoginSummary | null => {
    let existing: ResolvedLogin | null = null
    try {
      const account = store.list?.().find(login => login.origin === origin && login.username === captured.username)
      existing = store.resolve?.(origin, account?.id) ?? null
    } catch {
      return null
    }
    if (
      existing !== null &&
      existing.username === captured.username &&
      existing.password === captured.password
    ) {
      discard(request.guestWebContentsId)
      return null
    }

    discard(request.guestWebContentsId)
    const timer = setTimeout(
      () => staged.delete(request.guestWebContentsId),
      STAGED_LOGIN_TTL_MS
    )
    if (typeof timer === 'object' && 'unref' in timer) timer.unref()
    staged.set(request.guestWebContentsId, {
      origin,
      username: captured.username,
      password: captured.password,
      expiresAt: now() + STAGED_LOGIN_TTL_MS,
      timer
    })
    guest.once?.('destroyed', () => discard(request.guestWebContentsId))
    return {
      id: `staged:${request.guestWebContentsId}`,
      origin,
      username: captured.username,
      autoSubmit: false,
      updatedAt: new Date(now()).toISOString()
    }
  }

  return async (request): Promise<SavedLoginSummary | null> => {
    const mode = request.mode ?? 'save'
    if (mode === 'discard') {
      discard(request.guestWebContentsId)
      return null
    }

    if (mode === 'commit') {
      const pending = currentStage(request.guestWebContentsId)
      if (pending === null) return null
      let guest: LoginGuestWebContents | null
      try {
        guest = resolved.fromId(request.guestWebContentsId)
        if (
          guest === null ||
          (guest.getType() !== 'webview' && !isManagedBrowserPage(request.guestWebContentsId)) ||
          !isRelatedLoginOrigin(pending.origin, guest.getURL())
        ) {
          return null
        }
      } catch {
        return null
      }
      try {
        const saved = store.save({
          origin: pending.origin,
          username: pending.username,
          password: pending.password,
          autoSubmit: false
        })
        discard(request.guestWebContentsId)
        return saved
      } catch {
        return null
      }
    }

    const target = resolveGuest(resolved, request)
    if (target === null) return null

    if (mode === 'stage') {
      try {
        if (store.availability?.().state === 'unavailable') return null
      } catch {
        return null
      }
    }

    let captured: { username: string; password: string } | null
    try {
      captured = parse(await target.guest.executeJavaScript(CAPTURE_SOURCE))
    } catch {
      // Never surface the failure detail — it can quote page content.
      return null
    }
    if (captured === null) return null

    // The page could have navigated during the await. Storing a password
    // against the wrong origin would then offer it to that other site.
    if (currentOrigin(target.guest) !== target.origin) return null

    if (mode === 'stage') {
      return stage(request, captured, target.origin, target.guest)
    }

    try {
      return store.save({
        origin: target.origin,
        username: captured.username,
        password: captured.password,
        autoSubmit: request.autoSubmit ?? false
      })
    } catch {
      return null
    }
  }
}
