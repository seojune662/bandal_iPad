/**
 * Search engines, in `shared/` because both the renderer's omnibox and the
 * main-process settings validator need the same list — a value the sanitizer
 * does not know about is silently dropped on save.
 */

export const SEARCH_ENGINES = {
  google: 'https://www.google.com/search?q=',
  // Naver matters here: for a lot of Korean queries Google simply has less.
  naver: 'https://search.naver.com/search.naver?query=',
  daum: 'https://search.daum.net/search?q=',
  duckduckgo: 'https://duckduckgo.com/?q='
} as const

export type SearchEngineId = keyof typeof SEARCH_ENGINES

export const DEFAULT_SEARCH_ENGINE: SearchEngineId = 'google'

export function isSearchEngineId(value: unknown): value is SearchEngineId {
  return (
    typeof value === 'string' &&
    Object.prototype.hasOwnProperty.call(SEARCH_ENGINES, value)
  )
}

/** Korean display names for the settings picker. */
export const SEARCH_ENGINE_NAMES: Record<SearchEngineId, string> = {
  google: '구글',
  naver: '네이버',
  daum: '다음',
  duckduckgo: '덕덕고'
}
