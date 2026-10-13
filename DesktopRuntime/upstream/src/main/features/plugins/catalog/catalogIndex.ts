import { isValidSemver } from '../../../../shared/plugins/semver'
import {
  CATALOG_INDEX_FORMAT,
  CATALOG_INDEX_VERSION,
  type CatalogEntry
} from '../../../../shared/types/pluginCatalog'
import {
  PLUGIN_ID_MAX_LENGTH,
  PLUGIN_ID_PATTERN
} from '../../../../shared/types/plugin'
import { ValidationError } from '../../../db/errors'

interface CatalogIndex {
  name: string
  entries: CatalogEntry[]
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isBoundedString(value: unknown, maxLength: number): value is string {
  return typeof value === 'string' && Array.from(value).length <= maxLength
}

function parseTags(value: unknown): readonly string[] | null {
  if (!Array.isArray(value) || value.length > 8) return null
  if (!value.every((tag) => isBoundedString(tag, 24))) return null
  return value
}

function resolveArtifactUrl(value: unknown, sourceUrl: string, marketplace: string | null): string | null {
  if (typeof value !== 'string') return null
  try {
    const resolved = new URL(value, sourceUrl)
    if (resolved.username || resolved.password) return null
    return resolved.protocol === 'https:' || (marketplace !== null && sourceUrl === `${marketplace}/index.json` && resolved.origin === marketplace)
      ? resolved.href : null
  } catch {
    return null
  }
}

function parseEntry(
  raw: unknown,
  sourceUrl: string,
  official: boolean,
  marketplace: string | null
): CatalogEntry | null {
  if (!isRecord(raw)) return null
  const tags = parseTags(raw['tags'])
  const url = resolveArtifactUrl(raw['url'], sourceUrl, marketplace)
  if (
    typeof raw['id'] !== 'string' ||
    raw['id'].length > PLUGIN_ID_MAX_LENGTH ||
    !PLUGIN_ID_PATTERN.test(raw['id']) ||
    (raw['kind'] !== 'extension' && raw['kind'] !== 'pack') ||
    !isBoundedString(raw['name'], 80) ||
    !isBoundedString(raw['publisher'], 80) ||
    !isBoundedString(raw['description'], 300) ||
    tags === null ||
    !isValidSemver(raw['version']) ||
    !isValidSemver(raw['minAppVersion']) ||
    url === null ||
    typeof raw['sha256'] !== 'string' ||
    !/^[0-9a-f]{64}$/.test(raw['sha256'])
  ) {
    return null
  }
  return {
    id: raw['id'],
    kind: raw['kind'],
    name: raw['name'],
    publisher: raw['publisher'],
    description: raw['description'],
    tags,
    version: raw['version'].trim(),
    minAppVersion: raw['minAppVersion'].trim(),
    url,
    sha256: raw['sha256'],
    sourceUrl,
    verified: official
  }
}

/** Parses one source index, dropping bad entries while rejecting a bad envelope. */
export function parseCatalogIndex(
  text: string,
  sourceUrl: string,
  official: boolean,
  marketplace: string | null = null
): CatalogIndex {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    throw new ValidationError('카탈로그 index.json을 읽을 수 없습니다.')
  }
  if (
    !isRecord(raw) ||
    raw['format'] !== CATALOG_INDEX_FORMAT ||
    raw['version'] !== CATALOG_INDEX_VERSION ||
    typeof raw['name'] !== 'string' ||
    !Array.isArray(raw['entries'])
  ) {
    throw new ValidationError('카탈로그 index.json 형식이 올바르지 않습니다.')
  }

  const seen = new Set<string>()
  const entries = raw['entries'].flatMap((candidate) => {
    const entry = parseEntry(candidate, sourceUrl, official, marketplace)
    if (entry === null || seen.has(entry.id)) return []
    seen.add(entry.id)
    return [entry]
  })
  return { name: raw['name'], entries }
}
