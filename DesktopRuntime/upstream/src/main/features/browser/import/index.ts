import { randomUUID } from 'node:crypto'
import { homedir } from 'node:os'
import type { SaveLoginInput } from '../../../../shared/types/credentials'
import type { BrowserImportConflict, BrowserImportCounts, BrowserImportFileKind, BrowserImportItem, BrowserImportJob, BrowserImportRequest, BrowserImportSource } from '../../../../shared/types/browserImport'
import type { ImportedBookmark } from '../browserImport'
import { nativeSecretHelper, type SecretHelper } from './crypto'
import { discoverImportSources, fileImportSource, type PrivateImportSource } from './discovery'
import { readImportFile, readProfile } from './readers'
import { checkCancelled, ImportReadError, type ImportedCookie, type ImportedHistoryEntry, type ImportDisposition, type ImportPayload } from './types'

export type { ImportedCookie, ImportedHistoryEntry, ImportDisposition } from './types'
export interface ExistingImportCookie {
  domain: string
  hostOnly?: boolean
  path: string
  name: string
  value: string
  secure: boolean
  httpOnly: boolean
  sameSite?: string
  expirationDate?: number
  partitionKey?: unknown
}

export interface BrowserImportSinks {
  passwords(profileId: string, entries: SaveLoginInput[], conflict: BrowserImportConflict): Promise<BrowserImportCounts> | BrowserImportCounts
  bookmark(profileId: string, entry: ImportedBookmark, conflict: BrowserImportConflict): Promise<ImportDisposition> | ImportDisposition
  history(profileId: string, entries: ImportedHistoryEntry[], conflict: BrowserImportConflict): Promise<BrowserImportCounts> | BrowserImportCounts
  cookies(profileId: string): {
    get(filter: Record<string, never>): Promise<ExistingImportCookie[]>
    set(cookie: ImportedCookie): Promise<void>
    flushStore?(): Promise<void>
  }
}

export interface BrowserImportService {
  discover(): Promise<BrowserImportSource[]>
  registerFile(path: string, kind: BrowserImportFileKind): Promise<BrowserImportSource>
  start(request: BrowserImportRequest): BrowserImportJob
  get(jobId: string): BrowserImportJob | null
  cancel(jobId: string): boolean
  isProfileBusy(profileId: string): boolean
  subscribe(listener: (job: BrowserImportJob) => void): () => void
  dispose(): void
}

const ITEMS: BrowserImportItem[] = ['bookmarks', 'history', 'cookies', 'passwords']
const counts = (): BrowserImportCounts => ({ imported: 0, kept: 0, unsupported: 0, failed: 0 })
const results = (): BrowserImportJob['results'] => ({ bookmarks: counts(), history: counts(), cookies: counts(), passwords: counts() })
const yieldMain = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))

function cookieKey(cookie: Pick<ExistingImportCookie, 'domain' | 'hostOnly' | 'name' | 'path'>): string {
  return JSON.stringify([cookie.domain.replace(/^\./, '').toLowerCase(), cookie.hostOnly ?? !cookie.domain.startsWith('.'), cookie.path, cookie.name])
}
function importedCookieKey(cookie: ImportedCookie): string {
  return cookieKey({ domain: cookie.domain ?? new URL(cookie.url).hostname, hostOnly: cookie.domain === undefined, name: cookie.name, path: cookie.path })
}

