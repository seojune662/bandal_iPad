/** Burn stored annotations and drawings into a new PDF without touching the source. */

import { randomUUID } from 'node:crypto'
import { existsSync } from 'node:fs'
import { readFile, realpath, rename, unlink, writeFile } from 'node:fs/promises'
import { basename, dirname, isAbsolute, join, resolve } from 'node:path'
import fontkit from '@pdf-lib/fontkit'
import {
  BlendMode,
  LineCapStyle,
  PDFDocument,
  rgb,
  type Color,
  type PDFPage
} from 'pdf-lib'
import {
  TEXT_BOX_PADDING_EM,
  TEXT_EXPORT_FONT_PT,
  TEXT_FILL_OPACITY,
  TEXT_UNDERLINE_THICKNESS_EM,
  textBoxFontPx
} from '../../../shared/textBoxMetrics'
import type { Annotation, HighlightColor } from '../../../shared/types/annotation'
import type {
  Drawing,
  DrawingBox,
  DrawingColor,
  DrawingPoint,
  DrawingStyle,
  ExportAnnotatedPdfInput,
  TextAlign
} from '../../../shared/types/drawing'
import { drawPdfText, type TextboxFont } from '../pdfText'
import { ValidationError } from '../../db/errors'
import { requireId, requireNonEmptyString, resolveInsideReal } from '../../db/validate'
import {
  layoutTextboxLines,
  usedTextboxFaces,
  type TextboxFace
} from '../textboxPdfLayout'

/** Bundled Noto Sans KR faces (see electron-builder.yml `extraResources`). */
export type TextboxFontFile = 'NotoSansKR-Regular.otf' | 'NotoSansKR-Bold.otf'

/** Underline sits below the baseline, strikethrough above it, both in em. */
const TEXT_UNDERLINE_OFFSET_EM = -0.1
const TEXT_STRIKE_OFFSET_EM = 0.3
const TEXT_ALIGN_FACTORS: Record<TextAlign, number> = { left: 0, center: 0.5, right: 1 }

/**
 * Faces embedded for this document. A face is embedded ONLY when some box will
 * place a glyph with it: fontkit's CFF subsetter throws (asynchronously, past
 * every try/catch) on a subset that holds nothing but `.notdef`.
 */
interface TextboxFonts {
  regular: TextboxFont | null
  bold: TextboxFont | null
}

interface TextLineRun {
  x: number
  y: number
  width: number
  fontSize: number
  color: Color
  opacity: number
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value))
}

/** Whether drawing this text places at least one glyph (whitespace alone does not). */
function hasGlyphs(text: string | undefined): boolean {
  return text !== undefined && /\S/u.test(text)
}

const DRAWING_COLORS: Record<DrawingColor, Color> = {
  ink: rgb(0.08, 0.09, 0.12),
  red: rgb(0.84, 0.14, 0.18),
  orange: rgb(0.94, 0.39, 0.08),
  yellow: rgb(0.96, 0.72, 0.04),
  green: rgb(0.1, 0.58, 0.3),
  blue: rgb(0.08, 0.38, 0.88),
  violet: rgb(0.49, 0.21, 0.82)
}

const HIGHLIGHT_COLORS: Record<HighlightColor, Color> = {
  yellow: rgb(0.98, 0.83, 0.18),
  green: rgb(0.3, 0.78, 0.4),
  pink: rgb(0.94, 0.38, 0.6),
  blue: rgb(0.3, 0.62, 0.94)
}

function pdfPoint(point: DrawingPoint, width: number, height: number): { x: number; y: number } {
  return { x: point.x * width, y: (1 - point.y) * height }
}

function linePoints(drawing: Drawing): [DrawingPoint, DrawingPoint] | null {
  const points = drawing.data.points
  if (points !== undefined && points.length >= 2) {
    const first = points[0]
    const last = points[points.length - 1]
    if (first !== undefined && last !== undefined) return [first, last]
  }
  const box = drawing.data.box
  if (box === undefined) return null
  return [
    { x: box.x, y: box.y, p: 0.5 },
    { x: box.x + box.width, y: box.y + box.height, p: 0.5 }
  ]
}

