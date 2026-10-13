import { randomUUID } from 'node:crypto'
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { basename, dirname, join } from 'node:path'
import { PDFDocument, degrees } from 'pdf-lib'
import fontkit from '@pdf-lib/fontkit'
import type { MaterialsRepo } from '../materials/materialsRepo'
import { createPdfExporter, resolveDefaultFontPath } from '../pdf/exportPdf'
import { createConversionRuntime } from './conversionRuntime'
import type { PresentationPdfPage, PresentationRef } from '../../../shared/types/presentation'

interface Session extends PresentationRef { id: string; folder: string; pageCount: number; next: number; bytes: number; includeInk: boolean; busy: boolean; timer: ReturnType<typeof setTimeout> }

export function createPresentationService(deps: { userData: string; materials: MaterialsRepo; exporter: ReturnType<typeof createPdfExporter>; changed: (courseId: string) => void }) {
  const runtime = createConversionRuntime(deps.userData)
  const sessions = new Map<string, Session>()
  const preparing = new Set<string>()
  function source(ref: PresentationRef): string {
    if (!/\.pptx?$/i.test(ref.relPath)) throw new Error('PPT 또는 PPTX 파일을 선택해 주세요.')
    return deps.materials.absolutePathFor(ref.courseId, ref.relPath)
  }
  async function prepare(ref: PresentationRef & { requestId: string }) {
    const path = source(ref)
    if (preparing.has(ref.requestId)) throw new Error('이미 파일을 여는 중이에요.')
    preparing.add(ref.requestId)
    try {
      if ((await stat(path)).size > 128 * 1024 * 1024) throw new Error('128MB 이하 프레젠테이션을 열어 주세요.')
      const bytes = /\.ppt$/i.test(ref.relPath) ? await runtime.normalize(path, ref.requestId) : await readFile(path)
      return { encoding: 'base64' as const, data: bytes.toString('base64'), mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation', sizeBytes: bytes.length }
    } finally { preparing.delete(ref.requestId) }
  }
  async function cancel(sessionId: string): Promise<void> {
    const session = sessions.get(sessionId)
    if (!session) return
    sessions.delete(sessionId); clearTimeout(session.timer)
    if (!session.busy) await rm(session.folder, { recursive: true, force: true })
  }
  function sessionFor(id: string): Session {
    const value = sessions.get(id)
    if (!value) throw new Error('변환 세션이 만료되었어요. 다시 시도해 주세요.')
    return value
  }
  async function start(input: PresentationRef & { pageCount: number; includeInk: boolean }): Promise<{ sessionId: string }> {
    source(input)
    if (!Number.isInteger(input.pageCount) || input.pageCount < 1 || input.pageCount > 1000) throw new Error('1~1,000페이지 프레젠테이션을 변환할 수 있어요.')
    if (sessions.size >= 2) throw new Error('진행 중인 변환이 끝난 후 다시 시도해 주세요.')
    const root = join(deps.userData, 'presentation-pdf')
    await mkdir(root, { recursive: true })
    const folder = await mkdtemp(join(root, 'job-')), id = randomUUID()
    const timer = setTimeout(() => void cancel(id), 30 * 60_000)
    timer.unref()
    sessions.set(id, { ...input, id, folder, timer, next: 0, bytes: 0, busy: false })
    return { sessionId: id }
  }
  async function append(input: PresentationPdfPage): Promise<void> {
    const session = sessionFor(input.sessionId)
    if (session.busy || input.index !== session.next || input.index >= session.pageCount) throw new Error('슬라이드 순서가 올바르지 않아요.')
    if (![input.width, input.height].every((n) => Number.isFinite(n) && n >= 1 && n <= 14_400)) throw new Error('슬라이드 크기가 올바르지 않아요.')
    if (typeof input.pngBase64 !== 'string' || input.pngBase64.length > 32 * 1024 * 1024) throw new Error('슬라이드 이미지가 너무 커요.')
    const png = Buffer.from(input.pngBase64, 'base64')
    if (!png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) throw new Error('슬라이드 이미지 형식이 올바르지 않아요.')
    if (!Array.isArray(input.text) || input.text.length > 20_000 || input.text.some((run) => typeof run.text !== 'string' || run.text.length > 10_000 || ![run.x, run.y, run.width, run.height, run.fontSize, run.rotation].every(Number.isFinite))) throw new Error('슬라이드 텍스트 정보가 올바르지 않아요.')
    const metadata = JSON.stringify({ width: input.width, height: input.height, text: input.text })
    const textBytes = Buffer.byteLength(metadata)
    if (textBytes > 4 * 1024 * 1024 || session.bytes + png.length + textBytes > 300 * 1024 * 1024) throw new Error('PDF 변환 데이터가 너무 커요 (페이지 텍스트 4MB, 전체 300MB 제한).')
    session.busy = true
    try {
      await writeFile(join(session.folder, `${input.index}.png`), png, { flag: 'wx' })
      await writeFile(join(session.folder, `${input.index}.json`), metadata, { flag: 'wx' })
      session.next++; session.bytes += png.length + textBytes
    } finally { session.busy = false; if (!sessions.has(session.id)) await rm(session.folder, { recursive: true, force: true }) }
  }
  async function finish(id: string): Promise<PresentationRef> {
    const session = sessionFor(id)
    if (session.busy || session.next !== session.pageCount) throw new Error('아직 모든 슬라이드를 변환하지 않았어요.')
    session.busy = true
    try {
      const pdf = await PDFDocument.create()
      pdf.registerFontkit(fontkit)
      pdf.setTitle(basename(session.relPath).replace(/\.pptx?$/i, ''))
      pdf.setProducer('Bandal')
      let font: Awaited<ReturnType<typeof pdf.embedFont>> | null = null
      for (let index = 0; index < session.pageCount; index++) {
        sessionFor(id)
        const data = JSON.parse(await readFile(join(session.folder, `${index}.json`), 'utf8')) as Pick<PresentationPdfPage, 'width' | 'height' | 'text'>
        const page = pdf.addPage([data.width, data.height])
        page.drawImage(await pdf.embedPng(await readFile(join(session.folder, `${index}.png`))), { x: 0, y: 0, width: data.width, height: data.height })
        for (const run of data.text) {
          if (!run.text.trim() || run.fontSize <= 0) continue
          font ??= await pdf.embedFont(await readFile(resolveDefaultFontPath('NotoSansKR-Regular.otf')), { subset: true })
          page.drawText(run.text.replace(/[\r\n\t]/g, ' '), { x: run.x, y: data.height - run.y - run.fontSize, size: run.fontSize, font, opacity: 0, rotate: degrees(-run.rotation) })
        }
        await new Promise<void>((resolve) => setImmediate(resolve))
      }
      if (session.includeInk) await deps.exporter.annotateDocument(pdf, session)
      sessionFor(id)
      const output = join(session.folder, 'result.pdf')
      await writeFile(output, await pdf.save({ objectsPerTick: 30 }))
      sessionFor(id)
      const result = deps.materials.adoptFile({ courseId: session.courseId, dirRelPath: dirname(session.relPath) === '.' ? '' : dirname(session.relPath), fileName: basename(session.relPath).replace(/\.pptx?$/i, '.pdf'), sourcePath: output })
      deps.changed(session.courseId)
      return { courseId: session.courseId, relPath: result.relPath }
    } finally { sessions.delete(id); clearTimeout(session.timer); await rm(session.folder, { recursive: true, force: true }) }
  }
  return { runtime, prepare, start, append, finish, cancel }
}
