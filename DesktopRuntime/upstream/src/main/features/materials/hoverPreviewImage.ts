import type { MaterialHoverPreviewContent } from '../../../shared/types/materialHoverPreview'

export const HOVER_IMAGE_BYTES = 4 * 1024 * 1024
export const HOVER_IMAGE_PIXELS = 16 * 1024 * 1024
export const HOVER_IMAGE_EDGE = 8192
const SVG_BYTES = 256 * 1024
const IMAGE_EXTENSIONS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.avif', '.heic', '.svg'])
export const isHoverImageExtension = (extension: string): boolean => IMAGE_EXTENSIONS.has(extension.toLowerCase())

interface ImageDimensions { width: number; height: number; mime: string }
const pngMagic = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])
const jpegSof = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf])

function jpegDimensions(bytes: Buffer): ImageDimensions | null {
  let offset = 2
  let orientation = 1
  let width = 0, height = 0
  const result = (): ImageDimensions | null => width === 0 || height === 0 ? null : orientation >= 5 && orientation <= 8
    ? { mime: 'image/jpeg', width: height, height: width } : { mime: 'image/jpeg', width, height }
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] !== 0xff) return null
    while (bytes[offset] === 0xff) offset++
    const marker = bytes[offset++]!
    if (marker === 0xda || marker === 0xd9) return result()
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue
    if (offset + 2 > bytes.length) return null
    const size = bytes.readUInt16BE(offset)
    if (size < 2 || offset + size > bytes.length) return null
    if (jpegSof.has(marker)) {
      if (size < 8) return null
      height = Math.max(height, bytes.readUInt16BE(offset + 3)); width = Math.max(width, bytes.readUInt16BE(offset + 5))
    }
    if (marker === 0xe1 && size >= 16 && bytes.toString('ascii', offset + 2, offset + 8) === 'Exif\0\0') {
      const start = offset + 8, end = offset + size
      const little = bytes.toString('ascii', start, start + 2) === 'II'
      const big = bytes.toString('ascii', start, start + 2) === 'MM'
      const u16 = (at: number): number => little ? bytes.readUInt16LE(at) : bytes.readUInt16BE(at)
      const u32 = (at: number): number => little ? bytes.readUInt32LE(at) : bytes.readUInt32BE(at)
      if ((little || big) && u16(start + 2) === 42) {
        const directory = start + u32(start + 4)
        if (directory >= start + 8 && directory + 2 <= end) {
          const entries = Math.min(128, u16(directory))
          for (let i = 0; i < entries; i++) {
            const entry = directory + 2 + i * 12
            if (entry + 12 > end) break
            if (u16(entry) === 0x0112 && u16(entry + 2) === 3 && u32(entry + 4) === 1) { orientation = u16(entry + 8); break }
          }
        }
      }
    }
    offset += size
  }
  return result()
}

function gifDimensions(bytes: Buffer): ImageDimensions | null {
  if (bytes.length < 13) return null
  let width = bytes.readUInt16LE(6), height = bytes.readUInt16LE(8)
  let offset = 13 + ((bytes[10]! & 0x80) ? 3 * (1 << ((bytes[10]! & 7) + 1)) : 0)
  let blocks = 0
  const skip = (): boolean => {
    while (offset < bytes.length) {
      const size = bytes[offset++]!
      if (!size) return true
      offset += size
      if (offset > bytes.length) return false
    }
    return false
  }
  while (offset < bytes.length && ++blocks <= 4096) {
    const kind = bytes[offset++]!
    if (kind === 0x3b) return { width, height, mime: 'image/gif' }
    if (kind === 0x21) { offset++; if (!skip()) return null }
    else if (kind === 0x2c) {
      if (offset + 9 > bytes.length) return null
      width = Math.max(width, bytes.readUInt16LE(offset + 4))
      height = Math.max(height, bytes.readUInt16LE(offset + 6))
      const packed = bytes[offset + 8]!
      offset += 9 + ((packed & 0x80) ? 3 * (1 << ((packed & 7) + 1)) : 0)
      offset++ // LZW minimum code size; following data remains compressed.
      if (!skip()) return null
    } else return null
  }
  return null
}

