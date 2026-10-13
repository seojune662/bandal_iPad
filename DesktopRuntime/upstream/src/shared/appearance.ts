/**
 * The text and density preferences, applied as attributes /
 * a custom property on `<html>` so CSS can switch on them:
 *
 * - `--font-scale` → `html { font-size: calc(100% * var(--font-scale)) }`
 *   (styles/base.css). Every rem token follows, like browser zoom. The note
 *   editor's per-note `--note-font-scale` multiplies on top of it.
 * - `data-editor-font` → swaps the note editor's family only (styles/base.css).
 * - `data-density` → `:root[data-density='compact']` re-cuts the spacing,
 *   radius and chrome tokens (styles/tokens.css).
 *
 * Shared by the main window (stores/uiStore.ts) and the settings window
 * (features/settings/settingsTheme.ts) so the two never drift.
 */

import type { Settings } from './types/settings'

export type AppearanceKnobs = Pick<Settings, 'fontScale' | 'editorFont' | 'density'>

/** The four settings keys the Appearance panel saves as one unit. */
export type AppearanceSettings = Pick<
  Settings,
  'theme' | 'fontScale' | 'editorFont' | 'density'
>

export function pickAppearance(settings: AppearanceSettings): AppearanceSettings {
  return {
    theme: settings.theme,
    fontScale: settings.fontScale,
    editorFont: settings.editorFont,
    density: settings.density
  }
}

export function isSameAppearance(
  a: AppearanceSettings,
  b: AppearanceSettings
): boolean {
  return (
    a.theme === b.theme &&
    a.fontScale === b.fontScale &&
    a.editorFont === b.editorFont &&
    a.density === b.density
  )
}

/**
 * Structural stand-in for `HTMLElement` — src/shared compiles without the DOM
 * lib. `document.documentElement` satisfies it as-is.
 */
export interface AppearanceRoot {
  dataset: Record<string, string | undefined>
  style: { setProperty(name: string, value: string): void }
}

export function applyAppearanceKnobs(
  root: AppearanceRoot,
  knobs: AppearanceKnobs
): void {
  root.dataset['density'] = knobs.density
  root.dataset['editorFont'] = knobs.editorFont
  root.style.setProperty('--font-scale', String(knobs.fontScale))
}
