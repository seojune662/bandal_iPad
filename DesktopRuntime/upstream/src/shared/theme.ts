/** Neutral application themes. Legacy values are accepted only at the settings boundary. */
export type ThemeId = 'light' | 'dark'
export type ThemeBase = ThemeId
export type ResolvedTheme = ThemeId

/** Retained for stored settings and plugin compatibility; never applied to UI. */
export type PaletteId =
  | 'bandal'
  | 'ink'
  | 'lavender'
  | 'moss'
  | 'catppuccin'
  | 'minimal'
export const DEFAULT_PALETTE_ID: PaletteId = 'bandal'
export function isPaletteId(value: unknown): value is PaletteId {
  return [
    'bandal',
    'ink',
    'lavender',
    'moss',
    'catppuccin',
    'minimal'
  ].includes(value as string)
}

export interface ThemeDefinition {
  id: ThemeId
  name: string
  description: string
  base: ThemeBase
  windowBackground: string
}
export const THEMES: readonly ThemeDefinition[] = [
  {
    id: 'light',
    name: '라이트',
    description: '밝고 선명한 화면',
    base: 'light',
    windowBackground: '#ffffff'
  },
  {
    id: 'dark',
    name: '다크',
    description: '차분한 어두운 화면',
    base: 'dark',
    windowBackground: '#212121'
  }
]
export const DEFAULT_THEME_ID = 'system' as const
export const SYSTEM_THEME: Record<ThemeBase, ThemeId> = {
  dark: 'dark',
  light: 'light'
}
export function isThemeId(value: unknown): value is ThemeId {
  return value === 'light' || value === 'dark'
}
export function normalizeThemePreference(
  value: unknown,
  fallback: ThemeId | 'system' = 'system'
): ThemeId | 'system' {
  if (value === 'system' || isThemeId(value)) return value
  if (value === 'sepia' || value === 'high-contrast') return 'light'
  if (value === 'midnight' || value === 'graphite') return 'dark'
  return fallback
}
export function getTheme(id: ThemeId): ThemeDefinition {
  return THEMES.find((theme) => theme.id === id) ?? THEMES[0]!
}
export function resolveThemeId(
  preference: ThemeId | 'system',
  prefersDark: boolean
): ThemeId {
  return preference === 'system' ? (prefersDark ? 'dark' : 'light') : preference
}
/** Palette parameter is a compatibility seam for existing native window callers. */
export function resolveWindowBackground(
  preference: ThemeId | 'system',
  _palette: PaletteId,
  prefersDark: boolean
): string {
  return getTheme(resolveThemeId(preference, prefersDark)).windowBackground
}
export function resolveWindowSymbolColor(
  preference: ThemeId | 'system',
  prefersDark: boolean
): string {
  return resolveThemeId(preference, prefersDark) === 'dark'
    ? '#ececec'
    : '#0d0d0d'
}
