/**
 * Text box metrics shared by the renderer (ink layer) and main (PDF export).
 *
 * Every number here used to live twice — `0.026` in `textBoxLayout.ts` AND in
 * both exporters, line height `1.35` on screen vs `1.25` in the PDF — so the
 * exported page never matched what the student saw. One module, imported by
 * both sides, is the only way to keep them equal.
 *
 * Units: everything is relative to the SURFACE WIDTH (page width in px on
 * screen, page width in pt on export) or to the font size (`*_EM`). Padding
 * and border are em-based on purpose: a px-fixed padding made the measured
 * text height differ at every zoom level, and the grow-only height rule then
 * drifted the stored box height monotonically.
 */

/** fontSize = surfaceWidth · ratio · fontScale. */
export const TEXT_BASE_FONT_RATIO = 0.026
/** Line height as a multiple of the font size — screen and export alike. */
export const TEXT_LINE_HEIGHT = 1.35
/** Inner padding of the box, in em. */
export const TEXT_BOX_PADDING_EM = 0.3
/** Border width of the box, in em (dotted on hover on screen). */
export const TEXT_BOX_BORDER_EM = 0.06
/** Alpha of the `style.fill` tint behind the text. */
export const TEXT_FILL_OPACITY = 0.18
/** Synthetic italic: no italic Korean font is bundled, so the glyphs are skewed. */
export const TEXT_ITALIC_SKEW_DEG = 12
/** Underline / strikethrough stroke, in em. */
export const TEXT_UNDERLINE_THICKNESS_EM = 0.06
/** Export clamps the font size to what pdf-lib renders legibly. */
export const TEXT_EXPORT_FONT_PT = { min: 6, max: 96 } as const

/** New text boxes use real typographic points. */
export const TEXT_DEFAULT_FONT_PT = 14
export const TEXT_FONT_PT_LIMITS = { min: 6, max: 96 } as const
export const TEXT_FONT_PT_STEPS: readonly number[] = [
  6, 7, 8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72, 96
]

/** Stepper ladder — a legacy arbitrary fontScale snaps to the nearest step first. */
export const TEXT_FONT_SCALE_STEPS: readonly number[] =
  [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4]

function finitePositive(value: number | undefined): value is number {
  return value !== undefined && Number.isFinite(value) && value > 0
}

export function nearestFontScaleIndex(scale: number | undefined): number {
  const value = finitePositive(scale) ? scale : 1
  let best = 0
  for (let index = 1; index < TEXT_FONT_SCALE_STEPS.length; index += 1) {
    if (
      Math.abs(TEXT_FONT_SCALE_STEPS[index]! - value) <
      Math.abs(TEXT_FONT_SCALE_STEPS[best]! - value)
    ) {
      best = index
    }
  }
  return best
}

export function steppedFontScale(
  scale: number | undefined,
  direction: 1 | -1
): number {
  const index = nearestFontScaleIndex(scale)
  const next = Math.min(
    TEXT_FONT_SCALE_STEPS.length - 1,
    Math.max(0, index + direction)
  )
  return TEXT_FONT_SCALE_STEPS[next]!
}

/** Font size in surface units (px on screen, pt on export) for a text box. */
export function textBoxFontPx(
  surfaceWidthPx: number,
  fontScale: number | undefined,
  fontSizePt?: number,
  surfaceWidthPt = 595.28
): number {
  if (
    fontSizePt !== undefined &&
    Number.isFinite(fontSizePt) &&
    fontSizePt > 0 &&
    Number.isFinite(surfaceWidthPt) &&
    surfaceWidthPt > 0
  ) {
    return surfaceWidthPx * fontSizePt / surfaceWidthPt
  }
  const scale = finitePositive(fontScale) ? fontScale : 1
  return surfaceWidthPx * TEXT_BASE_FONT_RATIO * scale
}

export function clampFontPt(value: number): number {
  return Math.min(TEXT_FONT_PT_LIMITS.max, Math.max(TEXT_FONT_PT_LIMITS.min, value))
}

export function nearestFontPtIndex(value: number | undefined): number {
  const point = finitePositive(value) ? value : TEXT_DEFAULT_FONT_PT
  let best = 0
  for (let index = 1; index < TEXT_FONT_PT_STEPS.length; index += 1) {
    if (
      Math.abs(TEXT_FONT_PT_STEPS[index]! - point) <
      Math.abs(TEXT_FONT_PT_STEPS[best]! - point)
    ) best = index
  }
  return best
}

export function steppedFontPt(value: number | undefined, direction: 1 | -1): number {
  const index = nearestFontPtIndex(value)
  const next = Math.min(TEXT_FONT_PT_STEPS.length - 1, Math.max(0, index + direction))
  return TEXT_FONT_PT_STEPS[next]!
}
