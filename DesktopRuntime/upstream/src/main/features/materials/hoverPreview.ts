import { utilityProcess, type UtilityProcess } from 'electron'
import { stat } from 'node:fs/promises'
import { basename, join } from 'node:path'
import { materialKindForPath } from '../../../shared/materialKind'
import type { MaterialHoverPreview, MaterialHoverPreviewContent, MaterialHoverPreviewRequest } from '../../../shared/types/materialHoverPreview'
import type { MaterialsRepo } from './materialsRepo'
import { HOVER_OFFICE_READ_BYTES, readHoverText, unavailablePreview, type HoverExtractionInput } from './hoverPreviewExtract'
import { HOVER_IMAGE_BYTES } from './hoverPreviewImage'

const OFFICE_EXTENSIONS = new Set(['.docx', '.xlsx', '.xls', '.csv', '.tsv', '.pptx', '.ppt', '.hwp', '.hwpx'])
const TEXT_EXTENSIONS = new Set([
  '.txt', '.json', '.yml', '.yaml', '.xml', '.html', '.htm', '.css', '.scss', '.sass', '.less',
  '.js', '.jsx', '.mjs', '.cjs', '.ts', '.tsx', '.mts', '.cts', '.tex', '.log', '.srt', '.vtt',
  '.py', '.pyw', '.java', '.c', '.h', '.cpp', '.cc', '.cxx', '.hpp', '.hh', '.hxx', '.cs', '.go',
  '.rs', '.swift', '.kt', '.kts', '.sh', '.bash', '.zsh', '.fish', '.ps1', '.rb', '.php', '.pl',
  '.pm', '.r', '.sql', '.lua', '.dart', '.scala', '.groovy', '.gradle', '.vue', '.svelte', '.astro',
  '.toml', '.ini', '.cfg', '.conf', '.properties', '.env', '.gitignore', '.gitattributes', '.editorconfig'
])
export const HOVER_PARSE_TIMEOUT_MS = 3000
const CACHE_ENTRIES = 32
const CACHE_BYTES = 16 * 1024 * 1024

interface Extractor {
  read(input: HoverExtractionInput): Promise<MaterialHoverPreviewContent>
  dispose(): void
}

/** A slow/malformed office document can be killed without blocking the UI or main. */
export function createHoverPreviewExtractor(): Extractor {
  let child: UtilityProcess | null = null
  let sequence = 0
  let pending: { id: number; resolve: (value: MaterialHoverPreviewContent) => void; timer: NodeJS.Timeout } | null = null
  let idle: NodeJS.Timeout | null = null
  let disposed = false
  const queue: { id: number; input: HoverExtractionInput; resolve: (value: MaterialHoverPreviewContent) => void }[] = []
  const stop = (): void => {
    if (idle) clearTimeout(idle)
    idle = null
    const old = child
    child = null
    old?.kill()
  }
  const fail = (): void => {
    const old = pending
    pending = null
    if (old) {
      clearTimeout(old.timer)
      old.resolve(unavailablePreview('timeout', '내용 미리보기를 준비하지 못했어요. 자료를 열어 확인해 주세요.'))
    }
    stop()
    pump()
  }
  const pump = (): void => {
    if (disposed || pending || !queue.length) return
    const job = queue.shift()!
    if (idle) clearTimeout(idle)
    idle = null
    try {
      if (!child) {
        const worker = utilityProcess.fork(join(__dirname, 'hoverPreviewHost.js'), [], {
          serviceName: 'Bandal Material Preview', stdio: 'pipe', execArgv: ['--max-old-space-size=128']
        })
        child = worker
        worker.stdout?.on('data', () => undefined)
        worker.stderr?.on('data', () => undefined)
        worker.on('exit', () => { if (child === worker) fail() })
        worker.on('message', (message: { id: number; content: MaterialHoverPreviewContent }) => {
          if (child !== worker || pending?.id !== message.id) return
          const request = pending
          pending = null
          clearTimeout(request.timer)
          request.resolve(message.content)
          if (queue.length) pump()
          else { idle = setTimeout(stop, 10_000); idle.unref() }
        })
      }
      const timer = setTimeout(fail, HOVER_PARSE_TIMEOUT_MS)
      pending = { id: job.id, resolve: job.resolve, timer }
      child.postMessage({ id: job.id, input: job.input })
    } catch { job.resolve(unavailablePreview('unreadable', '내용 미리보기를 불러오지 못했어요.')); fail() }
  }
  return {
    read(input) {
      if (disposed) return Promise.resolve(unavailablePreview('unreadable', '내용 미리보기가 종료되었습니다.'))
      return new Promise(resolve => {
        // One board card may contain several independent images. Keep them in
        // one bounded lane instead of cancelling siblings. Old queued cards
        // cannot accumulate arbitrarily when the pointer moves quickly.
        if (queue.length >= 8) queue.shift()!.resolve(unavailablePreview('timeout', '내용 미리보기 요청이 취소되었어요.'))
        queue.push({ id: ++sequence, input, resolve })
        pump()
      })
    },
    dispose(): void {
      disposed = true
      for (const job of queue.splice(0)) job.resolve(unavailablePreview('timeout', '내용 미리보기가 종료되었습니다.'))
      fail()
    }
  }
}

