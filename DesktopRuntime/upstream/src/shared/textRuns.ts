import type {
  DrawingInlineStyle,
  DrawingTextRun
} from './types/drawing'

const INLINE_KEYS = [
  'color',
  'fontSizePt',
  'bold',
  'italic',
  'underline',
  'strike'
] as const satisfies readonly (keyof DrawingInlineStyle)[]

export function sameInlineStyle(
  left: DrawingInlineStyle,
  right: DrawingInlineStyle
): boolean {
  return INLINE_KEYS.every((key) => left[key] === right[key])
}

export function normalizeTextRuns(
  text: string,
  runs: readonly DrawingTextRun[] | undefined
): DrawingTextRun[] {
  if (runs === undefined || text.length === 0) return []
  const valid = runs
    .filter((run) =>
      Number.isInteger(run.from) && Number.isInteger(run.to) &&
      run.from >= 0 && run.to > run.from && run.from < text.length
    )
    .map((run) => ({
      from: run.from,
      to: Math.min(text.length, run.to),
      style: { ...run.style }
    }))
    .sort((left, right) => left.from - right.from || left.to - right.to)

  const normalized: DrawingTextRun[] = []
  for (const run of valid) {
    const previous = normalized.at(-1)
    const from = previous === undefined ? run.from : Math.max(previous.to, run.from)
    if (run.to <= from || Object.keys(run.style).length === 0) continue
    if (previous !== undefined && previous.to === from && sameInlineStyle(previous.style, run.style)) {
      previous.to = run.to
    } else {
      normalized.push({ ...run, from })
    }
  }
  return normalized
}