function drawInk(page: PDFPage, drawing: Drawing, width: number, height: number): void {
  const points = drawing.data.points ?? []
  if (points.length === 0) return
  const color = DRAWING_COLORS[drawing.style.color]
  const baseThickness = drawing.style.width * width
  const opacity = drawing.kind === 'highlighter'
    ? Math.min(drawing.style.opacity, 0.38)
    : drawing.style.opacity
  const blendMode = drawing.kind === 'highlighter' ? BlendMode.Multiply : BlendMode.Normal
  const first = points[0]
  if (points.length === 1 && first !== undefined) {
    const point = pdfPoint(first, width, height)
    page.drawCircle({
      ...point,
      size: Math.max(baseThickness * Math.max(first.p, 0.25) / 2, 0.25),
      color,
      opacity,
      blendMode
    })
    return
  }
  for (let index = 1; index < points.length; index += 1) {
    const previous = points[index - 1]
    const current = points[index]
    if (previous === undefined || current === undefined) continue
    const pressure = drawing.kind === 'highlighter'
      ? 1
      : Math.max(0.2, (previous.p + current.p) / 2)
    page.drawLine({
      start: pdfPoint(previous, width, height),
      end: pdfPoint(current, width, height),
      thickness: Math.max(baseThickness * pressure, 0.25),
      color,
      opacity,
      blendMode,
      lineCap: LineCapStyle.Round
    })
  }
}

function drawBoxShape(page: PDFPage, drawing: Drawing, box: DrawingBox, width: number, height: number): void {
  const color = DRAWING_COLORS[drawing.style.color]
  const borderWidth = Math.max(drawing.style.width * width, 0.25)
  const x = box.x * width
  const boxWidth = box.width * width
  const boxHeight = box.height * height
  const y = height - (box.y + box.height) * height
  if (drawing.kind === 'rect') {
    page.drawRectangle({
      x,
      y,
      width: boxWidth,
      height: boxHeight,
      borderColor: color,
      borderWidth,
      borderOpacity: drawing.style.opacity
    })
  } else {
    page.drawEllipse({
      x: x + boxWidth / 2,
      y: y + boxHeight / 2,
      xScale: boxWidth / 2,
      yScale: boxHeight / 2,
      borderColor: color,
      borderWidth,
      borderOpacity: drawing.style.opacity
    })
  }
}

function drawStraightLine(page: PDFPage, drawing: Drawing, width: number, height: number): void {
  const points = linePoints(drawing)
  if (points === null) return
  const start = pdfPoint(points[0], width, height)
  const end = pdfPoint(points[1], width, height)
  const thickness = Math.max(drawing.style.width * width, 0.25)
  const options = {
    thickness,
    color: DRAWING_COLORS[drawing.style.color],
    opacity: drawing.style.opacity,
    lineCap: LineCapStyle.Round
  }
  page.drawLine({ start, end, ...options })
  if (drawing.kind !== 'arrow') return

  const angle = Math.atan2(end.y - start.y, end.x - start.x)
  const headLength = Math.max(thickness * 4, width * 0.012)
  for (const offset of [-Math.PI / 6, Math.PI / 6]) {
    page.drawLine({
      start: end,
      end: {
        x: end.x - Math.cos(angle + offset) * headLength,
        y: end.y - Math.sin(angle + offset) * headLength
      },
      ...options
    })
  }
}

/** Underline / strikethrough rules spanning exactly the drawn line. */
function drawTextDecorations(page: PDFPage, style: DrawingStyle, run: TextLineRun): void {
  if (run.width <= 0) return
  const offsets: number[] = []
  if (style.underline === true) offsets.push(run.fontSize * TEXT_UNDERLINE_OFFSET_EM)
  if (style.strike === true) offsets.push(run.fontSize * TEXT_STRIKE_OFFSET_EM)
  for (const offset of offsets) {
    page.drawLine({
      start: { x: run.x, y: run.y + offset },
      end: { x: run.x + run.width, y: run.y + offset },
      thickness: run.fontSize * TEXT_UNDERLINE_THICKNESS_EM,
      color: run.color,
      opacity: run.opacity
    })
  }
}