export interface MaterialHoverPreviewServiceDeps {
  materials: Pick<MaterialsRepo, 'absolutePathForAsync'>
  userData: string
  /** In-process extraction in focused tests; production uses the utility host. */
  extractor?: Extractor
}

export function createMaterialHoverPreviewService(deps: MaterialHoverPreviewServiceDeps) {
  const extractor = deps.extractor ?? createHoverPreviewExtractor()
  const cache = new Map<string, { result: MaterialHoverPreview; bytes: number }>()
  const loading = new Map<string, Promise<MaterialHoverPreview>>()
  let cacheBytes = 0
  let disposed = false
  const retain = (key: string, result: MaterialHoverPreview): void => {
    if (disposed || result.content.kind === 'unsupported') return
    const bytes = Buffer.byteLength(JSON.stringify(result))
    if (bytes > CACHE_BYTES) return
    const previous = cache.get(key)
    cacheBytes -= previous?.bytes ?? 0
    cache.delete(key)
    cache.set(key, { result, bytes })
    cacheBytes += bytes
    while (cache.size > CACHE_ENTRIES || cacheBytes > CACHE_BYTES) {
      const oldest = cache.entries().next().value
      if (!oldest) break
      cache.delete(oldest[0]); cacheBytes -= oldest[1].bytes
    }
  }
  return {
    async read(request: MaterialHoverPreviewRequest): Promise<MaterialHoverPreview> {
      if (disposed) throw new Error('자료 미리보기가 종료되었습니다.')
      const path = await deps.materials.absolutePathForAsync(request.courseId, request.relPath)
      const info = await stat(path)
      if (disposed) throw new Error('자료 미리보기가 종료되었습니다.')
      if (!info.isFile()) throw new Error('파일 자료만 미리 볼 수 있어요.')
      const name = basename(request.relPath)
      const ext = name.slice(name.lastIndexOf('.')).toLowerCase()
      const kind = materialKindForPath(request.relPath)
      const metadata = { name, relPath: request.relPath, size: info.size, mtime: info.mtimeMs }
      const key = JSON.stringify([request.courseId, request.relPath, info.mtimeMs, info.size, info.ctimeMs])
      const cached = cache.get(key)
      if (cached) { cache.delete(key); cache.set(key, cached); return cached.result }
      const existing = loading.get(key)
      if (existing) return existing
      const pending = (async (): Promise<MaterialHoverPreview> => {
        let content: MaterialHoverPreviewContent
        if (kind === 'pdf' || kind === 'video') content = { kind }
        else if (kind === 'image') content = info.size > HOVER_IMAGE_BYTES
          ? unavailablePreview('too-large', '큰 이미지는 내용 미리보기를 생략해요. 자료를 열어 확인해 주세요.')
          : await extractor.read({ absolutePath: path, extension: ext, userData: deps.userData })
        else if (ext === '.wav') content = { kind: 'recording' }
        else if (kind === 'note' || TEXT_EXTENSIONS.has(ext)) content = await readHoverText(path, kind === 'note')
        else if (OFFICE_EXTENSIONS.has(ext)) {
          content = info.size > HOVER_OFFICE_READ_BYTES && ext !== '.csv' && ext !== '.tsv'
            ? unavailablePreview('too-large', '큰 자료는 내용 미리보기를 생략해요. 자료를 열어 확인해 주세요.')
            : await extractor.read({ absolutePath: path, extension: ext, userData: deps.userData })
        } else content = unavailablePreview('unsupported', '이 파일 형식은 내용 미리보기를 지원하지 않아요.')
        const result = { ...metadata, content }
        // A save during extraction must not poison the revision-keyed cache.
        const after = await stat(path).catch(() => null)
        if (after?.mtimeMs === info.mtimeMs && after.size === info.size && after.ctimeMs === info.ctimeMs) retain(key, result)
        return result
      })()
      loading.set(key, pending)
      try { return await pending } finally { loading.delete(key) }
    },
    dispose(): void { disposed = true; extractor.dispose(); cache.clear(); loading.clear(); cacheBytes = 0 }
  }
}
