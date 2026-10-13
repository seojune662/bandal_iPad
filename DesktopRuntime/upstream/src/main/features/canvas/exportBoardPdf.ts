import { createBoardMediaRenderer } from './boardMediaPdf'
import { readFile, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import fontkit from '@pdf-lib/fontkit'
import {
  BlendMode,
  LineCapStyle,
  PageSizes,
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
import type {
  DrawingBox,
  DrawingColor,
  DrawingPoint,
  DrawingShape,
  DrawingStyle,
  TextAlign
} from '../../../shared/types/drawing'
import type {
  BoardBackground,
  BoardSurface,
  OpenPersonalBoardResult
} from '../../../shared/types/whiteboard'
import { drawPdfText, type TextboxFont } from '../pdfText'
import { NotFoundError, ValidationError } from '../../db/errors'
import { requireId } from '../../db/validate'
import {
  layoutTextboxLines,
  usedTextboxFaces,
  type TextboxFace
} from '../textboxPdfLayout'

/** Bundled Noto Sans KR faces (see electron-builder.yml `extraResources`). */
export type TextboxFontFile = 'NotoSansKR-Regular.otf' | 'NotoSansKR-Bold.otf'

const RULE_SPACING = 28
/** Underline sits below the baseline, strikethrough above it, both in em. */
const TEXT_UNDERLINE_OFFSET_EM = -0.1
const TEXT_STRIKE_OFFSET_EM = 0.3
const TEXT_ALIGN_FACTORS: Record<TextAlign, number> = { left: 0, center: 0.5, right: 1 }

const LIGHT_COLORS: Record<DrawingColor, Color> = {
  ink: rgb(0.08, 0.09, 0.12),
  red: rgb(0.84, 0.14, 0.18),
  orange: rgb(0.94, 0.39, 0.08),
  yellow: rgb(0.78, 0.54, 0.02),
  green: rgb(0.1, 0.58, 0.3),
  blue: rgb(0.08, 0.38, 0.88),
  violet: rgb(0.49, 0.21, 0.82)
}

/** High-contrast counterparts for marks drawn on the dark paper. */
const DARK_COLORS: Record<DrawingColor, Color> = {
  ink: rgb(0.94, 0.96, 0.99),
  red: rgb(1, 0.48, 0.5),
  orange: rgb(1, 0.68, 0.32),
  yellow: rgb(1, 0.88, 0.34),
  green: rgb(0.46, 0.88, 0.6),
  blue: rgb(0.46, 0.72, 1),
  violet: rgb(0.78, 0.62, 1)
}

interface BoardPalette {
  paper: Color
  ruling: Color
  marks: Record<DrawingColor, Color>
}

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

const BOARD_PALETTES: Record<BoardSurface, BoardPalette> = {
  light: {
    paper: rgb(1, 1, 1),
    ruling: rgb(0.82, 0.84, 0.88),
    marks: LIGHT_COLORS
  },
  dark: {
    paper: rgb(0.045, 0.065, 0.115),
    ruling: rgb(0.2, 0.25, 0.36),
    marks: DARK_COLORS
  }
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value))
}

/** Whether drawing this text places at least one glyph (whitespace alone does not). */
function hasGlyphs(text: string | undefined): boolean {
  return text !== undefined && /\S/u.test(text)
}

function pdfPoint(
  point: DrawingPoint,
  width: number,
  height: number
): { x: number; y: number } {
  return { x: point.x * width, y: (1 - point.y) * height }
}

