import type { Font as FontkitFont, Path as FontkitPath } from '@pdf-lib/fontkit'
import { degrees, type Color, type PDFFont, type PDFPage } from 'pdf-lib'
import { TEXT_ITALIC_SKEW_DEG } from '../../shared/textBoxMetrics'

export interface TextboxFont {
  embedded: PDFFont
  outlines: FontkitFont
}

interface TransformablePath extends FontkitPath {
  scale(x: number, y: number): TransformablePath
  transform(a: number, b: number, c: number, d: number, e: number, f: number): TransformablePath
}

/**
 * CoreGraphics interprets subset CFF glyph IDs differently from PDF.js: Korean
 * text can extract correctly yet paint as punctuation. Paint vector outlines
 * from the original font and retain an invisible text layer for search/copy.
 * Shared by annotated PDFs (including slides) and whiteboards.
 */
export function drawPdfText(page: PDFPage, text: string, font: TextboxFont, pen: {
  x: number
  y: number
  fontSize: number
  color: Color
  opacity: number
  italic: boolean
}): void {
  page.drawText(text, {
    x: pen.x,
    y: pen.y,
    size: pen.fontSize,
    font: font.embedded,
    color: pen.color,
    opacity: 0,
    ...(pen.italic ? { ySkew: degrees(TEXT_ITALIC_SKEW_DEG) } : {})
  })
  const run = font.outlines.layout(text)
  const scale = pen.fontSize / font.outlines.unitsPerEm
  const shear = pen.italic ? Math.tan(TEXT_ITALIC_SKEW_DEG * Math.PI / 180) : 0
  let x = pen.x
  let y = pen.y
  for (let index = 0; index < run.glyphs.length; index++) {
    const glyph = run.glyphs[index]
    const position = run.positions[index]
    if (!glyph || !position) continue
    const path = glyph.path as TransformablePath
    const svgPath = path.transform(1, 0, shear, 1, 0, 0).scale(1, -1).toSVG()
    if (svgPath.length > 0) {
      page.drawSvgPath(svgPath, {
        x: x + position.xOffset * scale,
        y: y + position.yOffset * scale,
        scale,
        color: pen.color,
        opacity: pen.opacity
      })
    }
    x += position.xAdvance * scale
    y += position.yAdvance * scale
  }
}
