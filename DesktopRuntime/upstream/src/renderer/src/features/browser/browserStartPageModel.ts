import type { Favorite } from '../../../../shared/types/favorite'

/** Existing new-tab commands use this URL as their legacy blank-page marker. */
import { NEW_TAB_URL } from '../../../../shared/tabs'

/** Kept as an alias so existing browser code reads the same. */
export const LEGACY_NEW_TAB_URL = NEW_TAB_URL

export interface BrowserShortcut {
  id: string
  label: string
  url: string
}

export function hostnameForUrl(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./i, '')
  } catch {
    return url
  }
}

/** Generic document titles need a site identity, including older saved pins. */
export function browserFavoriteLabel(title: string, url: string): string {
  const label = title.trim()
  const hostname = hostnameForUrl(url)
  if (label === '') return hostname
  const normalized = label.toLocaleLowerCase().replace(/[\s\-_·:：|]+/g, '')
  if (/^(마이페이지|내페이지|홈|홈페이지|메인|메인페이지|대시보드|로그인|계정|mypage|myaccount|home|homepage|index|dashboard|login|signin|account|welcome)$/.test(normalized)) {
    return `${hostname} · ${label}`
  }
  return label
}

export function favoriteDisplayLabel(favorite: Favorite): string {
  return favorite.descriptor.kind === 'browser'
    ? browserFavoriteLabel(favorite.label, favorite.descriptor.payload.initialUrl)
    : favorite.label
}

export function initialForUrl(url: string): string {
  const hostname = hostnameForUrl(url)
  return Array.from(hostname)[0]?.toLocaleUpperCase() ?? '?'
}

export function toneForUrl(url: string): string {
  const hostname = hostnameForUrl(url)
  let hash = 0
  for (const character of hostname) {
    hash = (hash * 31 + character.charCodeAt(0)) >>> 0
  }
  return String(hash % 6)
}

export function browserFavoriteShortcuts(
  favorites: readonly Favorite[] | undefined,
  profileId?: string
): BrowserShortcut[] {
  if (favorites === undefined) return []
  const seen = new Set<string>()
  return favorites.flatMap((favorite) => {
    if (favorite.descriptor.kind !== 'browser') return []
    const payload = favorite.descriptor.payload
    const favoriteProfile = payload.profileId ?? 'default'
    if (profileId !== undefined && favoriteProfile !== profileId) return []
    // A course can pin an imported global bookmark too. Keep its course label
    // and ordering without showing the same profile/URL twice.
    const key = JSON.stringify([favoriteProfile, payload.initialUrl])
    if (seen.has(key)) return []
    seen.add(key)
    return [{ id: favorite.id, label: favoriteDisplayLabel(favorite), url: payload.initialUrl }]
  })
}

export function browserFavoriteMatches(favorite: Favorite, url: string, profileId: string): boolean {
  return favorite.descriptor.kind === 'browser' &&
    favorite.descriptor.payload.initialUrl === url &&
    (favorite.descriptor.payload.profileId ?? 'default') === profileId
}
