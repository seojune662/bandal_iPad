import type { DrawingColor } from '../../../upstream/src/shared/types/drawing'

export interface PenPreset { color: DrawingColor; width: number; opacity: number }
export interface PalettePosition { x: number; y: number }
export interface InputPreferences { version: 2; favorites: [PenPreset, PenPreset, PenPreset]; recentPen: PenPreset; position: PalettePosition; collapsed: boolean }
const KEY = 'bandal.ipad.pdf-input.v2', LEGACY_KEY = 'bandal.ipad.pdf-input.v1', CHANGED = 'bandal-pdf-input-preferences'
export const PDF_COLORS: DrawingColor[] = ['ink', 'red', 'orange', 'yellow', 'green', 'blue', 'violet']
export const DEFAULT_PEN: PenPreset = { color: 'ink', width: 0.004, opacity: 0.95 }
const DEFAULT_FAVORITES: InputPreferences['favorites'] = [{ ...DEFAULT_PEN }, { ...DEFAULT_PEN, color: 'blue' }, { ...DEFAULT_PEN, color: 'red' }]
const unit = (value: unknown, fallback: number): number => typeof value === 'number' && Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : fallback
export function validPreset(value: unknown): value is PenPreset {
  if (!value || typeof value !== 'object') return false
  const item = value as PenPreset
  return PDF_COLORS.includes(item.color) && Number.isFinite(item.width) && item.width >= 0.001 && item.width <= 0.04 &&
    Number.isFinite(item.opacity) && item.opacity >= 0.05 && item.opacity <= 1
}
export function normalizePreferences(value: unknown): InputPreferences {
  const candidate = value as { version?: unknown } | null
  const data = candidate?.version === 1 || candidate?.version === 2 ? value as Partial<Omit<InputPreferences, 'version'>> & { version: number; presets?: unknown[] } : null
  const previous = data?.version === 1 && Array.isArray(data.presets) ? data.presets.filter(validPreset) : []
  const source = data?.version === 2 && Array.isArray(data.favorites) ? data.favorites : previous
  const favorites = DEFAULT_FAVORITES.map((fallback, index) => ({ ...(validPreset(source[index]) ? source[index] : fallback) })) as InputPreferences['favorites']
  const recentPen = data?.version === 2 && validPreset(data.recentPen) ? data.recentPen : previous[0] ?? DEFAULT_PEN
  return { version: 2, favorites, recentPen: { ...recentPen }, collapsed: data?.collapsed === true,
    position: { x: unit(data?.position?.x, 0.5), y: unit(data?.position?.y, 0) } }
}
export function samePreset(a: PenPreset, b: PenPreset): boolean {
  return a.color === b.color && a.width === b.width && a.opacity === b.opacity
}
export function readInputPreferences(): InputPreferences {
  try { return normalizePreferences(JSON.parse(window.localStorage.getItem(KEY) ?? window.localStorage.getItem(LEGACY_KEY) ?? 'null')) } catch { return normalizePreferences(null) }
}
export function writeInputPreferences(value: InputPreferences): void {
  // Preferences are optional. A full/disabled web storage cannot block ink.
  try { window.localStorage.setItem(KEY, JSON.stringify(normalizePreferences(value))); window.dispatchEvent(new Event(CHANGED)) } catch { /* Keep this panel's in-memory preferences. */ }
}
export function onInputPreferencesChanged(listener: () => void): () => void {
  const storage = (event: StorageEvent): void => { if (event.key === KEY) listener() }
  window.addEventListener(CHANGED, listener); window.addEventListener('storage', storage)
  return () => { window.removeEventListener(CHANGED, listener); window.removeEventListener('storage', storage) }
}
