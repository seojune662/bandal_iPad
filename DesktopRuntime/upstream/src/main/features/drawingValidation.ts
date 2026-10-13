import type {
  DrawingBox,
  DrawingClipSource,
  DrawingColor,
  DrawingData,
  DrawingImageSource,
  DrawingKind,
  DrawingPoint,
  DrawingStyle,
  DrawingTextRun,
  TextAlign
} from '../../shared/types/drawing'
import {
  DRAWING_COLORS,
  DRAWING_KINDS,
  TEXT_ALIGNS
} from '../../shared/types/drawing'
import { normalizeTextRuns } from '../../shared/textRuns'
import { ValidationError } from '../db/errors'

const TEXT_FLAG_FIELDS = ['bold', 'italic', 'underline', 'strike'] as const

function assertUnit(value: unknown, field: string): number {
  if (
    typeof value !== 'number' ||
    !Number.isFinite(value) ||
    value < 0 ||
    value > 1
  ) {
    throw new ValidationError(`${field} must be a finite number between 0 and 1`)
  }
  return value
}

function assertPositive(value: unknown, field: string, max = 1): number {
  if (
    typeof value !== 'number' ||
    !Number.isFinite(value) ||
    value <= 0 ||
    value > max
  ) {
    throw new ValidationError(
      `${field} must be a finite number greater than 0 and at most ${max}`
    )
  }
  return value
}

function assertPoint(value: unknown, field: string): DrawingPoint {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new ValidationError(`${field} must be a drawing point`)
  }
  const point = value as Partial<DrawingPoint>
  return {
    x: assertUnit(point.x, `${field}.x`),
    y: assertUnit(point.y, `${field}.y`),
    p: assertUnit(point.p, `${field}.p`)
  }
}

function assertBox(value: unknown, field: string): DrawingBox {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new ValidationError(`${field} must be a drawing box`)
  }
  const box = value as Partial<DrawingBox>
  const result: DrawingBox = {
    x: assertUnit(box.x, `${field}.x`),
    y: assertUnit(box.y, `${field}.y`),
    width: assertUnit(box.width, `${field}.width`),
    height: assertUnit(box.height, `${field}.height`)
  }
  if (result.x + result.width > 1 || result.y + result.height > 1) {
    throw new ValidationError(`${field} must stay inside the normalized page`)
  }
  return result
}

function assertImage(value: unknown): DrawingImageSource {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new ValidationError('data.image must be an object')
  }
  const image = value as Partial<DrawingImageSource>
  if (
    typeof image.relPath !== 'string' ||
    image.relPath.trim() === '' ||
    typeof image.label !== 'string' ||
    image.label.trim() === ''
  ) {
    throw new ValidationError('data.image needs relPath and label')
  }
  const result: DrawingImageSource = {
    relPath: image.relPath,
    label: image.label
  }
  if (image.storage !== undefined || image.assetId !== undefined) {
    if (
      image.storage !== 'shared' ||
      typeof image.assetId !== 'string' ||
      image.assetId.trim() === '' ||
      typeof image.widthPx !== 'number' ||
      !Number.isInteger(image.widthPx) ||
      image.widthPx <= 0 ||
      typeof image.heightPx !== 'number' ||
      !Number.isInteger(image.heightPx) ||
      image.heightPx <= 0
    ) {
      throw new ValidationError('shared data.image needs assetId and pixel dimensions')
    }
    result.storage = 'shared'
    result.assetId = image.assetId
    result.widthPx = image.widthPx
    result.heightPx = image.heightPx
  }
  return result
}

function assertClip(value: unknown): DrawingClipSource {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new ValidationError('data.clip must be an object')
  }
  const clip = value as Partial<DrawingClipSource>
  if (
    typeof clip.relPath !== 'string' ||
    clip.relPath.trim() === '' ||
    typeof clip.label !== 'string' ||
    clip.label.trim() === ''
  ) {
    throw new ValidationError('data.clip needs relPath and label')
  }
  if (typeof clip.page !== 'number' || !Number.isInteger(clip.page) || clip.page < 1) {
    throw new ValidationError('data.clip.page must be an integer >= 1')
  }
  const result: DrawingClipSource = {
    relPath: clip.relPath,
    page: clip.page,
    label: clip.label
  }
  if (clip.crop !== undefined) result.crop = assertBox(clip.crop, 'data.clip.crop')
  return result
}

function assertTextRuns(text: string, value: unknown): DrawingTextRun[] {
  if (!Array.isArray(value)) {
    throw new ValidationError('data.textRuns needs textbox text and an array')
  }
  const runs = value.map((raw, index) => {
    if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
      throw new ValidationError(`data.textRuns[${index}] must be an object`)
    }
    const run = raw as DrawingTextRun
    if (
      !Number.isInteger(run.from) ||
      !Number.isInteger(run.to) ||
      run.from < 0 ||
      run.to <= run.from ||
      run.to > text.length
    ) {
      throw new ValidationError(`data.textRuns[${index}] has an invalid range`)
    }
    if (run.style === null || typeof run.style !== 'object' || Array.isArray(run.style)) {
      throw new ValidationError(`data.textRuns[${index}].style must be an object`)
    }
    const style: DrawingTextRun['style'] = {}
    if (run.style.color !== undefined) {
      if (!DRAWING_COLORS.includes(run.style.color)) {
        throw new ValidationError(`data.textRuns[${index}].style.color is invalid`)
      }
      style.color = run.style.color
    }
    if (run.style.fontSizePt !== undefined) {
      style.fontSizePt = assertPositive(
        run.style.fontSizePt,
        `data.textRuns[${index}].style.fontSizePt`,
        96
      )
    }
    for (const field of TEXT_FLAG_FIELDS) {
      const flag = run.style[field]
      if (flag === undefined) continue
      if (typeof flag !== 'boolean') {
        throw new ValidationError(`data.textRuns[${index}].style.${field} must be boolean`)
      }
      style[field] = flag
    }
    return { from: run.from, to: run.to, style }
  })
  const normalized = normalizeTextRuns(text, runs)
  if (normalized.length !== runs.length) {
    throw new ValidationError('data.textRuns must be ordered, non-overlapping ranges')
  }
  return normalized
}

