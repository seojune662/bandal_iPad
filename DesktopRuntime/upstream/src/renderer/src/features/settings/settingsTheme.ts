import { applyAppearanceKnobs } from '../../../../shared/appearance'
import type { AppearanceSettings } from '../../../../shared/appearance'
import { resolveThemeId } from '../../../../shared/theme'
import type { ResolvedTheme } from '../../../../shared/theme'
import type { ThemePreference } from '../../../../shared/types/settings'

export function resolveRendererTheme(theme: ThemePreference): ResolvedTheme {
  return resolveThemeId(
    theme,
    typeof window !== 'undefined' &&
      typeof window.matchMedia === 'function' &&
      window.matchMedia('(prefers-color-scheme: dark)').matches
  )
}

/** Apply the shared neutral theme and accessibility preferences before rendering. */
export function applyTheme(appearance: AppearanceSettings): ResolvedTheme {
  const resolved = resolveRendererTheme(appearance.theme)
  const root = document.documentElement
  root.dataset['theme'] = resolved
  delete root.dataset['palette']
  applyAppearanceKnobs(root, appearance)
  return resolved
}
