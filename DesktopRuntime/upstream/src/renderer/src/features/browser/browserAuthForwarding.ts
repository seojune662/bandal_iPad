import type { BrowserAuthFallback } from '../../../../shared/types/browserAuth'
import type { PushEvents } from '../../../../shared/ipc/events'
import { onPush } from '../../lib/ipc'
import { useBrowserGuests, type LiveGuest } from './browserGuestsStore'

type AuthEvent = PushEvents['browser:external-auth']
type GuestIdentity = Pick<LiveGuest, 'tabId' | 'profileId' | 'isPrivate'>
interface AuthSource {
  documentId: string
  retiredDocuments: Set<string>
  fallback: BrowserAuthFallback | null
}
interface AuthTarget {
  session: string
  webContentsId: number
  documentId: string | undefined
  retiredDocuments: Set<string>
  sources: Map<number, AuthSource>
}
interface PendingAuth {
  tabId: string
  session: string | null
  event: AuthEvent
}

const sessionKey = (guest: GuestIdentity): string => JSON.stringify([guest.profileId, guest.isPrivate])
const MAX_PENDING = 64
const MAX_RETIRED_PAGES = 512
const MAX_RETIRED_DOCUMENTS = 32
const MAX_SOURCES = 32

function rememberBounded<T>(values: Set<T>, value: T, limit: number): void {
  values.add(value)
  while (values.size > limit) values.delete(values.values().next().value!)
}

/** Main owns detection. This only keeps its results attached to the right page. */
export function createBrowserAuthForwarder(
  guests: () => readonly GuestIdentity[],
  setFallback: (tabId: string, fallback: BrowserAuthFallback | null) => void
) {
  const targets = new Map<string, AuthTarget>()
  const retiredWebContents = new Set<number>()
  const pending = new Map<string, PendingAuth>()
  const sessionFor = (tabId: string): string | null => {
    const guest = guests().find(value => value.tabId === tabId)
    return guest ? sessionKey(guest) : null
  }
  const show = (tabId: string, target: AuthTarget): void => {
    const notices = [...target.sources.values()].filter(source => source.fallback !== null)
    setFallback(tabId, notices.at(-1)?.fallback ?? null)
  }
  const retire = (tabId: string, webContentsId: number): void => {
    rememberBounded(retiredWebContents, webContentsId, MAX_RETIRED_PAGES)
    for (const [key, queued] of pending) {
      if (queued.event.webContentsId === webContentsId) pending.delete(key)
    }
    if (targets.get(tabId)?.webContentsId !== webContentsId) return
    targets.delete(tabId)
    setFallback(tabId, null)
  }
  const reconcile = (): void => {
    for (const [tabId, target] of targets) {
      if (sessionFor(tabId) !== target.session) retire(tabId, target.webContentsId)
    }
    for (const [key, queued] of pending) {
      if (queued.session !== null && sessionFor(queued.tabId) !== queued.session) {
        rememberBounded(retiredWebContents, queued.event.webContentsId, MAX_RETIRED_PAGES)
        pending.delete(key)
      }
    }
  }
  const apply = (tabId: string, target: AuthTarget, event: AuthEvent): boolean => {
    if (event.sourceWebContentsId === target.webContentsId) {
      if (target.retiredDocuments.has(event.documentId)) return true
      // A navigation clear can arrive just before its native page snapshot.
      if (target.documentId !== event.documentId) return false
    }
    const previous = target.sources.get(event.sourceWebContentsId)
    if (previous?.retiredDocuments.has(event.documentId)) return true
    const retiredDocuments = previous?.retiredDocuments ?? new Set<string>()
    if (previous && previous.documentId !== event.documentId) rememberBounded(retiredDocuments, previous.documentId, MAX_RETIRED_DOCUMENTS)
    const fallback = event.status === 'blocked' && event.restartUrl
      ? { restartUrl: event.restartUrl, ...(event.reason ? { reason: event.reason } : {}) } : null
    // Reinsert so the most recently reported visible refusal wins. A popup's
    // recovery must not erase another popup or the parent document's refusal.
    target.sources.delete(event.sourceWebContentsId)
    target.sources.set(event.sourceWebContentsId, { documentId: event.documentId, retiredDocuments, fallback })
    while (target.sources.size > MAX_SOURCES) target.sources.delete(target.sources.keys().next().value!)
    show(tabId, target)
    return true
  }
  const flush = (tabId: string, target: AuthTarget): void => {
    for (const [key, queued] of pending) {
      if (queued.tabId !== tabId || queued.event.webContentsId !== target.webContentsId) continue
      if (apply(tabId, target, queued.event)) pending.delete(key)
    }
  }
  return {
    reconcile,
    register(tabId: string, webContentsId: number, documentId?: string): void {
      reconcile()
      const session = sessionFor(tabId)
      if (session === null || webContentsId <= 0 || retiredWebContents.has(webContentsId)) return
      let target = targets.get(tabId)
      if (target && target.webContentsId !== webContentsId) {
        retire(tabId, target.webContentsId)
        target = undefined
      }
      if (!target) {
        target = { session, webContentsId, documentId, retiredDocuments: new Set(), sources: new Map() }
        targets.set(tabId, target)
      } else if (target.documentId !== documentId) {
        if (documentId !== undefined && target.retiredDocuments.has(documentId)) return
        if (target.documentId !== undefined) rememberBounded(target.retiredDocuments, target.documentId, MAX_RETIRED_DOCUMENTS)
        target.documentId = documentId
        target.sources.delete(webContentsId)
        show(tabId, target)
      }
      flush(tabId, target)
    },
    retire,
    receive(event: AuthEvent): void {
      reconcile()
      if (retiredWebContents.has(event.webContentsId)) return
      const tabId = event.tabId ?? [...targets].find(([, target]) => target.webContentsId === event.webContentsId)?.[0]
      if (tabId === undefined) return
      const target = targets.get(tabId)
      if (target?.webContentsId === event.webContentsId && apply(tabId, target, event)) return
      // Native popups can be detected before React adopts them. Keep their
      // results pending until createPage confirms the exact native identity.
      const key = JSON.stringify([tabId, event.webContentsId, event.sourceWebContentsId, event.documentId])
      pending.delete(key)
      pending.set(key, { tabId, session: sessionFor(tabId), event })
      while (pending.size > MAX_PENDING) pending.delete(pending.keys().next().value!)
    }
  }
}

const forwarding = createBrowserAuthForwarder(
  () => useBrowserGuests.getState().liveGuests,
  (tabId, url) => useBrowserGuests.getState().setAuthFallback(tabId, url)
)

export const registerBrowserAuthGuest = forwarding.register
export const retireBrowserAuthGuest = forwarding.retire

export function installBrowserAuthForwarding(): () => void {
  forwarding.reconcile()
  const unsubscribeAuth = onPush('browser:external-auth', forwarding.receive)
  const unsubscribeGuests = useBrowserGuests.subscribe(forwarding.reconcile)
  return () => { unsubscribeAuth(); unsubscribeGuests() }
}
