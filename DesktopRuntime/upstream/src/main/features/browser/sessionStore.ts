import { unlinkSync } from 'node:fs'
import { join } from 'node:path'
import type {
  Cookie,
  CookiesGetFilter,
  Event as ElectronEvent
} from 'electron'
import { BROWSING_PARTITION } from './webviewPolicy'
import { forgetGoogleAccountNavigation } from './googleAccountNavigation'

/** Removed on upgrade: older builds used this to extend session cookies. */
export const LEGACY_BROWSER_SESSION_FILE_NAME = 'browser-session-cookies.enc'

export interface BrowserSessionLike {
  flushStorageData(): void
  cookies: {
    get(filter: CookiesGetFilter): Promise<Cookie[]>
    remove(url: string, name: string): Promise<void>
    flushStore(): Promise<void>
  }
}

export interface BrowserSessionAppLike {
  on(
    event: 'before-quit',
    listener: (event: ElectronEvent) => void
  ): unknown
  removeListener(
    event: 'before-quit',
    listener: (event: ElectronEvent) => void
  ): unknown
  quit(): void
}

export interface BrowserSessionStoreDeps {
  session: BrowserSessionLike
  app?: BrowserSessionAppLike
  userDataPath?: string
  logger?: Pick<Console, 'warn'>
}

export interface BrowserSessionStore {
  flush(): Promise<void>
  startFlushOnQuit(): void
  resetQuitState(): void
  dispose(): void
  listSites(): Promise<{ origin: string; cookieCount: number }[]>
  clear(origin: string | null): Promise<{ ok: true }>
}

function normalizedDomain(domain: string | undefined): string {
  const value = domain?.replace(/^\.+/, '').trim() ?? ''
  if (value.length === 0) throw new TypeError('Cookie domain is missing')
  return value
}

/** Builds the exact URL Electron needs for cookies.remove. */
export function cookieUrl(
  cookie: Pick<Cookie, 'domain' | 'path' | 'secure'>
): string {
  const domain = normalizedDomain(cookie.domain)
  const authority = domain.includes(':') && !domain.startsWith('[')
    ? `[${domain}]`
    : domain
  const url = new URL(`${cookie.secure === true ? 'https' : 'http'}://${authority}`)

  if (
    url.username !== '' ||
    url.password !== '' ||
    url.port !== '' ||
    url.pathname !== '/' ||
    url.search !== '' ||
    url.hash !== ''
  ) {
    throw new TypeError('Cookie domain is not a hostname')
  }

  url.pathname = cookie.path?.startsWith('/') === true ? cookie.path : '/'
  return url.toString()
}

export function cookieOrigin(
  cookie: Pick<Cookie, 'domain' | 'path' | 'secure'>
): string {
  return new URL(cookieUrl(cookie)).origin
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isMissingFileError(error: unknown): boolean {
  return isRecord(error) && error['code'] === 'ENOENT'
}

function normalizedRequestedOrigin(origin: string): string {
  const parsed = new URL(origin)
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    throw new TypeError('Browser session origin must use HTTP or HTTPS')
  }
  return parsed.origin
}

function removeLegacySnapshot(
  userDataPath: string | undefined,
  logger: Pick<Console, 'warn'>
): void {
  if (userDataPath === undefined) return
  try {
    unlinkSync(join(userDataPath, LEGACY_BROWSER_SESSION_FILE_NAME))
  } catch (error: unknown) {
    if (!isMissingFileError(error)) {
      logger.warn('[browser-session] Could not remove the legacy cookie snapshot')
    }
  }
}

function buildBrowserSessionStore(
  deps: BrowserSessionStoreDeps
): BrowserSessionStore {
  const logger = deps.logger ?? console
  let flushQueue: Promise<void> = Promise.resolve()
  let listeningForQuit = false
  let finalizingQuit = false
  let allowQuit = false
  let quitGeneration = 0

  // Previous versions copied session cookies into an encrypted file and
  // restored them with a synthetic expiry. Never restore that file: doing so
  // changes server-selected cookie semantics. Chromium's own store remains.
  removeLegacySnapshot(deps.userDataPath, logger)

  const flush = (): Promise<void> => {
    const operation = flushQueue.then(async () => {
      try {
        deps.session.flushStorageData()
      } catch {
        logger.warn('[browser-session] Persistent site storage could not be flushed')
      }
      try {
        await deps.session.cookies.flushStore()
      } catch {
        logger.warn('[browser-session] Persistent cookies could not be flushed')
      }
    })
    flushQueue = operation
    return operation
  }

  const beforeQuit = (event: ElectronEvent): void => {
    if (allowQuit) return
    event.preventDefault()
    if (finalizingQuit) return

    finalizingQuit = true
    const generation = quitGeneration
    void flush().finally(() => {
      if (generation !== quitGeneration) return
      allowQuit = true
      deps.app?.quit()
    })
  }

  return {
    flush,

    startFlushOnQuit(): void {
      if (deps.app !== undefined && !listeningForQuit) {
        deps.app.on('before-quit', beforeQuit)
        listeningForQuit = true
      }
    },

    resetQuitState(): void {
      quitGeneration++
      finalizingQuit = false
      allowQuit = false
    },

    dispose(): void {
      if (deps.app !== undefined && listeningForQuit) {
        deps.app.removeListener('before-quit', beforeQuit)
        listeningForQuit = false
      }
    },

    async listSites(): Promise<{ origin: string; cookieCount: number }[]> {
      const counts = new Map<string, number>()
      for (const cookie of await deps.session.cookies.get({})) {
        try {
          const origin = cookieOrigin(cookie)
          counts.set(origin, (counts.get(origin) ?? 0) + 1)
        } catch {
          logger.warn('[browser-session] Ignored a cookie with an invalid domain')
        }
      }
      return [...counts.entries()]
        .map(([origin, cookieCount]) => ({ origin, cookieCount }))
        .sort((left, right) => left.origin.localeCompare(right.origin))
    },

    async clear(origin: string | null): Promise<{ ok: true }> {
      const requestedOrigin = origin === null
        ? null
        : normalizedRequestedOrigin(origin)
      forgetGoogleAccountNavigation(deps.session)
      const removals: Promise<void>[] = []

      for (const cookie of await deps.session.cookies.get({})) {
        try {
          if (
            requestedOrigin === null ||
            cookieOrigin(cookie) === requestedOrigin
          ) {
            removals.push(
              deps.session.cookies.remove(cookieUrl(cookie), cookie.name)
            )
          }
        } catch {
          logger.warn('[browser-session] Ignored a cookie with an invalid domain')
        }
      }

      await Promise.all(removals)
      await flush()
      return { ok: true }
    }
  }
}

let defaultStore: BrowserSessionStore | undefined

/**
 * Production calls use Electron lazily so importing this module in Vitest does
 * not require an Electron runtime. No-argument calls share one app-wide store.
 */
export function createBrowserSessionStore(): BrowserSessionStore
export function createBrowserSessionStore(
  deps: BrowserSessionStoreDeps
): BrowserSessionStore
export function createBrowserSessionStore(
  deps?: BrowserSessionStoreDeps
): BrowserSessionStore {
  if (deps !== undefined) return buildBrowserSessionStore(deps)
  if (defaultStore !== undefined) return defaultStore

  const electron = require('electron') as typeof import('electron')
  defaultStore = buildBrowserSessionStore({
    session: electron.session.fromPartition(BROWSING_PARTITION),
    userDataPath: electron.app.getPath('userData'),
    app: electron.app
  })
  return defaultStore
}
