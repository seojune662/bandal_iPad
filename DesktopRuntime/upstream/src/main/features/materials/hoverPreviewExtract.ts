import { createHash } from 'node:crypto'
import { open } from 'node:fs/promises'
import { join, posix } from 'node:path'
import { inflateRawSync } from 'node:zlib'
import type JSZip from 'jszip'
import type { MaterialHoverPreviewContent } from '../../../shared/types/materialHoverPreview'
import { OFFICE_RUNTIME_VERSION } from '../presentation/conversionRuntime'
import { extractSectionText, parseHwpFileHeader } from '../../../shared/hwpText'
import { HOVER_IMAGE_BYTES, hoverImageContent, isHoverImageExtension } from './hoverPreviewImage'

export const HOVER_TEXT_READ_BYTES = 64 * 1024
export const HOVER_OFFICE_READ_BYTES = 32 * 1024 * 1024
export const HOVER_TEXT_CHARS = 1200
const ZIP_ENTRY_BYTES = 8 * 1024 * 1024
const ZIP_TOTAL_BYTES = 64 * 1024 * 1024
const ZIP_ENTRIES = 4096
const SHEET_ROWS = 8
const SHEET_COLUMNS = 6

export interface HoverExtractionInput {
  /** Already resolved inside the course folder by MaterialsRepo. */
  absolutePath: string
  extension: string
  userData: string
}

export function unavailablePreview(
  reason: Extract<MaterialHoverPreviewContent, { kind: 'unsupported' }>['reason'],
  message: string
): MaterialHoverPreviewContent {
  return { kind: 'unsupported', reason, message }
}

class PreviewLimitError extends Error {}

/** Checks size on the opened handle and never allocates more than limit + 1. */
export async function readHoverBytes(path: string, limit: number, prefix = false): Promise<{ bytes: Buffer; truncated: boolean }> {
  const handle = await open(path, 'r')
  try {
    const info = await handle.stat()
    if (!info.isFile()) throw new Error('Not a file')
    if (!prefix && info.size > limit) throw new PreviewLimitError()
    const bytes = Buffer.alloc(Math.min(info.size, limit) + 1)
    let offset = 0
    while (offset < bytes.length) {
      const read = await handle.read(bytes, offset, bytes.length - offset, offset)
      if (!read.bytesRead) break
      offset += read.bytesRead
    }
    if (!prefix && offset > limit) throw new PreviewLimitError()
    return { bytes: bytes.subarray(0, Math.min(offset, limit)), truncated: info.size > limit || offset > limit }
  } finally { await handle.close() }
}

function trimmedText(text: string, kind: 'markdown' | 'text' = 'text', truncated = false, label?: string): MaterialHoverPreviewContent {
  const clean = text.replace(/\u0000/g, '').trim()
  const chars = Array.from(clean)
  return { kind, text: chars.slice(0, HOVER_TEXT_CHARS).join(''), truncated: truncated || chars.length > HOVER_TEXT_CHARS, ...(label ? { label } : {}) }
}

export async function readHoverText(path: string, markdown: boolean): Promise<MaterialHoverPreviewContent> {
  const { bytes, truncated } = await readHoverBytes(path, HOVER_TEXT_READ_BYTES, true)
  // Streaming decode omits an incomplete multibyte character at the byte limit.
  return trimmedText(new TextDecoder('utf-8').decode(bytes, { stream: truncated }), markdown ? 'markdown' : 'text', truncated)
}

async function boundedZip(bytes: Buffer): Promise<JSZip> {
  const module = await import('jszip')
  const Zip = module.default ?? module
  const zip = await Zip.loadAsync(bytes, { createFolders: false })
  const entries = Object.values(zip.files)
  if (entries.length > ZIP_ENTRIES) throw new PreviewLimitError()
  let total = 0
  for (const entry of entries) {
    if (entry.dir) continue
    const size = (entry as unknown as { _data?: { uncompressedSize?: number } })._data?.uncompressedSize
    if (typeof size !== 'number' || !Number.isFinite(size) || size < 0) throw new PreviewLimitError()
    total += size
    if (total > ZIP_TOTAL_BYTES) throw new PreviewLimitError()
  }
  return zip
}

