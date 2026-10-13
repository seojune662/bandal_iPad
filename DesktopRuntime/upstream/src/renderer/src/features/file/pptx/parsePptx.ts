/**
 * PPTX(OOXML Presentation) 최소 레이아웃 파서 — 순수 함수.
 *
 * 목표는 강의 슬라이드가 "알아볼 수 있게" 나오는 읽기 전용 미리보기다:
 * 텍스트 상자·이미지·표는 배치까지, 차트/스마트아트/OLE 는 라벨 자리표시,
 * 테마 색·폰트·레이아웃(마스터) 상속은 생략한다(기본 텍스트 색으로 렌더).
 * 모든 XML 매칭은 localName 기준이라 접두사(p:, a:)에 의존하지 않는다.
 */

export const EMU_PER_INCH = 914400
const DEFAULT_SLIDE_CX = 12192000 // 16:9 기본
const DEFAULT_SLIDE_CY = 6858000

export interface SlideFrame {
  x: number
  y: number
  w: number
  h: number
}

export interface SlideRun {
  text: string
  sizePt?: number
  bold?: boolean
  color?: string
}

export type SlideParagraph = SlideRun[]

export type SlideShape =
  | { type: 'text'; frame: SlideFrame | null; paragraphs: SlideParagraph[] }
  | { type: 'image'; frame: SlideFrame | null; dataUrl: string | null; label: string }
  | { type: 'table'; frame: SlideFrame | null; rows: SlideParagraph[][] }
  | { type: 'placeholder'; frame: SlideFrame | null; label: string }

export interface ParsedSlide {
  shapes: SlideShape[]
}

export interface ParsedPresentation {
  slideCx: number
  slideCy: number
  slides: ParsedSlide[]
}

export class PptxParseError extends Error {}

type FileMap = ReadonlyMap<string, string | Uint8Array>

const IMAGE_MIME: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp'
}

function parseXml(source: string): Document | null {
  const document_ = new DOMParser().parseFromString(source, 'application/xml')
  return document_.getElementsByTagName('parsererror').length > 0
    ? null
    : document_
}

function childrenByLocalName(parent: Element, name: string): Element[] {
  return Array.from(parent.children).filter((child) => child.localName === name)
}

function firstByLocalName(scope: Element | Document, name: string): Element | null {
  for (const element of Array.from(scope.getElementsByTagName('*'))) {
    if (element.localName === name) return element
  }
  return null
}

/** r:id 류 — 네임스페이스가 뭐든 localName 이 맞는 속성을 찾는다. */
function attributeByLocalName(element: Element, name: string): string | null {
  for (const attribute of Array.from(element.attributes)) {
    if (attribute.localName === name) return attribute.value
  }
  return null
}

function parseRels(source: string | undefined): Map<string, string> {
  const map = new Map<string, string>()
  if (typeof source !== 'string') return map
  const document_ = parseXml(source)
  if (document_ === null) return map
  for (const rel of Array.from(document_.getElementsByTagName('*'))) {
    if (rel.localName !== 'Relationship') continue
    const id = rel.getAttribute('Id')
    const target = rel.getAttribute('Target')
    if (id !== null && target !== null) map.set(id, target)
  }
  return map
}

/** rels Target(상대경로)을 zip 경로로 정규화한다. */
function resolveRelTarget(baseDir: string, target: string): string {
  const joined = target.startsWith('/')
    ? target.slice(1)
    : `${baseDir}/${target}`
  const parts: string[] = []
  for (const part of joined.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') parts.pop()
    else parts.push(part)
  }
  return parts.join('/')
}

function base64FromBytes(bytes: Uint8Array): string {
  let binary = ''
  const CHUNK = 0x8000
  for (let offset = 0; offset < bytes.length; offset += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + CHUNK))
  }
  return btoa(binary)
}