function drawBackground(
  page: PDFPage,
  background: BoardBackground,
  palette: BoardPalette,
  width: number,
  height: number
): void {
  page.drawRectangle({ x: 0, y: 0, width, height, color: palette.paper })
  if (background === 'blank') return

  if (background === 'dots') {
    for (let x = RULE_SPACING; x < width; x += RULE_SPACING) {
      for (let y = RULE_SPACING; y < height; y += RULE_SPACING) {
        page.drawCircle({ x, y, size: 0.85, color: palette.ruling, opacity: 0.72 })
      }
    }
    return
  }

  for (let y = RULE_SPACING; y < height; y += RULE_SPACING) {
    page.drawLine({
      start: { x: 0, y },
      end: { x: width, y },
      thickness: 0.55,
      color: palette.ruling,
      opacity: 0.68
    })
  }
  if (background === 'lines') return
  for (let x = RULE_SPACING; x < width; x += RULE_SPACING) {
    page.drawLine({
      start: { x, y: 0 },
      end: { x, y: height },
      thickness: 0.55,
      color: palette.ruling,
      opacity: 0.68
    })
  }
}

function drawInk(
  page: PDFPage,
  shape: DrawingShape,
  palette: BoardPalette,
  surface: BoardSurface,
  width: number,
  height: number
): void {
  const points = shape.data.points ?? []
  const first = points[0]
  if (first === undefined) return
  const baseThickness = Math.max(shape.style.width * width, 0.25)
  const opacity = shape.kind === 'highlighter'
    ? Math.min(clamp(shape.style.opacity, 0, 1), 0.42)
    : clamp(shape.style.opacity, 0, 1)
  const color = palette.marks[shape.style.color]
  const blendMode = shape.kind === 'highlighter'
    ? surface === 'dark' ? BlendMode.Screen : BlendMode.Multiply
    : BlendMode.Normal
  if (points.length === 1) {
    page.drawCircle({
      ...pdfPoint(first, width, height),
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
    const pressure = shape.kind === 'highlighter'
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

function boxOnPage(
  box: DrawingBox,
  width: number,
  height: number
): { x: number; y: number; width: number; height: number } | null {
  const boxWidth = box.width * width
  const boxHeight = box.height * height
  if (boxWidth <= 0 || boxHeight <= 0) return null
  return {
    x: box.x * width,
    y: height - (box.y + box.height) * height,
    width: boxWidth,
    height: boxHeight
  }
}

function drawBoxShape(
  page: PDFPage,
  shape: DrawingShape,
  box: DrawingBox,
  palette: BoardPalette,
  width: number,
  height: number
): void {
  const bounds = boxOnPage(box, width, height)
  if (bounds === null) return
  const border = {
    borderColor: palette.marks[shape.style.color],
    borderWidth: Math.max(shape.style.width * width, 0.25),
    borderOpacity: clamp(shape.style.opacity, 0, 1)
  }
  if (shape.kind === 'rect') {
    page.drawRectangle({ ...bounds, ...border })
  } else {
    page.drawEllipse({
      x: bounds.x + bounds.width / 2,
      y: bounds.y + bounds.height / 2,
      xScale: bounds.width / 2,
      yScale: bounds.height / 2,
      ...border
    })
  }
}

function linePoints(shape: DrawingShape): [DrawingPoint, DrawingPoint] | null {
  const points = shape.data.points
  if (points !== undefined && points.length >= 2) {
    const first = points[0]
    const last = points[points.length - 1]
    if (first !== undefined && last !== undefined) return [first, last]
  }
  const box = shape.data.box
  if (box === undefined) return null
  return [
    { x: box.x, y: box.y, p: 0.5 },
    { x: box.x + box.width, y: box.y + box.height, p: 0.5 }
  ]
}

function drawStraightLine(
  page: PDFPage,
  shape: DrawingShape,
  palette: BoardPalette,
  width: number,
  height: number
): void {
  const points = linePoints(shape)
  if (points === null) return
  const start = pdfPoint(points[0], width, height)
  const end = pdfPoint(points[1], width, height)
  const thickness = Math.max(shape.style.width * width, 0.25)
  const options = {
    thickness,
    color: palette.marks[shape.style.color],
    opacity: clamp(shape.style.opacity, 0, 1),
    lineCap: LineCapStyle.Round
  }
  page.drawLine({ start, end, ...options })
  if (shape.kind !== 'arrow') return

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
  shape: DrawingShape,
  box: DrawingBox,
  fonts: TextboxFonts,
  palette: BoardPalette,
  width: number,
  height: number
): void {
  const bounds = boxOnPage(box, width, height)
  if (bounds === null) return
  const style = shape.style
  // Same metrics module as the on-screen layer, so the export wraps and
  // spaces lines exactly where the student saw them.
  const fontSize = clamp(
    textBoxFontPx(width, style.fontScale, style.fontSizePt, width),
    TEXT_EXPORT_FONT_PT.min,
    TEXT_EXPORT_FONT_PT.max
  )
  const inset = fontSize * TEXT_BOX_PADDING_EM
  const maxWidth = Math.max(bounds.width - 2 * inset, fontSize)
  const opacity = clamp(style.opacity, 0, 1)

  if (style.fill !== undefined) {
    page.drawRectangle({
      ...bounds,
      color: palette.marks[style.fill],
      opacity: TEXT_FILL_OPACITY
    })
  }

  if (!hasGlyphs(shape.data.text)) return
  const lines = layoutTextboxLines({
    text: shape.data.text ?? '',
    textRuns: shape.data.textRuns,
    style,
    fonts: {
      regular: fonts.regular === null
        ? null
        : { metrics: fonts.regular.embedded, value: fonts.regular },
      bold: fonts.bold === null
        ? null
        : { metrics: fonts.bold.embedded, value: fonts.bold }
    },
    surfaceWidthPt: width,
    maxWidth
  })
  const top = bounds.y + bounds.height
  const alignFactor = TEXT_ALIGN_FACTORS[style.align ?? 'left']
  let lineTop = top - inset
  for (const line of lines) {
    const halfLeading = (line.lineHeight - line.contentHeight) / 2
    const y = lineTop - halfLeading - line.ascent
    if (y < bounds.y) break
    let x = bounds.x + inset + Math.max(0, maxWidth - line.width) * alignFactor
    for (const run of line.runs) {
      const color = palette.marks[run.style.color]
      drawPdfText(page, run.text, run.font, {
        x, y, fontSize: run.fontSize, color, opacity,
        italic: run.style.italic === true
      })
      drawTextDecorations(page, run.style, {
        x,
        y,
        width: run.width,
        fontSize: run.fontSize,
        color,
        opacity
      })
      x += run.width
    }
    lineTop -= line.lineHeight
  }
}

function resolveDefaultFontPath(file: TextboxFontFile): string {
  // Keep Electron out of plain-Node tests until this default is actually used.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { app } = require('electron') as typeof import('electron')
  return app.isPackaged
    ? join(process.resourcesPath, 'fonts', file)
    : join(app.getAppPath(), 'resources', 'fonts', file)
}

function safeFileStem(title: string): string {
  const stem = title
    .trim()
    .replace(/[/\\:*?"<>|]/g, '')
    .replace(/\s+/g, ' ')
    .replace(/^\.+/, '')
    .slice(0, 120)
    .trim()
  return stem.length === 0 ? '화이트보드' : stem
}

function candidateFileName(stem: string, number: number): string {
  return number === 1 ? `${stem}.pdf` : `${stem} (${number}).pdf`
}

function isOccupiedTargetError(error: unknown): boolean {
  return typeof error === 'object' && error !== null &&
    'code' in error && (error.code === 'EEXIST' || error.code === 'EISDIR')
}

export interface BoardPdfExporterDeps {
  openBoard: (boardId: string) => OpenPersonalBoardResult
  getCourseFolder: (courseId: string) => string
  /** Absolute path of a bundled face. Called at most once per face per exporter. */
  resolveFontPath?: (file: TextboxFontFile) => string
}

export interface BoardPdfExporter {
  exportBoard(boardId: string): Promise<{ relPath: string }>
}

export function createBoardPdfExporter(deps: BoardPdfExporterDeps): BoardPdfExporter {
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

  async function embedFace(pdf: PDFDocument, file: TextboxFontFile): Promise<TextboxFont> {
    const bytes = await loadFontBytes(file)
    return {
      embedded: await pdf.embedFont(bytes, { subset: true }),
      outlines: fontkit.create(bytes)
    }
  }

  /** A missing Bold face only costs weight, so it degrades to Regular. */
  async function tryEmbedBold(pdf: PDFDocument): Promise<TextboxFont | null> {
    try {
      return await embedFace(pdf, 'NotoSansKR-Bold.otf')
    } catch (error) {
      console.warn(
        '[canvas] NotoSansKR-Bold.otf could not be loaded; bold text will export in Regular weight.',
        error
      )
      return null
    }
  }

  async function embedTextboxFonts(pdf: PDFDocument, textboxes: DrawingShape[]): Promise<TextboxFonts> {
    pdf.registerFontkit(fontkit)
    const wanted = new Set<TextboxFace>()
    for (const shape of textboxes) {
      for (const face of usedTextboxFaces(
        shape.data.text,
        shape.style,
        shape.data.textRuns
      )) wanted.add(face)
    }
    const bold = wanted.has('bold') ? await tryEmbedBold(pdf) : null
    // Bold boxes whose face failed draw with Regular, so Regular is needed then too.
    const needsRegular = wanted.has('regular') || (wanted.has('bold') && bold === null)
    // Deliberately no Helvetica fallback for the Regular face: exporting
    // readable Korean or failing loudly is safer than silently replacing a
    // student's text.
    const regular = needsRegular ? await embedFace(pdf, 'NotoSansKR-Regular.otf') : null
    return { regular, bold }
  }

  return {
    async exportBoard(boardIdInput) {
      const boardId = requireId(boardIdInput, 'boardId')
      const { board, shapes } = deps.openBoard(boardId)
      const courseFolder = deps.getCourseFolder(board.courseId)
      try {
        if (!(await stat(courseFolder)).isDirectory()) {
          throw new NotFoundError('course folder', courseFolder)
        }
      } catch (error) {
        if (error instanceof NotFoundError) throw error
        throw new NotFoundError('course folder', courseFolder)
      }

      const pdf = await PDFDocument.create()
      pdf.setTitle(board.title)
      pdf.setCreator('Bandal')
      const palette = BOARD_PALETTES[board.surface]

      const textboxes = shapes.filter((shape) => shape.kind === 'textbox')
      const fonts = textboxes.length > 0 ? await embedTextboxFonts(pdf, textboxes) : null

      const renderMedia = createBoardMediaRenderer(pdf, courseFolder)
      for (let pageNumber = 1; pageNumber <= board.pageCount; pageNumber += 1) {
        const page = pdf.addPage(PageSizes.A4)
        const { width, height } = page.getSize()
        drawBackground(page, board.background, palette, width, height)

        for (const shape of shapes) {
          if (shape.page !== pageNumber) continue
          if (shape.kind === 'clip' || shape.kind === 'image') {
            await renderMedia(page, shape)
          } else if (shape.kind === 'ink' || shape.kind === 'highlighter') {
            drawInk(page, shape, palette, board.surface, width, height)
          } else if (shape.kind === 'rect' || shape.kind === 'ellipse') {
            if (shape.data.box !== undefined) {
              drawBoxShape(page, shape, shape.data.box, palette, width, height)
            }
          } else if (shape.kind === 'line' || shape.kind === 'arrow') {
            drawStraightLine(page, shape, palette, width, height)
          } else if (shape.kind === 'textbox' && fonts !== null && shape.data.box !== undefined) {
            drawTextbox(page, shape, shape.data.box, fonts, palette, width, height)
          }
        }
      }

      const bytes = await pdf.save()
      const stem = safeFileStem(board.title)
      for (let number = 1; number <= 1000; number += 1) {
        const relPath = candidateFileName(stem, number)
        try {
          await writeFile(join(courseFolder, relPath), bytes, { flag: 'wx' })
          console.info(
            `[canvas] exported board PDF: ${relPath}`
          )
          return { relPath }
        } catch (error) {
          if (!isOccupiedTargetError(error)) throw error
        }
      }
      throw new ValidationError(`could not find a free name for "${stem}.pdf"`)
    }
  }
}
