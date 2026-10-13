import type { PDFFont } from 'pdf-lib'
import {
  TEXT_EXPORT_FONT_PT,
  TEXT_LINE_HEIGHT,
  textBoxFontPx
} from '../../shared/textBoxMetrics'
import { normalizeTextRuns, sameInlineStyle } from '../../shared/textRuns'
import type {
  DrawingInlineStyle,
  DrawingStyle,
  DrawingTextRun
} from '../../shared/types/drawing'

export type TextboxFace = 'regular' | 'bold'

export interface LayoutFont<T> {
  metrics: PDFFont
  value: T
}

export interface TextboxLayoutFonts<T> {
  regular: LayoutFont<T> | null
  bold: LayoutFont<T> | null
}

export interface TextboxLayoutRun<T> {
  text: string
  font: T
  style: DrawingStyle
  fontSize: number
  width: number
}

export interface TextboxLayoutLine<T> {
  runs: TextboxLayoutRun<T>[]
  width: number
  lineHeight: number
  ascent: number
  contentHeight: number
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value))
}

export function faceOfTextStyle(style: Pick<DrawingStyle, 'bold'>): TextboxFace {
  return style.bold === true ? 'bold' : 'regular'
}

/** Every face that may place a glyph, including inline overrides. */
export function usedTextboxFaces(
  text: string | undefined,
  style: DrawingStyle,
  runs: readonly DrawingTextRun[] | undefined
): Set<TextboxFace> {
  const result = new Set<TextboxFace>()
  if (text === undefined || !/\S/u.test(text)) return result
  result.add(faceOfTextStyle(style))
  for (const run of normalizeTextRuns(text, runs)) {
    if (!/\S/u.test(text.slice(run.from, run.to))) continue
    result.add(run.style.bold ?? style.bold ? 'bold' : 'regular')
  }
  return result
}

function fontFor<T>(fonts: TextboxLayoutFonts<T>, style: DrawingStyle): LayoutFont<T> | null {
  return faceOfTextStyle(style) === 'bold'
    ? fonts.bold ?? fonts.regular
    : fonts.regular
}

function encodableText(font: PDFFont, text: string): string {
  try {
    font.encodeText(text)
    return text
  } catch {
    return '?'
  }
}

function sameRenderedStyle(left: DrawingStyle, right: DrawingStyle): boolean {
  const leftInline: DrawingInlineStyle = left
  const rightInline: DrawingInlineStyle = right
  return sameInlineStyle(leftInline, rightInline)
}

interface MutableLine<T> {
  runs: TextboxLayoutRun<T>[]
  width: number
}

/**
 * Character-level wrapping for a rich textbox. Ranges use UTF-16 offsets, the
 * same convention as ProseMirror and JavaScript strings, while iteration keeps
 * surrogate-pair glyphs intact.
 */
export function layoutTextboxLines<T>(options: {
  text: string
  textRuns?: readonly DrawingTextRun[] | undefined
  style: DrawingStyle
  fonts: TextboxLayoutFonts<T>
  surfaceWidthPt: number
  maxWidth: number
}): TextboxLayoutLine<T>[] {
  const { text, style, fonts, surfaceWidthPt, maxWidth } = options
  const normalizedRuns = normalizeTextRuns(text, options.textRuns)
  const baseFontSize = clamp(
    textBoxFontPx(surfaceWidthPt, style.fontScale, style.fontSizePt, surfaceWidthPt),
    TEXT_EXPORT_FONT_PT.min,
    TEXT_EXPORT_FONT_PT.max
  )
  const rawLines: MutableLine<T>[] = []
  let current: MutableLine<T> = { runs: [], width: 0 }
  let runIndex = 0

  const finishLine = (): void => {
    rawLines.push(current)
    current = { runs: [], width: 0 }
  }

  for (let offset = 0; offset < text.length;) {
    const codePoint = text.codePointAt(offset)
    if (codePoint === undefined) break
    const character = String.fromCodePoint(codePoint)
    const nextOffset = offset + character.length

    if (character === '\r' || character === '\n') {
      finishLine()
      offset = character === '\r' && text[nextOffset] === '\n'
        ? nextOffset + 1
        : nextOffset
      continue
    }

    while (normalizedRuns[runIndex] !== undefined && normalizedRuns[runIndex]!.to <= offset) {
      runIndex += 1
    }
    const inline = normalizedRuns[runIndex]
    const effectiveStyle: DrawingStyle = inline !== undefined && inline.from <= offset
      ? { ...style, ...inline.style }
      : style
    const selectedFont = fontFor(fonts, effectiveStyle)
    if (selectedFont !== null) {
      const fontSize = effectiveStyle.fontSizePt === undefined
        ? baseFontSize
        : clamp(effectiveStyle.fontSizePt, TEXT_EXPORT_FONT_PT.min, TEXT_EXPORT_FONT_PT.max)
      const display = character === '\t'
        ? '    '
        : encodableText(selectedFont.metrics, character)
      const glyphWidth = selectedFont.metrics.widthOfTextAtSize(display, fontSize)
      if (current.width > 0 && current.width + glyphWidth > maxWidth) finishLine()

      const previous = current.runs.at(-1)
      if (
        previous !== undefined &&
        previous.font === selectedFont.value &&
        previous.fontSize === fontSize &&
        sameRenderedStyle(previous.style, effectiveStyle)
      ) {
        previous.text += display
        previous.width += glyphWidth
      } else {
        current.runs.push({
          text: display,
          font: selectedFont.value,
          style: effectiveStyle,
          fontSize,
          width: glyphWidth
        })
      }
      current.width += glyphWidth
    }
    offset = nextOffset
  }
  finishLine()

  return rawLines.map((line) => {
    if (line.runs.length === 0) {
      const fallback = fontFor(fonts, style)
      return {
        ...line,
        lineHeight: baseFontSize * TEXT_LINE_HEIGHT,
        ascent: fallback?.metrics.heightAtSize(baseFontSize, { descender: false }) ?? baseFontSize,
        contentHeight: fallback?.metrics.heightAtSize(baseFontSize) ?? baseFontSize
      }
    }
    return {
      ...line,
      lineHeight: Math.max(...line.runs.map((run) => run.fontSize * TEXT_LINE_HEIGHT)),
      ascent: Math.max(...line.runs.map((run) => {
        const selected = run.font as T
        const font = selected === fonts.bold?.value ? fonts.bold : fonts.regular
        return font?.metrics.heightAtSize(run.fontSize, { descender: false }) ?? run.fontSize
      })),
      contentHeight: Math.max(...line.runs.map((run) => {
        const selected = run.font as T
        const font = selected === fonts.bold?.value ? fonts.bold : fonts.regular
        return font?.metrics.heightAtSize(run.fontSize) ?? run.fontSize
      }))
    }
  })
}
