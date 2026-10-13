import { create } from 'zustand'
import type { PptxPresentation, PptxTextRunInfo } from '@silurus/ooxml/pptx'
import type { PresentationRef } from '../../../../../shared/types/presentation'
import { invoke } from '../../../lib/ipc'
import { showToast, showToastWithAction } from '../../../app/toast'
import { openMaterialInCourse } from '../../workspace/openMaterial'
import './presentation.css'

export const PPTX_LIMITS = { maxArchiveEntries: 8_192, maxArchiveEntryBytes: 128 * 1024 * 1024, maxTotalInflatedBytes: 384 * 1024 * 1024 }
export function decodePresentation(base64: string): ArrayBuffer {
  const binary = atob(base64), bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes.buffer
}
export async function loadSlidePresentation(input: string | ArrayBuffer): Promise<PptxPresentation> {
  const { PptxPresentation } = await import('@silurus/ooxml/pptx')
  return PptxPresentation.load(typeof input === 'string' ? decodePresentation(input) : input, { mode: 'worker', progressiveLayout: true, useGoogleFonts: false, resourceLimits: PPTX_LIMITS })
}
export function slidePageSize(presentation: Pick<PptxPresentation, 'slideWidth' | 'slideHeight'>): { width: number; height: number } {
  // OOXML dimensions are EMUs: 914,400 per inch, 12,700 per PDF point.
  return { width: presentation.slideWidth / 12_700, height: presentation.slideHeight / 12_700 }
}
export function pdfTextRun(run: PptxTextRunInfo, scale: number) {
  return { text: run.text, x: (run.shapeX + run.inShapeX) * scale, y: (run.shapeY + run.inShapeY) * scale, width: run.w * scale, height: run.h * scale, fontSize: run.fontSize * scale, rotation: run.rotation }
}

interface Job { label: string; progress: number; total: number; cancel: () => void }
const usePresentationJob = create<{ job: Job | null }>(() => ({ job: null }))

export function PresentationProgress(): JSX.Element | null {
  const job = usePresentationJob((state) => state.job)
  return job ? <aside className="presentation-progress" role="status"><strong>{job.label}</strong>{job.total > 0 && <><progress value={job.progress} max={job.total} /><span>{job.progress} / {job.total}</span></>}<button type="button" onClick={job.cancel}>취소</button></aside> : null
}

export async function ensurePresentationRuntime(): Promise<boolean> {
  const runtime = await invoke('presentation:runtime', {})
  if (runtime.status === 'ready') return true
  if (runtime.status === 'unsupported') throw new Error('이 운영체제에서는 구형 PPT를 아직 열 수 없어요.')
  if (!window.confirm('구형 PPT를 열기 위한 변환기를 내려받을까요?\n\n약 300~450MB를 한 번 내려받고, 이후에는 인터넷 없이 사용할 수 있어요. 강의자료는 이 기기 안에서만 변환됩니다.')) return false
  await invoke('presentation:installRuntime', {})
  return true
}

/** Works from a viewer, a material menu, or a completed browser download. */
export async function convertPresentationToPdf(ref: PresentationRef, presentation?: PptxPresentation, includeInk = false): Promise<void> {
  if (usePresentationJob.getState().job) { showToast('진행 중인 PDF 변환이 끝난 후 다시 시도해 주세요.'); return }
  const abort = new AbortController(), requestId = crypto.randomUUID()
  let sessionId: string | null = null, owned: PptxPresentation | null = null
  const cancel = (): void => {
    abort.abort()
    void invoke('presentation:cancelPrepare', { requestId })
    void invoke('presentation:cancelRuntime', {})
    if (sessionId) void invoke('presentation:pdfCancel', { sessionId })
  }
  const update = (label: string, progress = 0, total = 0): void => usePresentationJob.setState({ job: { label, progress, total, cancel } })
  const check = (): void => { if (abort.signal.aborted) throw new Error('PDF 변환을 취소했어요.') }
  update('PDF 변환 준비 중…')
  try {
    if (!presentation) {
      if (/\.ppt$/i.test(ref.relPath)) {
        update('구형 PPT 변환기 준비 중…')
        if (!await ensurePresentationRuntime()) return
      }
      check()
      const file = await invoke('presentation:prepare', { ...ref, requestId })
      if (file.encoding !== 'base64') throw new Error('프레젠테이션을 읽지 못했어요.')
      owned = await loadSlidePresentation(file.data)
      presentation = owned
    }
    await presentation.waitUntilLayoutComplete()
    check()
    const count = presentation.slideCount, size = slidePageSize(presentation)
    sessionId = (await invoke('presentation:pdfStart', { ...ref, pageCount: count, includeInk })).sessionId
    const pixelWidth = Math.min(2400, Math.max(1200, size.width * 2))
    for (let index = 0; index < count; index++) {
      check(); update('PDF로 변환하는 중', index + 1, count)
      const canvas = document.createElement('canvas')
      const runs: PptxTextRunInfo[] = []
      const bitmap = await presentation.renderSlideToBitmap(index, { width: pixelWidth, dpr: 1, onTextRun: (run) => runs.push(run) })
      try {
        check()
        canvas.width = bitmap.width; canvas.height = bitmap.height
        canvas.getContext('2d')?.drawImage(bitmap, 0, 0)
      } finally { bitmap.close() }
      check()
      const pngBase64 = canvas.toDataURL('image/png').split(',')[1] ?? ''
      await invoke('presentation:pdfPage', { sessionId, index, ...size, pngBase64, text: runs.map((run) => pdfTextRun(run, size.width / pixelWidth)) })
      canvas.width = 0; canvas.height = 0
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()))
    }
    check(); update('PDF를 저장하는 중…')
    const result = await invoke('presentation:pdfFinish', { sessionId })
    sessionId = null
    showToastWithAction('PDF 사본을 저장했어요.', { label: 'PDF 열기', run: () => openMaterialInCourse(result.courseId, 'pdf', result.relPath) })
  } catch (cause) {
    if (sessionId) await invoke('presentation:pdfCancel', { sessionId }).catch(() => {})
    showToast(cause instanceof Error ? cause.message : 'PDF 변환을 완료하지 못했어요.', abort.signal.aborted ? 'info' : 'danger')
  } finally { owned?.destroy(); usePresentationJob.setState({ job: null }) }
}