function frameFromXfrm(scope: Element): SlideFrame | null {
  const xfrm = firstByLocalName(scope, 'xfrm')
  if (xfrm === null) return null
  const off = firstByLocalName(xfrm, 'off')
  const ext = firstByLocalName(xfrm, 'ext')
  if (off === null || ext === null) return null
  const x = Number(off.getAttribute('x'))
  const y = Number(off.getAttribute('y'))
  const w = Number(ext.getAttribute('cx'))
  const h = Number(ext.getAttribute('cy'))
  return [x, y, w, h].every(Number.isFinite) && w > 0 && h > 0
    ? { x, y, w, h }
    : null
}

function parseRun(run: Element): SlideRun | null {
  const textElement = firstByLocalName(run, 't')
  if (textElement === null) return null
  const result: SlideRun = { text: textElement.textContent ?? '' }
  const properties = childrenByLocalName(run, 'rPr')[0]
  if (properties !== undefined) {
    const size = Number(properties.getAttribute('sz'))
    if (Number.isFinite(size) && size > 0) result.sizePt = size / 100
    if (properties.getAttribute('b') === '1') result.bold = true
    const fill = firstByLocalName(properties, 'srgbClr')
    const value = fill?.getAttribute('val')
    if (value !== null && value !== undefined && /^[0-9a-f]{6}$/iu.test(value)) {
      result.color = `#${value}`
    }
  }
  return result
}

function parseParagraphs(txBody: Element): SlideParagraph[] {
  const paragraphs: SlideParagraph[] = []
  for (const paragraph of childrenByLocalName(txBody, 'p')) {
    const runs: SlideRun[] = []
    for (const child of Array.from(paragraph.children)) {
      if (child.localName === 'r') {
        const run = parseRun(child)
        if (run !== null) runs.push(run)
      } else if (child.localName === 'br') {
        runs.push({ text: '\n' })
      }
    }
    paragraphs.push(runs)
  }
  return paragraphs
}

function parseTable(tbl: Element): SlideParagraph[][] {
  const rows: SlideParagraph[][] = []
  for (const row of Array.from(tbl.getElementsByTagName('*'))) {
    if (row.localName !== 'tr') continue
    const cells: SlideParagraph[] = []
    for (const cell of childrenByLocalName(row, 'tc')) {
      const txBody = firstByLocalName(cell, 'txBody')
      const paragraphs = txBody === null ? [] : parseParagraphs(txBody)
      // 셀은 문단들을 개행으로 합친 한 문단으로 요약한다.
      cells.push(paragraphs.flatMap((paragraph, index) =>
        index === 0 ? paragraph : [{ text: '\n' }, ...paragraph]
      ))
    }
    if (cells.length > 0) rows.push(cells)
  }
  return rows
}

function graphicLabel(frame: Element): string {
  const uri = firstByLocalName(frame, 'graphicData')?.getAttribute('uri') ?? ''
  if (uri.includes('chart')) return '차트'
  if (uri.includes('diagram')) return '다이어그램'
  if (uri.includes('ole')) return '개체'
  return '그래픽'
}

function parsePicture(
  pic: Element,
  slidePath: string,
  slideRels: Map<string, string>,
  files: FileMap
): SlideShape {
  const frame = frameFromXfrm(pic)
  const blip = firstByLocalName(pic, 'blip')
  const embedId = blip === null ? null : attributeByLocalName(blip, 'embed')
  const target = embedId === null ? undefined : slideRels.get(embedId)
  if (target === undefined) {
    return { type: 'image', frame, dataUrl: null, label: '이미지' }
  }
  const baseDir = slidePath.slice(0, slidePath.lastIndexOf('/'))
  const mediaPath = resolveRelTarget(baseDir, target)
  const dot = mediaPath.lastIndexOf('.')
  const mime = dot < 0 ? undefined : IMAGE_MIME[mediaPath.slice(dot).toLowerCase()]
  const bytes = files.get(mediaPath)
  if (mime === undefined || !(bytes instanceof Uint8Array)) {
    return { type: 'image', frame, dataUrl: null, label: '이미지' }
  }
  return {
    type: 'image',
    frame,
    dataUrl: `data:${mime};base64,${base64FromBytes(bytes)}`,
    label: '이미지'
  }
}