function webpDimensions(bytes: Buffer): ImageDimensions | null {
  const end = Math.min(bytes.length, bytes.readUInt32LE(4) + 8)
  let width = 0, height = 0, chunks = 0
  const add = (w: number, h: number): void => { width = Math.max(width, w); height = Math.max(height, h) }
  const scan = (start: number, end: number, nested = false): boolean => {
    for (let offset = start; offset + 8 <= end;) {
      if (++chunks > 4096) return false
      const kind = bytes.toString('ascii', offset, offset + 4)
      const size = bytes.readUInt32LE(offset + 4)
      const body = offset + 8
      if (size > end - body) return false
      if (kind === 'VP8X' && size >= 10) add(1 + bytes.readUIntLE(body + 4, 3), 1 + bytes.readUIntLE(body + 7, 3))
      if (kind === 'VP8 ' && size >= 10 && bytes[body + 3] === 0x9d && bytes[body + 4] === 0x01 && bytes[body + 5] === 0x2a) {
        add(bytes.readUInt16LE(body + 6) & 0x3fff, bytes.readUInt16LE(body + 8) & 0x3fff)
      }
      if (kind === 'VP8L' && size >= 5 && bytes[body] === 0x2f) {
        const packed = bytes.readUInt32LE(body + 1)
        add((packed & 0x3fff) + 1, ((packed >>> 14) & 0x3fff) + 1)
      }
      if (kind === 'ANMF') {
        if (nested || size < 16) return false
        add(1 + bytes.readUIntLE(body + 6, 3), 1 + bytes.readUIntLE(body + 9, 3))
        if (!scan(body + 16, body + size, true)) return false
      }
      offset = body + size + (size & 1)
    }
    return true
  }
  return scan(12, end) && width > 0 && height > 0 ? { width, height, mime: 'image/webp' } : null
}

/** Every ispe is checked: selecting only a tiny embedded cover would miss a huge primary item. */
function isoDimensions(bytes: Buffer, extension: string): ImageDimensions | null {
  const dimensions: ImageDimensions[] = []
  let boxes = 0
  const scan = (start: number, end: number, depth: number): boolean => {
    if (depth > 8) return false
    for (let offset = start; offset + 8 <= end;) {
      if (++boxes > 4096) return false
      let size = bytes.readUInt32BE(offset)
      const kind = bytes.toString('ascii', offset + 4, offset + 8)
      let header = 8
      if (size === 1) {
        if (offset + 16 > end) return false
        const large = bytes.readBigUInt64BE(offset + 8)
        if (large > BigInt(end - offset)) return false
        size = Number(large); header = 16
      } else if (size === 0) size = end - offset
      if (size < header || size > end - offset) return false
      const body = offset + header
      if (kind === 'ispe') {
        if (size < header + 12) return false
        dimensions.push({ width: bytes.readUInt32BE(body + 4), height: bytes.readUInt32BE(body + 8), mime: extension === '.avif' ? 'image/avif' : 'image/heic' })
      } else if (kind === 'meta' || kind === 'iprp' || kind === 'ipco') {
        if (!scan(body + (kind === 'meta' ? 4 : 0), offset + size, depth + 1)) return false
      }
      offset += size
    }
    return true
  }
  if (!scan(0, bytes.length, 0) || !dimensions.length) return null
  // Fold each edge conservatively; mixed rotated properties remain within budget.
  return { width: Math.max(...dimensions.map(value => value.width)), height: Math.max(...dimensions.map(value => value.height)), mime: dimensions[0]!.mime }
}

