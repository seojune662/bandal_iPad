import { createHash } from 'node:crypto'
import { readFile, stat } from 'node:fs/promises'
import { extname } from 'node:path'
import { extractMaterialText } from '../materials/textExtract'

const MAX_SOURCE_BYTES = 50 * 1024 * 1024
const DEFAULT_MAX_CHARS = 200_000
const DEFAULT_MAX_PAGES = 200

export interface LearningMaterialSource {
  text: string
  pages: Array<{ page: number; text: string }>
  truncated: boolean
  /** Hash of the exact file bytes used for grounding this result. */
  contentHash: string
}
export interface LearningMaterialSourceOptions { maxChars?: number; maxPages?: number; signal?: AbortSignal }

// PDF.js creates one identity matrix at import time even for text-only parsing.
// This shim deliberately offers no rendering methods. Rendering must use the renderer.
class TextOnlyDOMMatrix {
  a = 1; b = 0; c = 0; d = 1; e = 0; f = 0
  constructor(transform?: unknown) {
    if (transform !== undefined) throw new Error('학습 자료 추출에서는 PDF 그리기 변환을 사용할 수 없어요.')
  }
}
let pdfRuntime: Promise<typeof import('pdfjs-dist/legacy/build/pdf.mjs')> | undefined

async function loadPdfRuntime(): Promise<typeof import('pdfjs-dist/legacy/build/pdf.mjs')> {
  if (!pdfRuntime) pdfRuntime = (async () => {
    const globals = globalThis as Record<string, unknown>
    if (globals['DOMMatrix'] === undefined) globals['DOMMatrix'] = TextOnlyDOMMatrix
    // Bundled as a lazy module, avoiding a worker URL/file outside the packaged app.
    const worker = await import('pdfjs-dist/legacy/build/pdf.worker.mjs')
    globals['pdfjsWorker'] = { WorkerMessageHandler: worker.WorkerMessageHandler }
    return import('pdfjs-dist/legacy/build/pdf.mjs')
  })()
  return pdfRuntime
}

function checkCancelled(signal?: AbortSignal): void {
  if (!signal?.aborted) return
  const error = new Error('자료 읽기를 중지했어요.')
  error.name = 'AbortError'
  throw error
}
function hash(bytes: Uint8Array): string { return createHash('sha256').update(bytes).digest('hex') }

/** Caller must resolve absPath inside the selected course before entering this service. */
export async function extractLearningMaterialSource(
  absPath: string,
  options: LearningMaterialSourceOptions = {}
): Promise<LearningMaterialSource | null> {
  const maxChars = options.maxChars ?? DEFAULT_MAX_CHARS
  const maxPages = options.maxPages ?? DEFAULT_MAX_PAGES
  if (!Number.isInteger(maxChars) || maxChars < 1 || !Number.isInteger(maxPages) || maxPages < 1) throw new Error('자료 읽기 범위가 올바르지 않아요.')
  checkCancelled(options.signal)
  const info = await stat(absPath)
  if (!info.isFile() || info.size > MAX_SOURCE_BYTES) throw new Error('학습 자료는 50MiB 이하의 파일이어야 해요.')
  const bytes = await readFile(absPath, { signal: options.signal })
  if (bytes.byteLength > MAX_SOURCE_BYTES) throw new Error('학습 자료는 50MiB 이하의 파일이어야 해요.')
  const contentHash = hash(bytes)
  const extension = extname(absPath).toLowerCase()
  if (extension !== '.pdf') {
    const text = await extractMaterialText(absPath, extension, maxChars)
    checkCancelled(options.signal)
    if (text === null) return null
    if (hash(await readFile(absPath, { signal: options.signal })) !== contentHash) throw new Error('자료를 읽는 동안 원본이 변경됐어요. 다시 시도해 주세요.')
    const marker = text.match(/\n…\(잘림: [\d,]+자 초과분 생략\. maxChars를 늘려 다시 요청할 수 있습니다\.\)$/u)
    return { text: marker ? text.slice(0, marker.index) : text, pages: [], truncated: marker !== null, contentHash }
  }

  const pdfjs = await loadPdfRuntime()
  checkCancelled(options.signal)
  const loading = pdfjs.getDocument({ data: new Uint8Array(bytes), isEvalSupported: false,
    disableFontFace: true, useSystemFonts: true, isOffscreenCanvasSupported: false,
    isImageDecoderSupported: false, useWasm: false, useWorkerFetch: false, enableXfa: false, stopAtErrors: true })
  const abort = (): void => { void loading.destroy().catch(() => undefined) }
  options.signal?.addEventListener('abort', abort, { once: true })
  try {
    const document = await loading.promise
    const pages: LearningMaterialSource['pages'] = []
    let remaining = maxChars
    let truncated = document.numPages > maxPages
    for (let pageNumber = 1; pageNumber <= Math.min(document.numPages, maxPages); pageNumber++) {
      checkCancelled(options.signal)
      const page = await document.getPage(pageNumber)
      const content = await page.getTextContent()
      const text = content.items.map(item => 'str' in item ? `${item.str}${item.hasEOL ? '\n' : ' '}` : '').join('').replace(/[\t ]+/gu, ' ').replace(/ *\n */gu, '\n').trim()
      page.cleanup()
      const kept = Array.from(text).slice(0, remaining).join('')
      pages.push({ page: pageNumber, text: kept })
      remaining -= Array.from(kept).length
      if (kept.length < text.length || remaining === 0 && pageNumber < document.numPages) truncated = true
      if (remaining === 0) break
    }
    checkCancelled(options.signal)
    if (!pages.some(page => page.text.trim())) throw new Error('이 PDF에서 텍스트를 찾지 못했어요. 스캔 자료는 텍스트가 있는 자료로 변환한 뒤 사용해 주세요.')
    return { text: pages.map(page => `## 페이지 ${page.page}\n${page.text}`).join('\n\n'), pages, truncated, contentHash }
  } catch (error) {
    checkCancelled(options.signal)
    if (error instanceof Error && error.name === 'PasswordException') throw new Error('암호로 잠긴 PDF예요. 잠금을 해제한 자료를 사용해 주세요.')
    throw error
  } finally {
    options.signal?.removeEventListener('abort', abort)
    await loading.destroy()
  }
}