export function assertDrawingKind(
  value: unknown,
  allowedKinds: readonly DrawingKind[] = DRAWING_KINDS
): DrawingKind {
  if (!allowedKinds.includes(value as DrawingKind)) {
    throw new ValidationError(`kind must be one of ${allowedKinds.join(', ')}`)
  }
  return value as DrawingKind
}

export function assertDrawingData(
  value: unknown,
  kind: DrawingKind,
  options: { allowClip?: boolean } = {}
): DrawingData {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new ValidationError('data must be an object')
  }
  const candidate = value as DrawingData
  let points: DrawingPoint[] | undefined
  if (candidate.points !== undefined) {
    if (!Array.isArray(candidate.points)) {
      throw new ValidationError('data.points must be an array')
    }
    points = candidate.points.map((point, index) =>
      assertPoint(point, `data.points[${index}]`)
    )
  }
  const box = candidate.box === undefined
    ? undefined
    : assertBox(candidate.box, 'data.box')
  const text = candidate.text
  if (text !== undefined && typeof text !== 'string') {
    throw new ValidationError('data.text must be a string')
  }
  let textRuns: DrawingTextRun[] | undefined
  if (candidate.textRuns !== undefined) {
    if (text === undefined) {
      throw new ValidationError('data.textRuns needs textbox text and an array')
    }
    textRuns = assertTextRuns(text, candidate.textRuns)
  }

  if ((kind === 'ink' || kind === 'highlighter') && (points?.length ?? 0) === 0) {
    throw new ValidationError(`${kind} data needs at least one point`)
  }
  if ((kind === 'rect' || kind === 'ellipse' || kind === 'textbox') && box === undefined) {
    throw new ValidationError(`${kind} data needs a box`)
  }
  if (
    (kind === 'line' || kind === 'arrow') &&
    box === undefined &&
    (points?.length ?? 0) < 2
  ) {
    throw new ValidationError(`${kind} data needs a box or two points`)
  }
  if (kind === 'textbox' && text === undefined) {
    throw new ValidationError('textbox data needs text')
  }

  const image = candidate.image === undefined
    ? undefined
    : assertImage(candidate.image)
  if (kind === 'image' && (image === undefined || box === undefined)) {
    throw new ValidationError('image data needs a box and an image source')
  }

  const clip = options.allowClip === true && candidate.clip !== undefined
    ? assertClip(candidate.clip)
    : undefined
  if (kind === 'clip' && (clip === undefined || box === undefined)) {
    throw new ValidationError('clip data needs a box and a clip source')
  }

  const result: DrawingData = {}
  if (points !== undefined) result.points = points
  if (box !== undefined) result.box = box
  if (text !== undefined) result.text = text
  if (textRuns !== undefined && textRuns.length > 0) result.textRuns = textRuns
  if (image !== undefined) result.image = image
  if (clip !== undefined) result.clip = clip
  return result
}

export function assertDrawingStyle(value: unknown): DrawingStyle {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new ValidationError('style must be an object')
  }
  const style = value as Partial<DrawingStyle>
  if (!DRAWING_COLORS.includes(style.color as DrawingColor)) {
    throw new ValidationError(
      `style.color must be one of ${DRAWING_COLORS.join(', ')}`
    )
  }
  const result: DrawingStyle = {
    color: style.color as DrawingColor,
    width: assertPositive(style.width, 'style.width'),
    opacity: assertUnit(style.opacity, 'style.opacity')
  }
  if (style.fontScale !== undefined) {
    result.fontScale = assertPositive(style.fontScale, 'style.fontScale', 10)
  }
  if (style.fontSizePt !== undefined) {
    result.fontSizePt = assertPositive(style.fontSizePt, 'style.fontSizePt', 96)
  }
  for (const field of TEXT_FLAG_FIELDS) {
    const flag = style[field]
    if (flag === undefined) continue
    if (typeof flag !== 'boolean') {
      throw new ValidationError(`style.${field} must be a boolean`)
    }
    result[field] = flag
  }
  if (style.align !== undefined) {
    if (!TEXT_ALIGNS.includes(style.align as TextAlign)) {
      throw new ValidationError(`style.align must be one of ${TEXT_ALIGNS.join(', ')}`)
    }
    result.align = style.align
  }
  if (style.fill !== undefined) {
    if (!DRAWING_COLORS.includes(style.fill as DrawingColor)) {
      throw new ValidationError(`style.fill must be one of ${DRAWING_COLORS.join(', ')}`)
    }
    result.fill = style.fill
  }
  return result
}