function svgDimensions(bytes: Buffer): ImageDimensions | null {
  if (bytes.length > SVG_BYTES) return null
  const text = bytes.toString('utf8')
  // This is a small static image preview, not an SVG document viewer. Reject
  // active, referenced, animated, embedded, filtered or entity-expanded content.
  if (/<!DOCTYPE|<!ENTITY|<\/?[\w.-]+:|<\s*(?:script|foreignObject|image|use|filter|style|animate\w*|set|fe\w+)\b|\bon\w+\s*=|\b(?:href|src|style)\s*=|url\s*\(/i.test(text)) return null
  const root = /<svg\b([^>]*)>/i.exec(text)
  if (!root || (text.match(/<svg\b/gi)?.length ?? 0) !== 1 || (text.match(/</g)?.length ?? 0) > 4096) return null
  const attributes: Record<string, string> = {}
  for (const attr of root[1]!.matchAll(/([\w:-]+)\s*=\s*(["'])(.*?)\2/g)) attributes[attr[1]!.toLowerCase()] = attr[3]!
  const number = (value: string | undefined): number | null => value !== undefined && /^\s*\d+(?:\.\d+)?(?:px)?\s*$/.test(value) ? Number.parseFloat(value) : null
  let width = number(attributes['width']), height = number(attributes['height'])
  if (width === null || height === null) {
    const viewBox = attributes['viewbox']?.trim().split(/[\s,]+/).map(Number)
    if (viewBox?.length === 4 && viewBox.every(Number.isFinite)) { width ??= viewBox[2]!; height ??= viewBox[3]! }
  }
  return width === null || height === null ? null : { width, height, mime: 'image/svg+xml' }
}

/** Header inspection happens before any decoder receives the immutable bytes. */
export function hoverImageDimensions(bytes: Buffer, extension: string): ImageDimensions | null {
  if (bytes.length < 10 || bytes.length > HOVER_IMAGE_BYTES) return null
  if (bytes.length >= 24 && bytes.subarray(0, 8).equals(pngMagic) && bytes.toString('ascii', 12, 16) === 'IHDR') {
    return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), mime: 'image/png' }
  }
  if (bytes[0] === 0xff && bytes[1] === 0xd8) return jpegDimensions(bytes)
  if (/^GIF8[79]a$/.test(bytes.toString('ascii', 0, 6))) return gifDimensions(bytes)
  if (bytes.length >= 26 && bytes.toString('ascii', 0, 2) === 'BM') {
    const header = bytes.readUInt32LE(14)
    return header === 12
      ? { width: bytes.readUInt16LE(18), height: bytes.readUInt16LE(20), mime: 'image/bmp' }
      : header >= 40 ? { width: bytes.readInt32LE(18), height: Math.abs(bytes.readInt32LE(22)), mime: 'image/bmp' } : null
  }
  if (bytes.length >= 20 && bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP') return webpDimensions(bytes)
  if (bytes.length >= 16 && bytes.toString('ascii', 4, 8) === 'ftyp' && (extension === '.avif' || extension === '.heic')) return isoDimensions(bytes, extension)
  if (extension === '.svg') return svgDimensions(bytes)
  return null
}

export function hoverImageContent(bytes: Buffer, extension: string): MaterialHoverPreviewContent {
  const info = hoverImageDimensions(bytes, extension)
  if (bytes.length > HOVER_IMAGE_BYTES || (info && (info.width > HOVER_IMAGE_EDGE || info.height > HOVER_IMAGE_EDGE || info.width * info.height > HOVER_IMAGE_PIXELS))) {
    return { kind: 'unsupported', reason: 'too-large', message: '큰 이미지는 내용 미리보기를 생략해요. 자료를 열어 확인해 주세요.' }
  }
  if (!info || !Number.isFinite(info.width) || !Number.isFinite(info.height) || info.width <= 0 || info.height <= 0) {
    return { kind: 'unsupported', reason: 'unreadable', message: '이 이미지는 내용 미리보기를 준비할 수 없어요. 자료를 열어 확인해 주세요.' }
  }
  return { kind: 'image', width: info.width, height: info.height, sourceDataUrl: `data:${info.mime};base64,${bytes.toString('base64')}` }
}