async function zipBytes(zip: JSZip, path: string, limit = ZIP_ENTRY_BYTES): Promise<Buffer> {
  const entry = zip.file(path)
  if (!entry) throw new Error('Document part missing')
  const size = (entry as unknown as { _data: { uncompressedSize: number } })._data.uncompressedSize
  if (size > limit) throw new PreviewLimitError()
  const bytes = await entry.async('nodebuffer')
  if (bytes.length > limit) throw new PreviewLimitError()
  return bytes
}

function unescapeXml(text: string): string {
  return text.replace(/&(#x[\da-f]+|#\d+|amp|lt|gt|quot|apos);/gi, (source, entity: string) => {
    const named: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" }
    if (entity[0] !== '#') return named[entity] ?? source
    const point = entity[1]?.toLowerCase() === 'x' ? Number.parseInt(entity.slice(2), 16) : Number.parseInt(entity.slice(1), 10)
    return Number.isInteger(point) && point > 0 && point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff) ? String.fromCodePoint(point) : ''
  })
}

/** Office text runs; retains paragraph boundaries without executing XML/HTML. */
export function officeXmlText(xml: string): string {
  const parts: string[] = []
  let length = 0
  const pattern = /<(?:[\w.-]+:)?t(?:\s[^>]*)?>([\s\S]*?)<\/(?:[\w.-]+:)?t\s*>|<\/(?:[\w.-]+:)?p\s*>|<(?:[\w.-]+:)?(?:tab|br)\b[^>]*\/>/g
  for (const match of xml.matchAll(pattern)) {
    const text = match[1] !== undefined ? unescapeXml(match[1].replace(/<[^>]*>/g, '')) : '\n'
    parts.push(text)
    length += text.length
    if (length > HOVER_TEXT_CHARS * 2) break
  }
  return parts.join('').replace(/\n{3,}/g, '\n\n').trim()
}