function parseSlide(
  slidePath: string,
  files: FileMap
): ParsedSlide {
  const source = files.get(slidePath)
  const document_ = typeof source === 'string' ? parseXml(source) : null
  if (document_ === null) return { shapes: [] }
  const relsPath = `${slidePath.slice(0, slidePath.lastIndexOf('/'))}/_rels/${slidePath.split('/').at(-1)}.rels`
  const relsSource = files.get(relsPath)
  const slideRels = parseRels(
    typeof relsSource === 'string' ? relsSource : undefined
  )

  const spTree = firstByLocalName(document_, 'spTree')
  if (spTree === null) return { shapes: [] }
  const shapes: SlideShape[] = []
  for (const child of Array.from(spTree.children)) {
    try {
      if (child.localName === 'sp') {
        const txBody = firstByLocalName(child, 'txBody')
        shapes.push({
          type: 'text',
          frame: frameFromXfrm(child),
          paragraphs: txBody === null ? [] : parseParagraphs(txBody)
        })
      } else if (child.localName === 'pic') {
        shapes.push(parsePicture(child, slidePath, slideRels, files))
      } else if (child.localName === 'graphicFrame') {
        const tbl = firstByLocalName(child, 'tbl')
        if (tbl !== null) {
          shapes.push({
            type: 'table',
            frame: frameFromXfrm(child),
            rows: parseTable(tbl)
          })
        } else {
          shapes.push({
            type: 'placeholder',
            frame: frameFromXfrm(child),
            label: graphicLabel(child)
          })
        }
      }
    } catch {
      shapes.push({ type: 'placeholder', frame: null, label: '그래픽' })
    }
  }
  return { shapes }
}

export function parsePptx(files: FileMap): ParsedPresentation {
  const presentationSource = files.get('ppt/presentation.xml')
  const presentation = typeof presentationSource === 'string'
    ? parseXml(presentationSource)
    : null
  if (presentation === null) {
    throw new PptxParseError('presentation.xml 을 읽을 수 없습니다.')
  }

  const sldSz = firstByLocalName(presentation, 'sldSz')
  const cx = Number(sldSz?.getAttribute('cx'))
  const cy = Number(sldSz?.getAttribute('cy'))
  const slideCx = Number.isFinite(cx) && cx > 0 ? cx : DEFAULT_SLIDE_CX
  const slideCy = Number.isFinite(cy) && cy > 0 ? cy : DEFAULT_SLIDE_CY

  const relsSource = files.get('ppt/_rels/presentation.xml.rels')
  const rels = parseRels(typeof relsSource === 'string' ? relsSource : undefined)

  const slidePaths: string[] = []
  const sldIdLst = firstByLocalName(presentation, 'sldIdLst')
  for (const sldId of sldIdLst === null ? [] : childrenByLocalName(sldIdLst, 'sldId')) {
    const relId = attributeByLocalName(sldId, 'id')
    // sldId 는 로컬 id 속성과 r:id 속성이 공존한다 — r:id 쪽을 잡아야 한다.
    const rid = Array.from(sldId.attributes).find(
      (attribute) => attribute.localName === 'id' && attribute.prefix !== null
    )?.value ?? relId
    const target = rid === null ? undefined : rels.get(rid)
    if (target !== undefined) {
      slidePaths.push(resolveRelTarget('ppt', target))
    }
  }
  if (slidePaths.length === 0) {
    throw new PptxParseError('슬라이드가 없습니다.')
  }

  return {
    slideCx,
    slideCy,
    slides: slidePaths.map((path) => parseSlide(path, files))
  }
}
