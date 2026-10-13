import { Plugin } from '@milkdown/prose/state'

export const NOTE_FONT_SCALE_STORAGE_KEY = 'bandal.noteFontScale'
export const NOTE_FONT_SCALES = [0.875, 1, 1.125, 1.25, 1.5] as const
export type NoteFontScale = (typeof NOTE_FONT_SCALES)[number]

export function parseNoteFontScale(value: string | null): NoteFontScale {
  const parsed = value === null ? Number.NaN : Number(value)
  return NOTE_FONT_SCALES.find((scale) => scale === parsed) ?? 1
}

export function stepNoteFontScale(
  current: NoteFontScale,
  direction: -1 | 1
): NoteFontScale {
  const currentIndex = NOTE_FONT_SCALES.indexOf(current)
  const nextIndex = Math.max(
    0,
    Math.min(NOTE_FONT_SCALES.length - 1, currentIndex + direction)
  )
  return NOTE_FONT_SCALES[nextIndex] ?? 1
}

export function createNoteZoomShortcutPlugin(
  onStep: (direction: -1 | 1) => void
): Plugin {
  return new Plugin({
    props: {
      handleKeyDown: (_view, event) => {
        if (!(event.metaKey || event.ctrlKey) || event.altKey) return false

        const direction =
          event.key === '+' || event.key === '='
            ? 1
            : event.key === '-' || event.key === '_'
              ? -1
              : null
        if (direction === null) return false

        event.preventDefault()
        onStep(direction)
        return true
      }
    }
  })
}