function attributes(tag: string): Record<string, string> {
  const result: Record<string, string> = {}
  for (const match of tag.matchAll(/([\w:.-]+)\s*=\s*(["'])(.*?)\2/g)) result[match[1]!] = unescapeXml(match[3]!)
  return result
}

async function slidesPreview(zip: JSZip): Promise<MaterialHoverPreviewContent> {
  const presentation = (await zipBytes(zip, 'ppt/presentation.xml')).toString('utf8')
  const ids = [...presentation.matchAll(/<(?:[\w.-]+:)?sldId\b[^>]*>/g)].map(match => attributes(match[0])['r:id']).filter(Boolean)
  if (!ids.length) return { kind: 'slides', text: '', slideCount: 0, truncated: false }
  const relationships = (await zipBytes(zip, 'ppt/_rels/presentation.xml.rels')).toString('utf8')
  const relation = [...relationships.matchAll(/<(?:[\w.-]+:)?Relationship\b[^>]*>/g)]
    .map(match => attributes(match[0])).find(value => value['Id'] === ids[0] && value['TargetMode'] !== 'External')
  const target = relation?.['Target']
  if (!target) throw new Error('Slide missing')
  const path = target.startsWith('/') ? target.slice(1) : posix.normalize(posix.join('ppt', target))
  if (!/^ppt\/slides\/[^/]+\.xml$/i.test(path)) throw new Error('Invalid slide target')
  const text = officeXmlText((await zipBytes(zip, path)).toString('utf8'))
  const chars = Array.from(text)
  const result: Extract<MaterialHoverPreviewContent, { kind: 'slides' }> = { kind: 'slides', text: chars.slice(0, HOVER_TEXT_CHARS).join(''), slideCount: ids.length, truncated: chars.length > HOVER_TEXT_CHARS }
  // Office embeds a representative cover in many decks. Never render/convert
  // all slides just to show a hover card. Restrict to inert raster formats.
  const imagePath = Object.keys(zip.files).find(name => /^docProps\/thumbnail\.(png|jpe?g)$/i.test(name))
  if (imagePath) {
    try {
      const image = await zipBytes(zip, imagePath, 256 * 1024)
      const checked = hoverImageContent(image, imagePath.toLowerCase().endsWith('.png') ? '.png' : '.jpg')
      if (checked.kind === 'image' && checked.width <= 2048 && checked.height <= 2048 && checked.width * checked.height <= 1024 * 1024) result.imageDataUrl = checked.sourceDataUrl
    } catch { /* First-slide text is still useful when the optional cover fails. */ }
  }
  return result
}

async function sheetPreview(bytes: Buffer, extension: string, truncated: boolean): Promise<MaterialHoverPreviewContent> {
  const module = await import('xlsx')
  const xlsx = module.default ?? module
  const delimited = extension === '.csv' || extension === '.tsv'
  const workbook = xlsx.read(delimited ? new TextDecoder('utf-8').decode(bytes, { stream: truncated }) : bytes, {
    type: delimited ? 'string' : 'buffer', sheets: 0, sheetRows: SHEET_ROWS, cellDates: true, cellNF: true,
    ...(extension === '.tsv' ? { FS: '\t' } : {})
  })
  const sheetName = workbook.SheetNames[0] ?? ''
  const sheet = workbook.Sheets[sheetName]
  const rows: string[][] = []
  let clipped = truncated
  if (sheet?.['!ref']) {
    const bounds = xlsx.utils.decode_range(sheet['!ref'])
    const original = xlsx.utils.decode_range(sheet['!fullref'] ?? sheet['!ref'])
    const rowEnd = Math.min(bounds.e.r, bounds.s.r + SHEET_ROWS - 1)
    const columnEnd = Math.min(bounds.e.c, bounds.s.c + SHEET_COLUMNS - 1)
    clipped ||= original.e.r > rowEnd || original.e.c > columnEnd
    let remaining = HOVER_TEXT_CHARS
    for (let r = bounds.s.r; r <= rowEnd; r++) {
      const row: string[] = []
      for (let c = bounds.s.c; c <= columnEnd; c++) {
        const cell = sheet[xlsx.utils.encode_cell({ r, c })]
        const value = cell ? String(xlsx.utils.format_cell(cell)) : ''
        const chars = Array.from(value)
        const visible = chars.slice(0, Math.min(160, remaining)).join('')
        clipped ||= chars.length > Array.from(visible).length
        remaining -= Array.from(visible).length
        row.push(visible)
      }
      rows.push(row)
    }
  }
  return { kind: 'table', rows, sheetName, sheetCount: workbook.SheetNames.length, truncated: clipped }
}

interface CfbEntry { content?: Uint8Array | number[] }
interface CfbContainer { FullPaths: string[]; FileIndex: CfbEntry[] }
interface CfbReader { read(data: Uint8Array, options: { type: 'buffer' }): CfbContainer; find(container: CfbContainer, path: string): CfbEntry | null }

async function hwpPreview(bytes: Buffer): Promise<MaterialHoverPreviewContent> {
  const module = await import('xlsx') as unknown as { CFB?: CfbReader; default?: { CFB?: CfbReader } }
  const cfb = module.CFB ?? module.default?.CFB
  if (!cfb) throw new Error('CFB reader unavailable')
  const container = cfb.read(bytes, { type: 'buffer' })
  const header = parseHwpFileHeader(Uint8Array.from(cfb.find(container, '/FileHeader')?.content ?? []))
  if (!header.isHwp) throw new Error('Invalid HWP')
  if (header.passworded) return unavailablePreview('unreadable', '암호로 보호된 문서는 미리 볼 수 없어요.')
  const sections = container.FullPaths.map((path, index) => ({ path, index }))
    .filter(({ path }) => /BodyText\/Section\d+$/.test(path))
    .sort((left, right) => Number(/Section(\d+)$/.exec(left.path)?.[1]) - Number(/Section(\d+)$/.exec(right.path)?.[1]))
  if (!sections.length) return unavailablePreview('unreadable', '이 한글 문서 형식은 본문 미리보기를 지원하지 않아요.')
  let text = ''
  let consumed = 0
  for (const section of sections) {
    const raw = Uint8Array.from(container.FileIndex[section.index]?.content ?? [])
    const content = header.compressed ? inflateRawSync(raw, { maxOutputLength: ZIP_ENTRY_BYTES }) : raw
    consumed += content.length
    if (consumed > ZIP_TOTAL_BYTES) throw new PreviewLimitError()
    text += `${extractSectionText(content)}\n\n`
    if (text.length > HOVER_TEXT_CHARS) break
  }
  return trimmedText(text, 'text', false, '한글 본문')
}

/** Runs only in the disposable utility process. No conversion or source writes. */
export async function extractMaterialHoverPreview(input: HoverExtractionInput): Promise<MaterialHoverPreviewContent> {
  try {
    const ext = input.extension.toLowerCase()
    if (isHoverImageExtension(ext)) return hoverImageContent((await readHoverBytes(input.absolutePath, HOVER_IMAGE_BYTES)).bytes, ext)
    const delimited = ext === '.csv' || ext === '.tsv'
    let { bytes, truncated } = await readHoverBytes(input.absolutePath, delimited ? HOVER_TEXT_READ_BYTES : HOVER_OFFICE_READ_BYTES, delimited)
    if (ext === '.ppt') {
      const key = createHash('sha256').update(bytes).digest('hex')
      const cached = join(input.userData, 'presentation-runtime', 'cache', OFFICE_RUNTIME_VERSION, `${key}.pptx`)
      try { bytes = (await readHoverBytes(cached, HOVER_OFFICE_READ_BYTES)).bytes }
      catch (error) {
        if ((error as NodeJS.ErrnoException)?.code !== 'ENOENT') throw error
        return unavailablePreview('needs-conversion', '이 PPT는 먼저 자료를 열어야 내용 미리보기를 준비할 수 있어요.')
      }
      return await slidesPreview(await boundedZip(bytes))
    }
    if (ext === '.xls' || ext === '.xlsx' || delimited) {
      if (ext === '.xlsx') await boundedZip(bytes)
      return await sheetPreview(bytes, ext, truncated)
    }
    if ((ext === '.hwp' || ext === '.hwpx') && bytes[0] === 0xd0 && bytes[1] === 0xcf) return await hwpPreview(bytes)
    const zip = await boundedZip(bytes)
    if (ext === '.pptx') return await slidesPreview(zip)
    if (ext === '.docx') {
      return trimmedText(officeXmlText((await zipBytes(zip, 'word/document.xml')).toString('utf8')), 'text', false, 'Word 본문')
    }
    if (ext === '.hwpx' || ext === '.hwp') {
      const sections = Object.keys(zip.files).filter(path => /^Contents\/section\d+\.xml$/i.test(path))
        .sort((left, right) => Number(/section(\d+)/i.exec(left)?.[1]) - Number(/section(\d+)/i.exec(right)?.[1]))
      if (!sections.length) throw new Error('HWPX body missing')
      let text = ''
      for (const path of sections) {
        text += `${officeXmlText((await zipBytes(zip, path)).toString('utf8'))}\n\n`
        if (text.length > HOVER_TEXT_CHARS) break
      }
      return trimmedText(text, 'text', false, '한글 본문')
    }
    return unavailablePreview('unsupported', '이 파일 형식은 내용 미리보기를 지원하지 않아요.')
  } catch (error) {
    return error instanceof PreviewLimitError
      ? unavailablePreview('too-large', '큰 자료는 내용 미리보기를 생략해요. 자료를 열어 확인해 주세요.')
      : unavailablePreview('unreadable', '내용 미리보기를 불러오지 못했어요. 자료를 열어 확인해 주세요.')
  }
}
