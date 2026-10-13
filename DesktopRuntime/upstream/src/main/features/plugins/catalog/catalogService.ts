import { existsSync, mkdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { isValidSemver } from '../../../../shared/plugins/semver'
import {
  OFFICIAL_CATALOG_URL,
  type CatalogEntry,
  type CatalogSource,
  type PluginCatalog
} from '../../../../shared/types/pluginCatalog'
import { PLUGIN_ID_PATTERN } from '../../../../shared/types/plugin'
import { writeFileAtomic } from '../../../lib/atomicWrite'
import { parseCatalogIndex } from './catalogIndex'

const CATALOG_CACHE_FILE = 'plugin-catalog.json'
const CATALOG_INDEX_MAX_BYTES = 1024 * 1024

export type CatalogFetch = (
  url: string,
  init: { signal: AbortSignal }
) => Promise<Response>

export interface CatalogService {
  get(refresh: boolean): Promise<PluginCatalog>
  current(): PluginCatalog | null
}

interface CatalogServiceDeps {
  userDataDir: string
  getPluginSources(): readonly string[]
  getMarketplaceUrl?(): string | null
  fetch: CatalogFetch
  now?: () => Date
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isIsoOrNull(value: unknown): value is string | null {
  return (
    value === null ||
    (typeof value === 'string' && Number.isFinite(Date.parse(value)))
  )
}

function isHttpsUrl(value: unknown): value is string {
  if (typeof value !== 'string') return false
  try {
    return new URL(value).protocol === 'https:'
  } catch {
    return false
  }
}

function isCachedSource(value: unknown): value is CatalogSource {
  if (!isRecord(value)) return false
  return (
    isHttpsUrl(value['url']) &&
    typeof value['official'] === 'boolean' &&
    (value['status'] === 'ok' || value['status'] === 'error') &&
    (value['error'] === null || typeof value['error'] === 'string') &&
    isIsoOrNull(value['fetchedAt']) &&
    typeof value['entryCount'] === 'number' &&
    Number.isInteger(value['entryCount']) &&
    value['entryCount'] >= 0
  )
}

function isCachedEntry(value: unknown): value is CatalogEntry {
  if (!isRecord(value)) return false
  const tags = value['tags']
  return (
    typeof value['id'] === 'string' &&
    PLUGIN_ID_PATTERN.test(value['id']) &&
    (value['kind'] === 'extension' || value['kind'] === 'pack') &&
    typeof value['name'] === 'string' &&
    typeof value['publisher'] === 'string' &&
    typeof value['description'] === 'string' &&
    Array.isArray(tags) &&
    tags.every((tag: unknown) => typeof tag === 'string') &&
    isValidSemver(value['version']) &&
    (value['minAppVersion'] === null || isValidSemver(value['minAppVersion'])) &&
    isHttpsUrl(value['url']) &&
    typeof value['sha256'] === 'string' &&
    /^[0-9a-f]{64}$/.test(value['sha256']) &&
    isHttpsUrl(value['sourceUrl']) &&
    typeof value['verified'] === 'boolean'
  )
}

function parseCachedCatalog(text: string): PluginCatalog {
  const raw: unknown = JSON.parse(text)
  if (
    !isRecord(raw) ||
    !Array.isArray(raw['sources']) ||
    !Array.isArray(raw['entries'])
  ) {
    throw new TypeError('invalid plugin catalog cache')
  }
  const sources: unknown[] = raw['sources']
  const entries: unknown[] = raw['entries']
  if (
    !sources.every(isCachedSource) ||
    !entries.every(isCachedEntry) ||
    !isIsoOrNull(raw['fetchedAt'])
  ) {
    throw new TypeError('invalid plugin catalog cache')
  }
  const sourceUrls = new Set(sources.map((source) => source.url))
  if (
    entries.some(
      (entry) =>
        !sourceUrls.has(entry.sourceUrl) ||
        entry.verified !== (entry.sourceUrl === OFFICIAL_CATALOG_URL)
    )
  ) {
    throw new TypeError('invalid plugin catalog cache')
  }
  return { sources, entries, fetchedAt: raw['fetchedAt'] }
}

async function readLimited(response: Response): Promise<string> {
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const declared = Number(response.headers.get('content-length'))
  if (Number.isFinite(declared) && declared > CATALOG_INDEX_MAX_BYTES) {
    throw new Error('카탈로그가 1MB를 초과합니다.')
  }
  if (response.body === null) return ''

  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  let size = 0
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    size += value.byteLength
    if (size > CATALOG_INDEX_MAX_BYTES) {
      await reader.cancel()
      throw new Error('카탈로그가 1MB를 초과합니다.')
    }
    chunks.push(value)
  }
  return Buffer.concat(chunks.map((chunk) => Buffer.from(chunk))).toString('utf8')
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

async function fetchSource(
  deps: CatalogServiceDeps,
  url: string
): Promise<{ source: CatalogSource; entries: CatalogEntry[] }> {
  const official = url === OFFICIAL_CATALOG_URL
  try {
    const response = await deps.fetch(url, {
      signal: AbortSignal.timeout(10_000)
    })
    const parsed = parseCatalogIndex(await readLimited(response), url, official, deps.getMarketplaceUrl?.() ?? null)
    const fetchedAt = (deps.now ?? (() => new Date()))().toISOString()
    return {
      source: {
        url,
        official,
        status: 'ok',
        error: null,
        fetchedAt,
        entryCount: parsed.entries.length
      },
      entries: parsed.entries
    }
  } catch (error) {
    return {
      source: {
        url,
        official,
        status: 'error',
        error: errorMessage(error),
        fetchedAt: null,
        entryCount: 0
      },
      entries: []
    }
  }
}

async function fetchCatalog(deps: CatalogServiceDeps): Promise<PluginCatalog> {
  const urls = [...new Set([OFFICIAL_CATALOG_URL, ...deps.getPluginSources()])]
  const fetched = await Promise.all(urls.map((url) => fetchSource(deps, url)))
  const successfulTimes = fetched.flatMap(({ source }) =>
    source.fetchedAt === null ? [] : [source.fetchedAt]
  )
  return {
    sources: fetched.map(({ source }) => source),
    entries: fetched.flatMap(({ entries }) => entries),
    fetchedAt: successfulTimes.sort().at(-1) ?? null
  }
}

function readCache(cachePath: string): PluginCatalog | null {
  if (!existsSync(cachePath)) return null
  try {
    return parseCachedCatalog(readFileSync(cachePath, 'utf8'))
  } catch {
    return null
  }
}

export function createCatalogService(deps: CatalogServiceDeps): CatalogService {
  const cachePath = join(deps.userDataDir, CATALOG_CACHE_FILE)
  let latest: PluginCatalog | null = null
  function annotate(catalog: PluginCatalog): PluginCatalog {
    const marketplace = deps.getMarketplaceUrl?.()
    return { ...catalog, entries: catalog.entries.map((entry) => {
      const { marketplaceReleaseId: _untrusted, ...clean } = entry
      if (!marketplace || entry.sourceUrl !== `${marketplace}/index.json`) return clean
      const url = new URL(entry.url)
      const match = /^\/releases\/([0-9a-f-]{36})\/download$/.exec(url.pathname)
      return url.origin === marketplace && match ? { ...clean, marketplaceReleaseId: match[1]! } : clean
    }) }
  }

  return {
    async get(refresh) {
      if (!refresh) {
        const cached = latest ?? readCache(cachePath)
        if (cached !== null) {
          latest = annotate(cached)
          return latest
        }
      }
      const catalog = annotate(await fetchCatalog(deps))
      latest = catalog
      mkdirSync(deps.userDataDir, { recursive: true })
      writeFileAtomic(cachePath, `${JSON.stringify(catalog, null, 2)}\n`, {
        mode: 0o600
      })
      return catalog
    },
    current: () => latest
  }
}