function drawTextbox(
  page: PDFPage,
  drawing: Drawing,
  box: DrawingBox,
  fonts: TextboxFonts,
  width: number,
  height: number
): void {
  const style = drawing.style
  // Same metrics module as the on-screen layer, so the export wraps and
  // spaces lines exactly where the student saw them.
  const fontSize = clamp(
    textBoxFontPx(width, style.fontScale, style.fontSizePt, width),
    TEXT_EXPORT_FONT_PT.min,
    TEXT_EXPORT_FONT_PT.max
  )
  const inset = fontSize * TEXT_BOX_PADDING_EM
  const left = box.x * width
  const boxWidth = box.width * width
  const boxHeight = box.height * height
  const bottom = height - (box.y + box.height) * height
  const top = bottom + boxHeight
  const maxWidth = Math.max(boxWidth - 2 * inset, fontSize)
  const opacity = style.opacity

  if (style.fill !== undefined) {
    page.drawRectangle({
      x: left,
      y: bottom,
      width: boxWidth,
      height: boxHeight,
      color: DRAWING_COLORS[style.fill],
      opacity: TEXT_FILL_OPACITY
    })
  }

  if (!hasGlyphs(drawing.data.text)) return
  const lines = layoutTextboxLines({
    text: drawing.data.text ?? '',
    textRuns: drawing.data.textRuns,
    style,
    fonts: {
      regular: fonts.regular === null ? null : { metrics: fonts.regular.embedded, value: fonts.regular },
      bold: fonts.bold === null ? null : { metrics: fonts.bold.embedded, value: fonts.bold }
    },
    surfaceWidthPt: width,
    maxWidth
  })
  const alignFactor = TEXT_ALIGN_FACTORS[style.align ?? 'left']
  let lineTop = top - inset
  for (const line of lines) {
    // CSS centers each face's content inside the tallest inline line box.
    const halfLeading = (line.lineHeight - line.contentHeight) / 2
    const y = lineTop - halfLeading - line.ascent
    if (y < bottom) break
    let x = left + inset + Math.max(0, maxWidth - line.width) * alignFactor
    for (const run of line.runs) {
      const runColor = DRAWING_COLORS[run.style.color]
      drawPdfText(page, run.text, run.font, {
        x, y, fontSize: run.fontSize, color: runColor, opacity,
        italic: run.style.italic === true
      })
      drawTextDecorations(page, run.style, {
        x,
        y,
        width: run.width,
        fontSize: run.fontSize,
        color: runColor,
        opacity
      })
      x += run.width
    }
    lineTop -= line.lineHeight
  }
}

function drawAnnotation(page: PDFPage, annotation: Annotation, width: number, height: number): void {
  for (const rect of annotation.rects) {
    page.drawRectangle({
      x: rect.x * width,
      y: height - (rect.y + rect.height) * height,
      width: rect.width * width,
      height: rect.height * height,
      color: HIGHLIGHT_COLORS[annotation.color],
      opacity: 0.42,
      blendMode: BlendMode.Multiply
    })
  }
}

async function canonicalPath(path: string): Promise<string> {
  try {
    return await realpath(path)
  } catch {
    return join(await realpath(dirname(path)), basename(path))
  }
}

export function resolveDefaultFontPath(file: TextboxFontFile): string {
  // Keep Electron out of the module graph until the default is actually used.
  // Vitest imports this module in plain Node and supplies resolveFontPath.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { app } = require('electron') as typeof import('electron')
  if (app.isPackaged) return join(process.resourcesPath, 'fonts', file)
  const devPath = join(app.getAppPath(), 'resources', 'fonts', file)
  // Launching the built main entry directly sets appPath to out/main.
  return existsSync(devPath) ? devPath : resolve(__dirname, '../../resources/fonts', file)
}

export interface PdfExporterDeps {
  getCourseFolder: (courseId: string) => string
  listDrawings: (courseId: string, relPath: string) => Drawing[]
  listAnnotations: (courseId: string, relPath: string) => Annotation[]
  /** Absolute path of a bundled face. Called at most once per face per exporter. */
  resolveFontPath?: (file: TextboxFontFile) => string
}