export function createBrowserImportService(options: {
  helperPath: string
  sinks: BrowserImportSinks
  platform?: NodeJS.Platform
  homeDir?: string
  localAppData?: string
  appData?: string
  /** Injection points are used with synthetic profiles; never renderer arguments. */
  helper?: SecretHelper
  now?: () => number
}): BrowserImportService {
  const platform = options.platform ?? process.platform
  const sources = new Map<string, PrivateImportSource>()
  const jobs = new Map<string, { public: BrowserImportJob; abort: AbortController }>()
  const listeners = new Set<(job: BrowserImportJob) => void>()
  const helper = options.helper ?? nativeSecretHelper(options.helperPath)
  let disposed = false
  const publish = (job: BrowserImportJob): void => {
    if (disposed) return
    for (const listener of listeners) { try { listener(structuredClone(job)) } catch { /* One closed window cannot abort an import. */ } }
  }
  function register(source: PrivateImportSource): BrowserImportSource {
    const existing = [...sources.values()].find((entry) => entry.path === source.path && entry.public.kind === source.public.kind)
    if (existing) return structuredClone(existing.public)
    sources.set(source.public.id, source)
    return structuredClone(source.public)
  }
  async function apply(job: BrowserImportJob, payload: ImportPayload, request: BrowserImportRequest, signal: AbortSignal): Promise<void> {
    job.total = request.items.reduce((sum, item) => sum + payload[item].length + (payload.unsupported[item] ?? 0) + (payload.failed[item] ?? 0), 0)
    job.messages = [...new Set(payload.messages)]
    for (const item of request.items) {
      checkCancelled(signal)
      job.currentItem = item
      job.results[item].unsupported += payload.unsupported[item] ?? 0
      job.results[item].failed += payload.failed[item] ?? 0
      job.processed += (payload.unsupported[item] ?? 0) + (payload.failed[item] ?? 0)
      publish(job)
      try {
        if (item === 'passwords' || item === 'history') {
          const entries = payload[item]
          if (entries.length === 0) continue
          await yieldMain()
          checkCancelled(signal)
          const result = item === 'passwords'
            ? await options.sinks.passwords(request.targetProfileId, payload.passwords, request.conflict)
            : await options.sinks.history(request.targetProfileId, payload.history, request.conflict)
          for (const key of ['imported', 'kept', 'unsupported', 'failed'] as const) job.results[item][key] += result[key]
          job.processed += entries.length
        } else if (item === 'bookmarks') {
          for (let index = 0; index < payload.bookmarks.length; index += 1) {
            checkCancelled(signal)
            if (index % 50 === 0) { publish(job); await yieldMain(); checkCancelled(signal) }
            let disposition: ImportDisposition
            try { disposition = await options.sinks.bookmark(request.targetProfileId, payload.bookmarks[index]!, request.conflict) } catch { disposition = 'failed' }
            job.results.bookmarks[disposition] += 1
            job.processed += 1
          }
        } else if (payload.cookies.length > 0) {
          const target = options.sinks.cookies(request.targetProfileId)
          const existing = new Map((await target.get({})).filter((cookie) => cookie.partitionKey === undefined).map((cookie) => [cookieKey(cookie), cookie]))
          for (let index = 0; index < payload.cookies.length; index += 1) {
            checkCancelled(signal)
            if (index % 50 === 0) { publish(job); await yieldMain(); checkCancelled(signal) }
            const cookie = payload.cookies[index]!
            const key = importedCookieKey(cookie)
            const previous = existing.get(key)
            if (previous && (request.conflict === 'keep' || previous.value === cookie.value && previous.secure === cookie.secure && previous.httpOnly === cookie.httpOnly && previous.sameSite === cookie.sameSite && previous.expirationDate === cookie.expirationDate)) job.results.cookies.kept += 1
            else {
              try {
                await target.set(cookie)
                job.results.cookies.imported += 1
                existing.set(key, { ...cookie, domain: cookie.domain ?? new URL(cookie.url).hostname, hostOnly: cookie.domain === undefined })
              } catch { job.results.cookies.failed += 1 }
            }
            job.processed += 1
          }
          await target.flushStore?.()
        }
      } catch (error) {
        if (signal.aborted) throw new ImportReadError('cancelled')
        const unprocessed = Math.max(0, payload[item].length - (job.results[item].imported + job.results[item].kept + job.results[item].failed - (payload.failed[item] ?? 0)))
        job.results[item].failed += unprocessed
        job.processed += unprocessed
        job.messages.push('일부 항목을 저장하지 못했습니다. 결과를 확인한 뒤 다시 시도해 주세요.')
      }
      publish(job)
    }
  }
  return {
    async discover() {
      if (disposed) return []
      const found = await discoverImportSources({ platform, homeDir: options.homeDir ?? homedir(), ...(options.localAppData ?? process.env.LOCALAPPDATA ? { localAppData: options.localAppData ?? process.env.LOCALAPPDATA! } : {}), ...(options.appData ?? process.env.APPDATA ? { appData: options.appData ?? process.env.APPDATA! } : {}) })
      return found.map(register)
    },
    async registerFile(path, kind) {
      if (disposed || !['passwords-csv', 'bookmarks-html', 'safari-zip'].includes(kind)) throw new TypeError('지원하지 않는 가져오기 파일입니다.')
      return register(fileImportSource(path, kind, platform))
    },
    start(request) {
      if (disposed) throw new Error('가져오기가 종료되었습니다.')
      const source = sources.get(request.sourceId)
      if (!source) throw new TypeError('원본을 다시 선택해 주세요.')
      if (typeof request.targetProfileId !== 'string' || request.targetProfileId.length === 0 || request.targetProfileId.length > 128) throw new TypeError('대상 프로필을 선택해 주세요.')
      if (!Array.isArray(request.items) || request.items.length === 0 || request.items.length > 4 || !request.items.every((item) => ITEMS.includes(item)) || !['keep', 'replace'].includes(request.conflict)) throw new TypeError('가져올 항목을 확인해 주세요.')
      if ([...jobs.values()].some((job) => job.public.state === 'running' && job.public.targetProfileId === request.targetProfileId)) throw new Error('이 프로필의 가져오기가 진행 중입니다.')
      const normalized = { ...request, items: [...new Set(request.items)] }
      const job: BrowserImportJob = { id: randomUUID(), sourceId: source.public.id, targetProfileId: request.targetProfileId, state: 'running', currentItem: null, processed: 0, total: null, results: results(), messages: [] }
      const abort = new AbortController()
      jobs.set(job.id, { public: job, abort })
      for (const [id, older] of jobs) if (jobs.size > 20 && older.public.state !== 'running') jobs.delete(id)
      void (async () => {
        let payload: ImportPayload | undefined
        try {
          await yieldMain()
          checkCancelled(abort.signal)
          const now = (options.now ?? Date.now)()
          payload = source.public.kind === 'profile'
            ? await readProfile(source, normalized.items, { platform, helper, signal: abort.signal, now, onItem(item) { job.currentItem = item; publish(job) } })
            : await readImportFile(source, normalized.items, abort.signal, now)
          checkCancelled(abort.signal)
          await apply(job, payload, normalized, abort.signal)
          checkCancelled(abort.signal)
          job.state = 'completed'
        } catch (error) {
          job.state = abort.signal.aborted ? 'cancelled' : 'failed'
          job.messages.push(job.state === 'cancelled' ? '가져오기를 취소했습니다. 이미 가져온 항목은 유지됩니다.' : error instanceof ImportReadError && error.reason === 'permission' ? '원본 파일 접근이 허용되지 않았습니다.' : '원본 데이터를 읽을 수 없습니다. 파일 형식과 접근 권한을 확인해 주세요.')
        } finally {
          // Drop secret references immediately; completed jobs contain counts only.
          if (payload) { for (const item of payload.passwords) item.password = ''; for (const cookie of payload.cookies) cookie.value = ''; payload.passwords.length = 0; payload.cookies.length = 0 }
          job.currentItem = null
          job.messages = [...new Set(job.messages)]
          publish(job)
        }
      })()
      return structuredClone(job)
    },
    get(jobId) { const job = jobs.get(jobId); return job ? structuredClone(job.public) : null },
    cancel(jobId) { const job = jobs.get(jobId); if (!job || job.public.state !== 'running') return false; job.abort.abort(); return true },
    isProfileBusy(profileId) { return [...jobs.values()].some((job) => job.public.state === 'running' && job.public.targetProfileId === profileId) },
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener) },
    dispose() { disposed = true; for (const job of jobs.values()) if (job.public.state === 'running') job.abort.abort(); listeners.clear(); sources.clear() }
  }
}
