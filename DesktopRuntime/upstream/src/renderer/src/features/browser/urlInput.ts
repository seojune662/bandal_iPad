/**
 * [M3-F] URL-bar input resolution: URL-ish input navigates (https by
 * default), anything else becomes a search-engine query.
 */

import { addressSearchTerms, addressMatchRank } from '../../../../shared/browserSearch'
import { looksLikeUrl, normalizeUrl } from '../workspace/tabIdentity'

import {
  DEFAULT_SEARCH_ENGINE,
  SEARCH_ENGINES,
  type SearchEngineId
} from '../../../../shared/search'

export { DEFAULT_SEARCH_ENGINE, SEARCH_ENGINES }
export type { SearchEngineId }

export interface AddressDisplayParts {
  prefix: string
  domain: string
  suffix: string
  secure: boolean
}

/**
 * 표시 전용 주소 정리 — Safari/Chrome 문법을 따른다. 실제 URL 은 그대로
 * 두고(포커스하면 원문 편집), 보이는 것만 바꾼다:
 * - 퍼센트 인코딩을 디코드한다. 한글 경로가 %EC%84%9C… 로 보이면 주소가
 *   실제보다 훨씬 복잡해 보인다.
 * - https:// 스킴과 www. 접두는 숨긴다(http 는 경고 신호라 남긴다).
 * - 루트 경로의 맨끝 '/' 는 지운다.
 */
export function addressDisplayParts(url: string): AddressDisplayParts {
  try {
    const parsed = new URL(url)
    if (parsed.host.length === 0) throw new Error('No URL host')
    const secure = parsed.protocol === 'https:'
    const decode = (part: string): string => {
      try {
        return decodeURI(part)
      } catch {
        return part
      }
    }
    let suffix = decode(`${parsed.pathname}${parsed.search}${parsed.hash}`)
    if (suffix === '/') suffix = ''
    return {
      prefix: secure ? '' : `${parsed.protocol}//`,
      domain: decode(parsed.host.replace(/^www\./iu, '')),
      suffix,
      secure
    }
  } catch {
    return { prefix: '', domain: url, suffix: '', secure: false }
  }
}

/** Resolve raw URL-bar input to a loadable URL; null for empty input. */
export function resolveAddressInput(
  input: string,
  engine: SearchEngineId = DEFAULT_SEARCH_ENGINE
): string | null {
  const trimmed = input.trim()
  if (trimmed.length === 0) return null
  if (looksLikeUrl(trimmed)) return normalizeUrl(trimmed)
  const prefix = SEARCH_ENGINES[engine] ?? SEARCH_ENGINES[DEFAULT_SEARCH_ENGINE]
  return `${prefix}${encodeURIComponent(trimmed)}`
}

export type SuggestionKind = 'url' | 'search' | 'history' | 'favorite' | 'tab'

export interface AddressSuggestion {
  kind: SuggestionKind
  /** What navigating to this suggestion loads. */
  url: string
  /** Primary line: a title when we have one, else the URL. */
  label: string
  /** Secondary line: the URL, or empty when the label already is it. */
  detail: string
}

export interface SuggestionSources {
  history: ReadonlyArray<{ url: string; title: string; host: string }>
  favorites: ReadonlyArray<{ label: string; url: string }>
  /** School shortcuts — the student's own campus, so they rank like favorites. */
  services: ReadonlyArray<{ label: string; url: string }>
  openTabs: ReadonlyArray<{ title: string; url: string }>
}

const MAX_SUGGESTIONS = 8

/** The literal action stays first even when asynchronous history arrives. */
export function suggestionsFor(
  input: string,
  sources: SuggestionSources,
  engine: SearchEngineId = DEFAULT_SEARCH_ENGINE
): AddressSuggestion[] {
  const trimmed = input.trim()
  const terms = addressSearchTerms(trimmed)
  const primaryUrl = resolveAddressInput(trimmed, engine)
  const primary: AddressSuggestion[] = primaryUrl === null ? [] : [{
    kind: looksLikeUrl(trimmed) ? 'url' : 'search',
    url: primaryUrl,
    label: trimmed,
    detail: looksLikeUrl(trimmed) ? '주소로 이동' : '웹에서 검색'
  }]
  const candidates: AddressSuggestion[] = [
    ...sources.openTabs.map((tab): AddressSuggestion => ({
      kind: 'tab', url: tab.url, label: tab.title || tab.url, detail: tab.url
    })),
    ...[...sources.favorites, ...sources.services].map((item): AddressSuggestion => ({
      kind: 'favorite', url: item.url, label: item.label, detail: item.url
    })),
    ...sources.history.map((entry): AddressSuggestion => ({
      kind: 'history', url: entry.url, label: entry.title || entry.url, detail: entry.url
    }))
  ]
  const ranked = candidates
    .map((item) => ({ item, rank: addressMatchRank(item.label, item.url, terms) }))
    .filter(({ rank }) => rank !== null)
    // Stable sort preserves source priority, then the repo's frequency/recency.
    .sort((a, b) => a.rank! - b.rank!)
  const out = [...primary]
  const seen = new Set(primary.map((item) => canonicalUrl(item.url)))
  for (const { item } of ranked) {
    const key = canonicalUrl(item.url)
    if (seen.has(key)) continue
    seen.add(key)
    out.push(item)
    if (out.length === MAX_SUGGESTIONS) break
  }
  return out
}

function canonicalUrl(url: string): string {
  try { return new URL(url).href } catch { return url }
}
