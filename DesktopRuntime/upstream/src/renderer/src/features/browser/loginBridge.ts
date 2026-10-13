import { useEffect, type RefObject } from 'react'
import {
  LOGIN_CAPTURE_GLOBAL,
  STAGED_LOGIN_TTL_MS,
  type SavedLoginSummary
} from '../../../../shared/types/credentials'
import { invoke } from '../../lib/ipc'
import {
  initialLoginState,
  useBrowserGuests,
  type BrowserLoginState
} from './browserGuestsStore'
import type { BrowserPageHandle } from './browserPageTypes'

export const LOGIN_REPORT_PREFIX = '__bandal_login_form__'

interface WebviewConsoleMessageEvent extends Event {
  message: string
}

export interface LoginFormReport {
  kind: 'form'
  origin: string
  hasLoginForm: boolean
  usernameFocused: boolean
}

export interface LoginSubmitReport {
  kind: 'submit'
  origin: string
}

export type LoginReporterReport = LoginFormReport | LoginSubmitReport

/**
 * Runs only in the top frame. The console report contains submission metadata
 * but never field values; main reads the capture global directly before the
 * navigation can destroy the document.
 */
export const REPORTER_SOURCE = `(() => {
  if (window.top !== window || window.__bandalLoginReporterInstalledV2__ === true) return;
  Object.defineProperty(window, '__bandalLoginReporterInstalledV2__', {
    value: true, configurable: false, enumerable: false, writable: false
  });
  const prefix = ${JSON.stringify(LOGIN_REPORT_PREFIX)};
  const touchedPasswords = new WeakSet();
  const fields = () => {
    const password = document.querySelector('input[type="password"]');
    if (!(password instanceof HTMLInputElement) || password.disabled || password.readOnly) {
      return null;
    }
    const usernames = Array.from(document.querySelectorAll(
      'input[type="text"], input[type="email"], input[type="tel"], input:not([type])'
    )).filter((input) =>
      input instanceof HTMLInputElement &&
      !input.disabled &&
      !input.readOnly &&
      (input.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0
    );
    const username = usernames.at(-1);
    return username instanceof HTMLInputElement ? { username, password } : null;
  };
  document.addEventListener('input', (event) => {
    if (
      event.isTrusted &&
      event.target instanceof HTMLInputElement &&
      event.target.type === 'password'
    ) touchedPasswords.add(event.target);
  }, true);
  Object.defineProperty(window, ${JSON.stringify(LOGIN_CAPTURE_GLOBAL)}, {
    value: () => {
      const found = fields();
      if (!found || !touchedPasswords.has(found.password)) return null;
      return { username: found.username.value, password: found.password.value };
    },
    configurable: false,
    enumerable: false,
    writable: false
  });
  let previous = '';
  let timer = 0;
  let submitted = false;
  const send = (payload) => console.log(prefix + JSON.stringify(payload));
  const report = () => {
    timer = 0;
    const found = fields();
    const payload = {
      kind: 'form',
      origin: location.origin,
      hasLoginForm: found !== null,
      usernameFocused: found !== null && document.activeElement === found.username
    };
    const serialized = JSON.stringify(payload);
    if (serialized === previous) return;
    previous = serialized;
    console.log(prefix + serialized);
  };
  const schedule = () => {
    window.clearTimeout(timer);
    timer = window.setTimeout(report, 80);
  };
  const reportSubmit = (event) => {
    if (submitted || !event.isTrusted) return;
    const found = fields();
    if (
      !found ||
      !touchedPasswords.has(found.password) ||
      found.username.value.trim() === '' ||
      found.password.value === ''
    ) return;
    submitted = true;
    send({ kind: 'submit', origin: location.origin });
  };
  document.addEventListener('submit', reportSubmit, true);
  document.addEventListener('keydown', (event) => {
    if (
      event.key === 'Enter' &&
      event.target instanceof HTMLInputElement &&
      event.target.type === 'password'
    ) reportSubmit(event);
  }, true);
  document.addEventListener('click', (event) => {
    const target = event.target instanceof Element
      ? event.target.closest('button, input')
      : null;
    const isSubmit =
      (target instanceof HTMLButtonElement && target.type === 'submit') ||
      (target instanceof HTMLInputElement && ['submit', 'image'].includes(target.type));
    if (isSubmit) reportSubmit(event);
  }, true);
  document.addEventListener('focusin', schedule, true);
  document.addEventListener('focusout', schedule, true);
  new MutationObserver(schedule).observe(document.documentElement, {
    childList: true, subtree: true, attributes: true,
    attributeFilter: ['type', 'disabled', 'readonly']
  });
  report();
})();`

