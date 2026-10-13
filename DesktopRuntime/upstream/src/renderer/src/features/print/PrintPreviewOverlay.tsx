/**
 * 인쇄 미리보기.
 *
 * The overlay is not a nicety — it is the insurance. Electron's print path has
 * a long history of "works the first time only" (electron#21195, #14705), and
 * on top of that a native print sheet is the one thing that cannot be tested
 * from CI. Even if 인쇄 fails outright, the student can still take the bytes:
 * PDF로 저장 and 자료로 저장 are the same bytes on screen, and for a 고지서
 * that is usually what they actually wanted.
 *
 * Rendered with the pdf.js viewer the app already ships for course materials,
 * from a data URL rather than a byte array — pdf.js detaches transferred
 * ArrayBuffers, which StrictMode's double mount then re-reads. (자료 PDF 는
 * bandal-media:// URL 스트리밍으로 옮겨갔지만, 인쇄 미리보기는 main 이 만든
 * 인메모리 바이트라 여전히 data URL 이 맞다.)
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Document, Page } from 'react-pdf'
import { invoke } from '../../lib/ipc'
import { showToast } from '../../app/toast'
import { Icon } from '../../app/icons'
import { useFocusTrap } from '../../components/useFocusTrap'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import { useCoursesStore } from '../../stores/coursesStore'
import '../pdf/pdfWorker'
import { usePrintStore } from './printStore'
import './print.css'

const PREVIEW_PAGE_WIDTH_PX = 520

function fileNameFor(title: string): string {
  const cleaned = title.replace(/[\\/:*?"<>|\x00-\x1f]/g, ' ').trim().slice(0, 60)
  return `${cleaned === '' ? '인쇄' : cleaned}.pdf`
}

export function PrintPreviewOverlay(): JSX.Element | null {
  const target = usePrintStore((state) => state.target)
  const phase = usePrintStore((state) => state.phase)
  const prefs = usePrintStore((state) => state.prefs)
  const title = usePrintStore((state) => state.title)
  const setPrefs = usePrintStore((state) => state.setPrefs)
  const close = usePrintStore((state) => state.close)
  const courseId = useCoursesStore((state) => state.selectedCourseId)
  const [pageCount, setPageCount] = useState(0)
  const [busy, setBusy] = useState(false)
  const dialogRef = useRef<HTMLDivElement>(null)

  const open = target !== null

  useFocusTrap(dialogRef, { active: open, onEscape: close })

  // Guests live in a fixed layer of their own and would otherwise eat every
  // click aimed at this dialog. Released unconditionally — a token left held
  // is a scar this codebase already carries once.
  useEffect(() => {
    if (!open) return undefined
    const release = acquirePointerPassthrough()
    return () => release()
  }, [open])

  const base64 = phase.status === 'ready' ? phase.base64 : null

  const print = useCallback(async () => {
    if (base64 === null) return
    setBusy(true)
    try {
      await invoke('print:pdf', { base64, jobName: fileNameFor(title) })
    } catch {
      showToast('인쇄하지 못했어요. PDF로 저장해 보세요.', 'danger')
    } finally {
      setBusy(false)
    }
  }, [base64, title])

  const savePdf = useCallback(async () => {
    if (base64 === null) return
    setBusy(true)
    try {
      const result = await invoke('print:savePdfAs', {
        base64,
        suggestedName: fileNameFor(title)
      })
      if (!result.canceled) showToast('PDF로 저장했어요.')
    } catch {
      showToast('저장하지 못했어요.', 'danger')
    } finally {
      setBusy(false)
    }
  }, [base64, title])

  const saveToMaterials = useCallback(async () => {
    if (base64 === null || courseId === null) return
    setBusy(true)
    try {
      const result = await invoke('materials:writeFile', {
        courseId,
        dirRelPath: '',
        fileName: fileNameFor(title),
        data: base64,
        encoding: 'base64'
      })
      showToast(`«${result.relPath}»에 저장했어요.`)
    } catch {
      showToast('자료로 저장하지 못했어요.', 'danger')
    } finally {
      setBusy(false)
    }
  }, [base64, courseId, title])

  if (!open) return null

  return createPortal(
    <div
      ref={dialogRef}
      className="print-preview-backdrop"
      role="dialog"
      aria-modal="true"
      aria-label="인쇄 미리보기"
      onPointerDown={(event) => {
        if (event.target === event.currentTarget) close()
      }}
    >
      <div className="print-preview">
        <header className="print-preview__head">
          <h2 className="print-preview__title">인쇄 미리보기</h2>
          <button
            type="button"
            className="print-preview__close"
            aria-label="닫기"
            onClick={close}
          >
            <Icon name="x" />
          </button>
        </header>

        <div className="print-preview__options">
          <label>
            용지
            <select
              value={prefs.pageSize}
              onChange={(event) =>
                setPrefs({ pageSize: event.target.value === 'Letter' ? 'Letter' : 'A4' })
              }
            >
              <option value="A4">A4</option>
              <option value="Letter">Letter</option>
            </select>
          </label>
          <label>
            방향
            <select
              value={prefs.landscape ? 'landscape' : 'portrait'}
              onChange={(event) =>
                setPrefs({ landscape: event.target.value === 'landscape' })
              }
            >
              <option value="portrait">세로</option>
              <option value="landscape">가로</option>
            </select>
          </label>
          <label className="print-preview__toggle">
            <input
              type="checkbox"
              checked={prefs.printBackground}
              onChange={(event) => setPrefs({ printBackground: event.target.checked })}
            />
            배경 그래픽
          </label>
        </div>

        <div className="print-preview__body">
          {phase.status === 'rendering' && (
            <p className="print-preview__status" role="status">
              미리보기를 만드는 중…
            </p>
          )}
          {phase.status === 'error' && (
            <p className="print-preview__status">{phase.message}</p>
          )}
          {base64 !== null && (
            <Document
              file={`data:application/pdf;base64,${base64}`}
              onLoadSuccess={(pdf) => setPageCount(pdf.numPages)}
              loading={
                <p className="print-preview__status" role="status">
                  불러오는 중…
                </p>
              }
              error={
                <p className="print-preview__status">
                  미리보기를 열지 못했어요.
                </p>
              }
            >
              {Array.from({ length: pageCount }, (_unused, index) => (
                <Page
                  key={index}
                  pageNumber={index + 1}
                  width={PREVIEW_PAGE_WIDTH_PX}
                  renderTextLayer={false}
                  renderAnnotationLayer={false}
                  className="print-preview__page"
                />
              ))}
            </Document>
          )}
        </div>

        <footer className="print-preview__actions">
          <button
            type="button"
            className="button button--primary"
            disabled={base64 === null || busy}
            onClick={() => void print()}
          >
            인쇄
          </button>
          <button
            type="button"
            className="button"
            disabled={base64 === null || busy}
            onClick={() => void savePdf()}
          >
            PDF로 저장
          </button>
          <button
            type="button"
            className="button"
            disabled={base64 === null || busy || courseId === null}
            onClick={() => void saveToMaterials()}
          >
            자료로 저장
          </button>
        </footer>
      </div>
    </div>,
    document.body
  )
}
