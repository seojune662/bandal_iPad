import { randomUUID } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { app, session, type Session } from 'electron'
import Database from 'better-sqlite3'
import { writeFileAtomic, quarantineFile } from '../../lib/atomicWrite'
import { runtimeSafeStorage } from '../../lib/safeStorageGate'
import { createCredentialStore } from '../credentials/credentialStore'
import { createHistoryRepo } from './historyRepo'
import { createPermissionsRepo } from './permissionsRepo'
import { createBrowserSessionStore } from './sessionStore'
import { forgetGoogleAccountNavigation } from './googleAccountNavigation'
import { BROWSING_PARTITION, PRIVATE_BROWSING_PARTITION } from './webviewPolicy'
import { PROFILE_COLORS, type BrowserProfile } from '../../../shared/types/browserProfile'

let profiles: BrowserProfile[] | undefined
let defaultDb: Database.Database
const databases = new Map<string, Database.Database>()
const resources = new Map<string, ReturnType<typeof buildResources>>()
const listeners = new Set<(partition: string, profileId: string) => void>()
const activeDownloads = new Map<string, number>()
const initialized = new Map<string, string>()
const downloadListeners = new Map<string, (event: Electron.Event, item: Electron.DownloadItem) => void>()
const deletedListeners = new Set<(id: string, partitions: readonly string[]) => void>()
const privateDownloads = new Map<string, number>()
const privateCleanup = new Map<string, Promise<void>>()
const deleting = new Set<string>()
const guestProfiles = new Map<number, { profileId: string; isPrivate: boolean }>()
const file = (): string => join(app.getPath('userData'), 'browser-profiles.json')
export const profileDirectory = (id: string): string => join(app.getPath('userData'), 'browser-profiles', requireProfile(id).id)
export function listBrowserProfiles(): BrowserProfile[] {
  if (!profiles) {
    profiles = [{ id: 'default', name: '기본', color: PROFILE_COLORS[0], icon: '●' }]
    if (existsSync(file())) {
      try {
      const raw: unknown = JSON.parse(readFileSync(file(), 'utf8'))
      if (!Array.isArray(raw)) throw new Error('브라우저 프로필 파일을 읽을 수 없습니다.')
      profiles = raw.filter((p): p is BrowserProfile => p && typeof p === 'object' &&
        (p.id === 'default' || /^[a-f0-9-]{36}$/.test(p.id)) && typeof p.name === 'string' &&
        PROFILE_COLORS.includes(p.color) && typeof p.icon === 'string')
      } catch (error) {
        quarantineFile(file())
        console.warn('[browser] Restoring profile metadata from retained folders', error)
        profiles = [{ id: 'default', name: '기본', color: PROFILE_COLORS[0], icon: '●' }]
        const root = join(app.getPath('userData'), 'browser-profiles')
        if (existsSync(root)) for (const id of readdirSync(root).filter(id => /^[a-f0-9-]{36}$/.test(id))) {
          profiles.push({ id, name: `복구된 프로필 ${profiles.length}`, color: PROFILE_COLORS[0], icon: '●' })
        }
        writeFileAtomic(file(), JSON.stringify(profiles))
      }
      if (!profiles.some(p => p.id === 'default')) profiles.unshift({ id: 'default', name: '기본', color: PROFILE_COLORS[0], icon: '●' })
    }
  }
  return profiles.map(p => ({ ...p }))
}
export function requireProfile(id = 'default'): BrowserProfile {
  if (deleting.has(id)) throw new Error('삭제 중인 브라우저 프로필입니다.')
  const p = listBrowserProfiles().find(p => p.id === id)
  if (!p) throw new Error('삭제되었거나 존재하지 않는 브라우저 프로필입니다.')
  return p
}
export function saveBrowserProfile(input: { id?: string; name: string; color: string; icon: string }): BrowserProfile {
  if (typeof input.name !== 'string' || typeof input.icon !== 'string') throw new Error('프로필 입력이 올바르지 않습니다.')
  const name = input.name.trim().slice(0, 40)
  if (!name || !PROFILE_COLORS.includes(input.color as typeof PROFILE_COLORS[number])) throw new Error('프로필 이름과 색상을 확인해 주세요.')
  const all = listBrowserProfiles()
  if (!input.id && all.length >= 100) throw new Error('프로필은 최대 100개까지 만들 수 있습니다.')
  const p = { id: input.id ? requireProfile(input.id).id : randomUUID(), name, color: input.color, icon: [...String(input.icon)].slice(0, 2).join('') || '●' }
  const next = all.filter(item => item.id !== p.id).concat(p)
  writeFileAtomic(file(), JSON.stringify(next))
  profiles = next
  return p
}
export function profilePartition(id = 'default', isPrivate = false): string {
  requireProfile(id)
  if (id === 'default') return isPrivate ? PRIVATE_BROWSING_PARTITION : BROWSING_PARTITION
  return `${isPrivate ? '' : 'persist:'}bandal-profile-${id}${isPrivate ? '-private' : ''}`
}
export function initializeBrowserProfiles(db: Database.Database): void { defaultDb = db }
export function onBrowserSession(callback: (partition: string, id: string) => void): void {
  for (const [partition, id] of initialized) callback(partition, id)
  listeners.add(callback)
}
export function ensureProfileSession(id = 'default', isPrivate = false): Session {
  const partition = profilePartition(id, isPrivate)
  if (!initialized.has(partition)) {
    initialized.set(partition, id)
    const trackDownload = (_event: Electron.Event, item: Electron.DownloadItem): void => {
      activeDownloads.set(id, (activeDownloads.get(id) ?? 0) + 1)
      if (isPrivate) privateDownloads.set(id, (privateDownloads.get(id) ?? 0) + 1)
      item.once('done', () => {
        activeDownloads.set(id, Math.max(0, (activeDownloads.get(id) ?? 1) - 1))
        if (isPrivate) {
          privateDownloads.set(id, Math.max(0, (privateDownloads.get(id) ?? 1) - 1))
          clearUnusedPrivateSession(id)
        }
      })
    }
    try { for (const callback of listeners) callback(partition, id) }
    catch (error) { initialized.delete(partition); throw error }
    session.fromPartition(partition).on('will-download', trackDownload)
    downloadListeners.set(partition, trackDownload)
  }
  return session.fromPartition(partition)
}
function buildResources(id: string) {
  const directory = id === 'default' ? app.getPath('userData') : profileDirectory(id)
  mkdirSync(directory, { recursive: true })
  let db = defaultDb
  if (id !== 'default') {
    db = new Database(join(directory, 'browser.sqlite'))
    db.pragma('journal_mode = WAL')
    for (const table of ['browser_history', 'browser_permissions']) {
      const schema = defaultDb.prepare('SELECT sql FROM sqlite_master WHERE type = ? AND name = ?').get('table', table) as { sql: string }
      db.exec(schema.sql.replace(/CREATE TABLE(?: IF NOT EXISTS)?/, 'CREATE TABLE IF NOT EXISTS'))
    }
    db.exec('CREATE INDEX IF NOT EXISTS history_visited ON browser_history(last_visited_at DESC)')
    databases.set(id, db)
  }
  const ses = session.fromPartition(profilePartition(id))
  const cookies = id === 'default' ? createBrowserSessionStore() : createBrowserSessionStore({ session: ses, app })
  cookies.startFlushOnQuit()
  const history = createHistoryRepo(db)
  history.prune()
  return { history, permissions: createPermissionsRepo(db), cookies,
    credentials: id === 'default' ? createCredentialStore() : createCredentialStore({ safeStorage: runtimeSafeStorage(), userDataPath: directory }) }
}
export function browserProfileResources(id = 'default'): ReturnType<typeof buildResources> {
  requireProfile(id)
  if (!resources.has(id)) resources.set(id, buildResources(id))
  return resources.get(id)!
}
export function resetBrowserProfileQuit(): void {
  for (const resource of resources.values()) resource.cookies.resetQuitState()
}
/** Called before a native page is created, so reopening cannot race private cleanup. */
export async function prepareProfileSession(id = 'default', isPrivate = false): Promise<Session> {
  requireProfile(id)
  if (isPrivate) await privateCleanup.get(id)
  return ensureProfileSession(id, isPrivate)
}
export function onBrowserProfileDeleted(callback: (id: string, partitions: readonly string[]) => void): () => void {
  deletedListeners.add(callback)
  return () => deletedListeners.delete(callback)
}
function clearUnusedPrivateSession(profileId: string): void {
  if (deleting.has(profileId) || privateCleanup.has(profileId) || (privateDownloads.get(profileId) ?? 0) > 0 ||
    [...guestProfiles.values()].some(p => p.profileId === profileId && p.isPrivate)) return
  const ses = session.fromPartition(profilePartition(profileId, true))
  forgetGoogleAccountNavigation(ses)
  const operation = (async () => {
    await ses.closeAllConnections()
    await ses.clearStorageData()
    await ses.clearCache()
    await ses.clearAuthCache()
  })().catch(() => {
    // Keep a rejected cleanup barrier: a fresh private page must never reuse old data.
    throw new Error('시크릿 세션을 정리하지 못했습니다. 앱을 다시 시작해 주세요.')
  })
  privateCleanup.set(profileId, operation)
  void operation.then(() => {
    if (privateCleanup.get(profileId) === operation) privateCleanup.delete(profileId)
  }, () => undefined)
}
export function registerGuestProfile(id: number, profileId: string, isPrivate: boolean): void { guestProfiles.set(id, { profileId, isPrivate }) }
/** Standalone site windows must keep their parent's session alive too. */
export function inheritGuestProfile(id: number, parentId: number): void {
  const parent = guestProfiles.get(parentId)
  if (parent) guestProfiles.set(id, { ...parent })
}
export function forgetGuestProfile(id: number): void {
  const previous = guestProfiles.get(id)
  guestProfiles.delete(id)
  if (previous?.isPrivate) clearUnusedPrivateSession(previous.profileId)
}
export function guestProfile(id: number): { profileId: string; isPrivate: boolean } {
  const value = guestProfiles.get(id)
  if (!value) throw new Error('브라우저 탭을 찾을 수 없습니다.')
  return value
}
export async function deleteBrowserProfile(id: string): Promise<void> {
  requireProfile(id)
  if (id === 'default') throw new Error('기본 프로필은 삭제할 수 없습니다.')
  if ((activeDownloads.get(id) ?? 0) > 0) throw new Error('다운로드가 끝난 뒤 프로필을 삭제해 주세요.')
  if ([...guestProfiles.values()].some(p => p.profileId === id)) throw new Error('이 프로필의 탭을 먼저 닫아 주세요. 진행 중인 다운로드도 완료한 뒤 삭제해 주세요.')
  const partitions = [profilePartition(id), profilePartition(id, true)]
  const data = browserProfileResources(id)
  deleting.add(id)
  try {
    for (const partition of partitions) forgetGoogleAccountNavigation(session.fromPartition(partition))
    await privateCleanup.get(id)
    for (const partition of partitions) {
      const ses = session.fromPartition(partition)
      for (const extension of ses.extensions.getAllExtensions()) ses.extensions.removeExtension(extension.id)
      await ses.clearStorageData()
      await ses.clearCache()
      await ses.clearAuthCache()
      await ses.closeAllConnections()
    }

    data.cookies.dispose()
    data.history.clear(null)
    data.permissions.forgetAll()
    databases.get(id)?.close()
    databases.delete(id)
    resources.delete(id)
    rmSync(join(app.getPath('userData'), 'browser-profiles', id), { recursive: true, force: true })
    const next = listBrowserProfiles().filter(p => p.id !== id)
    writeFileAtomic(file(), JSON.stringify(next))
    profiles = next
    for (const partition of partitions) {
      const listener = downloadListeners.get(partition)
      if (listener) session.fromPartition(partition).removeListener('will-download', listener)
      downloadListeners.delete(partition)
      initialized.delete(partition)
    }
    activeDownloads.delete(id)
    privateDownloads.delete(id)
    privateCleanup.delete(id)
    for (const callback of deletedListeners) callback(id, partitions)
  } finally { deleting.delete(id) }
}