export function createPdfExporter(deps: PdfExporterDeps): {
  exportAnnotated(input: ExportAnnotatedPdfInput, savePath: string): Promise<void>
  annotateDocument(pdf: PDFDocument, input: ExportAnnotatedPdfInput): Promise<void>
} {
  const fontBytes = new Map<TextboxFontFile, Promise<Uint8Array>>()

  /** Each face is resolved and read once per exporter; Bold only on demand. */
  function loadFontBytes(file: TextboxFontFile): Promise<Uint8Array> {
    const cached = fontBytes.get(file)
    if (cached !== undefined) return cached
    const promise = Promise.resolve().then(() =>
      readFile((deps.resolveFontPath ?? resolveDefaultFontPath)(file))
    ).catch((error: unknown) => {
      fontBytes.delete(file)
      throw error
    })
    fontBytes.set(file, promise)
    return promise
  }

  async function tryEmbedFace(
    pdf: PDFDocument,
    file: TextboxFontFile,
    consequence: string
  ): Promise<TextboxFont | null> {
    try {
      const bytes = await loadFontBytes(file)
      return {
        embedded: await pdf.embedFont(bytes, { subset: true }),
        outlines: fontkit.create(bytes)
      }
    } catch (error) {
      console.warn(`[pdf] ${file} could not be loaded; ${consequence}`, error)
      return null
    }
  }

  async function embedTextboxFonts(pdf: PDFDocument, textboxes: Drawing[]): Promise<TextboxFonts> {
    pdf.registerFontkit(fontkit)
    const wanted = new Set<TextboxFace>()
    for (const drawing of textboxes) {
      for (const face of usedTextboxFaces(
        drawing.data.text,
        drawing.style,
        drawing.data.textRuns
      )) wanted.add(face)
    }
    const bold = wanted.has('bold')
      ? await tryEmbedFace(pdf, 'NotoSansKR-Bold.otf', 'bold text will export in Regular weight.')
      : null
    // Bold boxes whose face failed draw with Regular, so Regular is needed then too.
    const needsRegular = wanted.has('regular') || (wanted.has('bold') && bold === null)
    const regular = needsRegular
      ? await tryEmbedFace(pdf, 'NotoSansKR-Regular.otf', 'export cancelled to preserve the text.')
      : null
    if (!needsRegular || regular !== null) return { regular, bold }
    throw new Error('PDF 내보내기에 필요한 한글 글꼴을 읽지 못했어요. 앱을 다시 설치한 뒤 시도해 주세요.')
  }

  async function annotateDocument(pdf: PDFDocument, input: ExportAnnotatedPdfInput): Promise<void> {
    const { courseId, relPath } = input
    const pages = pdf.getPages()
    const annotations = deps.listAnnotations(courseId, relPath)
    const drawings = deps.listDrawings(courseId, relPath)
    const textboxes = drawings.filter((drawing) => drawing.kind === 'textbox')
    const fonts = textboxes.length > 0 ? await embedTextboxFonts(pdf, textboxes) : null

    for (const annotation of annotations) {
      const page = pages[annotation.page - 1]
      if (page === undefined) continue
      const { width, height } = page.getSize()
      drawAnnotation(page, annotation, width, height)
    }
    for (const drawing of drawings) {
      const page = pages[drawing.page - 1]
      if (page === undefined) continue
      const { width, height } = page.getSize()
      if (drawing.kind === 'ink' || drawing.kind === 'highlighter') {
        drawInk(page, drawing, width, height)
      } else if (drawing.kind === 'rect' || drawing.kind === 'ellipse') {
        if (drawing.data.box !== undefined) {
          drawBoxShape(page, drawing, drawing.data.box, width, height)
        }
      } else if (drawing.kind === 'line' || drawing.kind === 'arrow') {
        drawStraightLine(page, drawing, width, height)
      } else if (drawing.kind === 'image' && drawing.data.image && drawing.data.box) {
        const canonicalImage = resolveInsideReal(deps.getCourseFolder(courseId), drawing.data.image.relPath)
        const { nativeImage } = await import('electron')
        const png = nativeImage.createFromBuffer(await readFile(canonicalImage)).toPNG()
        const image = await pdf.embedPng(png)
        const box = drawing.data.box
        page.drawImage(image, { x: box.x * width, y: (1 - box.y - box.height) * height, width: box.width * width, height: box.height * height, opacity: drawing.style.opacity })
      } else if (drawing.kind === 'textbox' && fonts !== null && drawing.data.box !== undefined) {
        drawTextbox(page, drawing, drawing.data.box, fonts, width, height)
      }
    }

  }

  return {
    annotateDocument,
    async exportAnnotated(input, savePathInput) {
      const courseId = requireId(input.courseId, 'courseId')
      const relPath = requireNonEmptyString(input.relPath, 'relPath')
      const savePath = requireNonEmptyString(savePathInput, 'savePath')
      if (!isAbsolute(savePath)) throw new ValidationError('savePath must be absolute')

      const sourcePath = resolveInsideReal(deps.getCourseFolder(courseId), relPath)
      const [canonicalSource, canonicalSave] = await Promise.all([
        canonicalPath(sourcePath),
        canonicalPath(resolve(savePath))
      ])
      if (canonicalSource === canonicalSave) {
        throw new ValidationError('annotated PDF must be saved to a new file')
      }

      const pdf = await PDFDocument.load(await readFile(sourcePath))
      await annotateDocument(pdf, input)
      // Write beside the destination then atomically replace it. Besides avoiding
      // partial PDFs, this cannot follow a destination symlink/hardlink back to
      // the source file.
      const temporaryPath = join(
        dirname(savePath),
        `.${basename(savePath)}.${randomUUID()}.tmp`
      )
      try {
        await writeFile(temporaryPath, await pdf.save())
        await rename(temporaryPath, savePath)
      } catch (error) {
        await unlink(temporaryPath).catch(() => undefined)
        throw error
      }
    }
  }
}