interface CaptureModeRequest {
  origin: string
  guestWebContentsId: number
  autoSubmit: false
  mode: 'stage' | 'commit' | 'discard'
}

export interface StagedPromptCandidate {
  origin: string
  username: string
  kind: 'save' | 'update'
  ready: boolean
  navigated: boolean
  prompted: boolean
}

const elements = new Map<string, BrowserPageHandle>()
const autoFilledOrigins = new Map<string, string>()
const navigationGenerations = new Map<string, number>()
const stagedLogins = new Map<string, StagedPromptCandidate>()
const stagedExpiryTimers = new Map<string, ReturnType<typeof setTimeout>>()
const suppressedSites = new Set<string>()
const SUPPRESSED_SITE_STORAGE_PREFIX = 'bandal.credentials.suppress.'

const COMMON_SECOND_LEVEL_SUFFIXES = new Set([
  'ac',
  'co',
  'go',
  'ne',
  'or',
  'pe',
  're'
])

function httpsOrigin(value: string): string | null {
  try {
    const url = new URL(value)
    return url.protocol === 'https:' ? url.origin : null
  } catch {
    return null
  }
}

function siteKey(value: string): string | null {
  try {
    const host = new URL(value).hostname
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

function suppressionStorage(): Storage | null {
  try {
    return typeof window === 'undefined' ? null : window.localStorage
  } catch {
    return null
  }
}

export function isLoginPromptSuppressed(site: string): boolean {
  if (suppressedSites.has(site)) return true
  try {
    if (
      suppressionStorage()?.getItem(SUPPRESSED_SITE_STORAGE_PREFIX + site) ===
      '1'
    ) {
      suppressedSites.add(site)
      return true
    }
  } catch {
    return false
  }
  return false
}

export function suppressLoginPromptForSite(site: string): boolean {
  suppressedSites.add(site)
  const storage = suppressionStorage()
  if (storage === null) return true
  try {
    storage.setItem(SUPPRESSED_SITE_STORAGE_PREFIX + site, '1')
    return true
  } catch {
    return false
  }
}

export function isSameLoginSite(left: string, right: string): boolean {
  const leftOrigin = httpsOrigin(left)
  const rightOrigin = httpsOrigin(right)
  if (leftOrigin === null || rightOrigin === null) return false
  return siteKey(leftOrigin) === siteKey(rightOrigin)
}

export function parseLoginReport(message: string): LoginReporterReport | null {
  if (!message.startsWith(LOGIN_REPORT_PREFIX)) return null
  try {
    const value: unknown = JSON.parse(message.slice(LOGIN_REPORT_PREFIX.length))
    if (typeof value !== 'object' || value === null) return null
    const report = value as Record<string, unknown>
    if (typeof report['origin'] !== 'string') return null
    const origin = httpsOrigin(report['origin'])
    if (origin === null) return null
    if (report['kind'] === 'submit') return { kind: 'submit', origin }
    if (
      report['kind'] !== 'form' ||
      typeof report['hasLoginForm'] !== 'boolean' ||
      typeof report['usernameFocused'] !== 'boolean'
    ) {
      return null
    }
    return {
      kind: 'form',
      origin,
      hasLoginForm: report['hasLoginForm'],
      usernameFocused: report['usernameFocused']
    }
  } catch {
    return null
  }
}

/** Mutates `candidate` so a qualifying navigation can surface only once. */
export function consumeStagedPrompt(
  candidate: StagedPromptCandidate,
  currentOrigin: string,
  hasLoginForm: boolean
): boolean {
  if (
    !candidate.ready ||
    !candidate.navigated ||
    candidate.prompted ||
    hasLoginForm ||
    // Google's password-free passkey, verification, consent and refusal
    // screens are still authentication steps. Wait until the account flow
    // reaches a Google service before offering to save the submitted login.
    httpsOrigin(currentOrigin) === 'https://accounts.google.com' ||
    !isSameLoginSite(candidate.origin, currentOrigin)
  ) {
    return false
  }
  candidate.prompted = true
  return true
}

function liveOrigin(element: BrowserPageHandle): string | null {
  try {
    return httpsOrigin(element.getURL())
  } catch {
    return null
  }
}

function update(tabId: string, patch: Partial<BrowserLoginState>): void {
  useBrowserGuests.getState().updateLogin(tabId, patch)
}

function guestId(element: BrowserPageHandle): number | null {
  try {
    return element.getWebContentsId()
  } catch {
    return null
  }
}

function captureWithMode(
  request: CaptureModeRequest
): Promise<SavedLoginSummary | null> {
  // A named value may carry the local mode extension while remaining
  // structurally compatible with the frozen shared request contract.
  return invoke('credentials:capture', request)
}

function maybeShowPrompt(tabId: string): void {
  const staged = stagedLogins.get(tabId)
  const state = useBrowserGuests.getState().login[tabId]
  if (
    staged === undefined ||
    state === undefined ||
    state.origin === null ||
    !consumeStagedPrompt(staged, state.origin, state.hasLoginForm)
  ) {
    return
  }
  update(tabId, {
    savePrompt: { origin: staged.origin, username: staged.username, kind: staged.kind },
  })
}

function clearStagedLogin(tabId: string): void {
  stagedLogins.delete(tabId)
  const timer = stagedExpiryTimers.get(tabId)
  if (timer !== undefined) clearTimeout(timer)
  stagedExpiryTimers.delete(tabId)
}

async function fill(tabId: string, origin: string, credentialId?: string): Promise<boolean> {
  const element = elements.get(tabId)
  if (element === undefined || liveOrigin(element) !== origin) return false
  const guestWebContentsId = guestId(element)
  if (guestWebContentsId === null) return false

  try {
    const result = await invoke('credentials:fill', {
      origin,
      guestWebContentsId,
      ...(credentialId === undefined ? {} : { credentialId })
    })
    return result.filled
  } catch {
    return false
  }
}

async function stageSubmittedLogin(
  tabId: string,
  report: LoginSubmitReport
): Promise<void> {
  const element = elements.get(tabId)
  const state = useBrowserGuests.getState().login[tabId]
  const key = siteKey(report.origin)
  if (
    element === undefined ||
    state === undefined ||
    liveOrigin(element) !== report.origin ||
    (key !== null && isLoginPromptSuppressed(key))
  ) {
    return
  }
  const guestWebContentsId = guestId(element)
  if (guestWebContentsId === null) return

  const candidate: StagedPromptCandidate = {
    origin: report.origin,
    username: '',
    kind: 'save',
    ready: false,
    navigated: false,
    prompted: false
  }
  clearStagedLogin(tabId)
  stagedLogins.set(tabId, candidate)
  update(tabId, { savePrompt: null })
  try {
    const summary = await captureWithMode({
      origin: report.origin,
      guestWebContentsId,
      autoSubmit: false,
      mode: 'stage'
    })
    if (stagedLogins.get(tabId) !== candidate) return
    if (summary === null) {
      clearStagedLogin(tabId)
      return
    }
    // An existing login for the site can belong to a different account.
    // Only the actual captured account can make this an update prompt.
    try {
      const logins = await invoke('credentials:list', { profileId: useBrowserGuests.getState().liveGuests.find(g => g.tabId === tabId)?.profileId ?? 'default' })
      if (logins.some((login) => login.origin === summary.origin && login.username === summary.username)) {
        candidate.kind = 'update'
      }
    } catch {
      // The capture already succeeded; keep the conservative save wording
      // while surfacing that metadata lookup failed.
      update(tabId, { message: 'failed' })
    }
    if (stagedLogins.get(tabId) !== candidate) return
    candidate.origin = summary.origin
    candidate.username = summary.username
    const remaining = Date.parse(summary.updatedAt) + STAGED_LOGIN_TTL_MS - Date.now()
    if (!Number.isFinite(remaining) || remaining <= 0) {
      await discardStagedLoginForTab(tabId, false)
      return
    }
    stagedExpiryTimers.set(tabId, setTimeout(() => {
      if (stagedLogins.get(tabId) === candidate) void discardStagedLoginForTab(tabId, false)
    }, remaining))
    candidate.ready = true
    maybeShowPrompt(tabId)
  } catch {
    if (stagedLogins.get(tabId) === candidate) clearStagedLogin(tabId)
    update(tabId, { message: 'failed' })
  }
}

async function applyFormReport(
  tabId: string,
  generation: number,
  report: LoginFormReport
): Promise<void> {
  const element = elements.get(tabId)
  if (
    element === undefined ||
    navigationGenerations.get(tabId) !== generation ||
    liveOrigin(element) !== report.origin
  ) {
    return
  }
  update(tabId, {
    origin: report.origin,
    hasLoginForm: report.hasLoginForm,
    usernameFocused: report.usernameFocused,
    savedLogin: null,
    savedLogins: [],
    pending: report.hasLoginForm,
    message: null
  })
  if (!report.hasLoginForm) {
    update(tabId, { pending: false })
    maybeShowPrompt(tabId)
    return
  }

  let saved: SavedLoginSummary | undefined
  let accounts: SavedLoginSummary[] = []
  try {
    const logins = await invoke('credentials:list', { profileId: useBrowserGuests.getState().liveGuests.find(g => g.tabId === tabId)?.profileId ?? 'default' })
    accounts = logins.filter((login) => login.origin === report.origin)
    saved = accounts.length === 1 ? accounts[0] : undefined
  } catch {
    update(tabId, { pending: false, message: 'failed' })
    return
  }
  if (
    navigationGenerations.get(tabId) !== generation ||
    liveOrigin(element) !== report.origin
  ) {
    return
  }
  update(tabId, { savedLogin: saved ?? null, savedLogins: accounts, pending: false })

  if (saved !== undefined && autoFilledOrigins.get(tabId) !== report.origin) {
    autoFilledOrigins.set(tabId, report.origin)
    update(tabId, { pending: true })
    const filled = await fill(tabId, report.origin, saved.id)
    update(tabId, { pending: false, message: filled ? 'filled' : 'failed' })
  }
}


export async function saveStagedLoginForTab(tabId: string): Promise<'saved' | 'expired' | 'failed'> {
  const element = elements.get(tabId)
  const staged = stagedLogins.get(tabId)
  const current = element === undefined ? null : liveOrigin(element)
  const guestWebContentsId = element === undefined ? null : guestId(element)
  if (
    staged === undefined ||
    current === null ||
    guestWebContentsId === null ||
    !isSameLoginSite(staged.origin, current)
  ) {
    return 'expired'
  }

  update(tabId, { pending: true, message: null })
  try {
    const saved = await captureWithMode({
      origin: current,
      guestWebContentsId,
      autoSubmit: false,
      mode: 'commit'
    })
    if (saved === null) {
      // Main also returns null when storage refuses the write. Preserve the
      // candidate for retry while it is still alive; null alone is not proof
      // that it expired. The shared expiry timer removes the card when due.
      update(tabId, { pending: false, message: 'failed' })
      return stagedLogins.get(tabId) === staged ? 'failed' : 'expired'
    }
    clearStagedLogin(tabId)
    update(tabId, {
      pending: false,
      savePrompt: null,
      savedLogin: saved.origin === current ? saved : null,
      message: 'saved'
    })
    return 'saved'
  } catch {
    update(tabId, { pending: false, message: 'failed' })
    return 'failed'
  }
}

export async function discardStagedLoginForTab(
  tabId: string,
  suppressSite: boolean
): Promise<void> {
  const element = elements.get(tabId)
  const staged = stagedLogins.get(tabId)
  if (staged === undefined) return
  let message: BrowserLoginState['message'] = null
  if (suppressSite) {
    const key = siteKey(staged.origin)
    if (key !== null && !suppressLoginPromptForSite(key)) message = 'failed'
  }
  clearStagedLogin(tabId)
  update(tabId, { savePrompt: null, message })
  const guestWebContentsId = element === undefined ? null : guestId(element)
  const origin = element === undefined ? null : liveOrigin(element)
  if (guestWebContentsId === null || origin === null) return
  try {
    await captureWithMode({
      origin,
      guestWebContentsId,
      autoSubmit: false,
      mode: 'discard'
    })
  } catch {
    update(tabId, { message: 'failed' })
  }
}

export async function fillLoginForTab(tabId: string, credentialId?: string): Promise<void> {
  const state = useBrowserGuests.getState().login[tabId]
  if (
    state === undefined ||
    state.origin === null ||
    (state.savedLogin === null && credentialId === undefined) ||
    state.pending
  ) {
    return
  }
  update(tabId, { pending: true, message: null })
  const filled = await fill(tabId, state.origin, credentialId ?? state.savedLogin?.id)
  update(tabId, { pending: false, message: filled ? 'filled' : 'failed' })
}

export function useBrowserLoginBridge(
  tabId: string,
  webviewRef: RefObject<BrowserPageHandle | null>,
  enabled = true
): void {
  useEffect(() => {
    if (!enabled) {
      update(tabId, initialLoginState())
      return
    }
    const webview = webviewRef.current
    if (webview === null) return
    elements.set(tabId, webview)
    navigationGenerations.set(tabId, 0)

    const inject = (): void => {
      try {
        void webview.executeJavaScript(REPORTER_SOURCE).catch(() => undefined)
      } catch {
        // The next dom-ready retries after an attach/navigation race.
      }
    }
    const onConsoleMessage = (rawEvent: Event): void => {
      const event = rawEvent as WebviewConsoleMessageEvent
      if (typeof event.message !== 'string') return
      const report = parseLoginReport(event.message)
      if (report?.kind === 'submit') {
        void stageSubmittedLogin(tabId, report)
      } else if (report?.kind === 'form') {
        void applyFormReport(
          tabId,
          navigationGenerations.get(tabId) ?? 0,
          report
        )
      }
    }
    const onStartLoading = (): void => {
      try {
        if (!webview.isLoadingMainFrame()) return
      } catch {
        // Treat an attach race as a main-frame navigation.
      }
      navigationGenerations.set(
        tabId,
        (navigationGenerations.get(tabId) ?? 0) + 1
      )
      update(tabId, {
        origin: null,
        hasLoginForm: false,
        usernameFocused: false,
        savedLogin: null,
        savedLogins: [],
        savePrompt: null,
        pending: false,
        message: null
      })
    }
    const onNavigate = (): void => {
      const current = liveOrigin(webview)
      const staged = stagedLogins.get(tabId)
      if (current === null || staged === undefined) return
      if (!isSameLoginSite(staged.origin, current)) {
        void discardStagedLoginForTab(tabId, false)
        return
      }
      staged.navigated = true
      if (autoFilledOrigins.get(tabId) !== current) {
        autoFilledOrigins.delete(tabId)
      }
      maybeShowPrompt(tabId)
    }

    webview.addEventListener('dom-ready', inject)
    webview.addEventListener('console-message', onConsoleMessage)
    webview.addEventListener('did-start-loading', onStartLoading)
    webview.addEventListener('did-navigate', onNavigate)
    inject()
    return () => {
      webview.removeEventListener('dom-ready', inject)
      webview.removeEventListener('console-message', onConsoleMessage)
      webview.removeEventListener('did-start-loading', onStartLoading)
      webview.removeEventListener('did-navigate', onNavigate)
      if (stagedLogins.has(tabId)) void discardStagedLoginForTab(tabId, false)
      if (elements.get(tabId) === webview) elements.delete(tabId)
      autoFilledOrigins.delete(tabId)
      navigationGenerations.delete(tabId)
    }
  }, [enabled, tabId, webviewRef])
}

/** Test-only: session prompt preferences and staged metadata are ephemeral. */
export function resetLoginBridgeForTests(): void {
  elements.clear()
  autoFilledOrigins.clear()
  navigationGenerations.clear()
  stagedLogins.clear()
  for (const timer of stagedExpiryTimers.values()) clearTimeout(timer)
  stagedExpiryTimers.clear()
  suppressedSites.clear()
}
