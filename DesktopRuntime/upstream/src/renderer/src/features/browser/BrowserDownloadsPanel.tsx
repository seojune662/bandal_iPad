import { useViewportBounds } from '../../lib/useViewportBounds'
/**
 * The downloads list.
 *
 * There was none: a non-interactive count badge and a toast that disappeared
 * after 60 seconds. So a 300MB 강의 영상 started on tethering could not be
 * stopped — the only button was 닫기, which removed the row while the transfer
 * kept running invisibly, and quitting the app was the real cancel button.
 *
 * `dismiss` had zero callers before this: it was the leftover of a panel
 * nobody built.
 */

import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { invoke } from '../../lib/ipc'
import { showToast } from '../../app/toast'
import { Icon } from '../../app/icons'
import { BrowserIcon } from './browserIcons'
import { useDownloads, type BrowserDownload } from './downloadsStore'
import { convertPresentationToPdf } from '../file/pptx/presentationJobs'

function sizeLabel(bytes: number): string {
  if (bytes <= 0) return ''
  const mb = bytes / (1024 * 1024)
  return mb >= 1 ? `${mb.toFixed(1)}MB` : `${Math.round(bytes / 1024)}KB`
}

function progressLabel(download: BrowserDownload): string {
  const received = sizeLabel(download.receivedBytes)
  // A blob download reports totalBytes 0, so a percentage would read 0% while
  // it works. Show what actually arrived instead.
  if (download.totalBytes <= 0) return received
  const percent = Math.min(
    100,
    Math.round((download.receivedBytes / download.totalBytes) * 100)
  )
  return `${percent}% · ${received} / ${sizeLabel(download.totalBytes)}`
}

function stateLabel(download: BrowserDownload): string {
  switch (download.state) {
    case 'completed':
      return `${download.courseId ? '과목 자료' : '다운로드'} · ${download.relPath ?? '완료'}`
    case 'cancelled':
      return '취소했어요'
    case 'interrupted':
      return download.failureReason ?? '받지 못했어요'
    default:
      return download.paused === true
        ? `일시중지 · ${progressLabel(download)}`
        : progressLabel(download)
  }
}

export function BrowserDownloadsPanel({
  anchor,
  onClose
}: {
  anchor: DOMRect
  onClose: () => void
}): JSX.Element {
  const downloads = useDownloads((state) => state.downloads)
  const dismiss = useDownloads((state) => state.dismiss)
  const ref = useRef<HTMLDivElement>(null)
  useViewportBounds(ref)

  useEffect(() => {
    const onPointerDown = (event: PointerEvent): void => {
      const target = event.target
      if (target instanceof Node && ref.current?.contains(target) === true) return
      onClose()
    }
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') onClose()
    }
    const onBlur = (): void => onClose()
    window.addEventListener('pointerdown', onPointerDown, true)
    window.addEventListener('keydown', onKey)
    window.addEventListener('blur', onBlur)
    return () => {
      window.removeEventListener('pointerdown', onPointerDown, true)
      window.removeEventListener('keydown', onKey)
      window.removeEventListener('blur', onBlur)
    }
  }, [onClose])

  const control = (id: string, action: 'cancel' | 'pause' | 'resume'): void => {
    void invoke('browser:controlDownload', { id, action }).catch(() => {
      // The transfer finished between render and click; the row updates itself.
    })
  }

  const fileAction = (id: string, action: 'open' | 'reveal' | 'saveAs' | 'retry'): void => {
    void invoke('browser:downloadFile', { id, action }).catch(() => {
      showToast('파일을 처리하지 못했어요. 저장 위치를 확인해 주세요.', 'danger')
    })
  }

  return createPortal(
    <div
      ref={ref}
      className="browser-downloads"
      role="dialog"
      aria-label="다운로드"
      style={{
        top: anchor.bottom,
        right: Math.max(0, window.innerWidth - anchor.right)
      }}
    >
      {downloads.length === 0 ? (
        <p className="browser-downloads__empty">받은 파일이 없어요.</p>
      ) : (
        <ul className="browser-downloads__list">
          {downloads.map((download) => {
            const running = download.state === 'progressing'
            return (
              <li key={download.id} className="browser-downloads__row">
                <BrowserIcon name="download" />
                <span className="browser-downloads__text">
                  <span className="browser-downloads__name">
                    {download.fileName}
                  </span>
                  <span className="browser-downloads__meta">
                    {stateLabel(download)}
                  </span>
                </span>
                {running ? (
                  <span className="browser-downloads__actions">
                    <button
                      type="button"
                      className="browser-downloads__action"
                      aria-label={`${download.fileName} ${download.paused === true ? '계속 받기' : '일시중지'}`}
                      onClick={() => control(
                        download.id,
                        download.paused === true ? 'resume' : 'pause'
                      )}
                    >
                      {download.paused === true ? '계속' : '일시중지'}
                    </button>
                    <button
                      type="button"
                      className="browser-downloads__action"
                      aria-label={`${download.fileName} 받기 취소`}
                      onClick={() => control(download.id, 'cancel')}
                    >
                      취소
                    </button>
                  </span>
                ) : (
                  <>
                  {(download.state === 'completed' || download.recoverable) && (
                    <span className="browser-downloads__actions">
                      {download.state === 'completed' && <button type="button" className="browser-downloads__action" onClick={() => fileAction(download.id, 'open')}>열기</button>}
                      <button type="button" className="browser-downloads__action" onClick={() => fileAction(download.id, 'reveal')}>폴더 보기</button>
                      <button type="button" className="browser-downloads__action" onClick={() => fileAction(download.id, 'saveAs')}>다른 위치에 저장</button>
                      {download.recoverable && <button type="button" className="browser-downloads__action" onClick={() => fileAction(download.id, 'retry')}>다시 저장</button>}
                    </span>
                  )}
                  {download.state === 'completed' && download.courseId !== null && download.relPath !== null && /\.pptx?$/i.test(download.relPath) && <button type="button" className="browser-downloads__action" onClick={() => {
                    if (download.courseId === null || download.relPath === null) return
                    onClose(); void convertPresentationToPdf({ courseId: download.courseId, relPath: download.relPath })
                  }}>PDF로 변환</button>}
                  <button
                    type="button"
                    className="browser-downloads__action"
                    aria-label={`${download.fileName} 목록에서 지우기`}
                    onClick={() => dismiss(download.id)}
                  >
                    <Icon name="x" />
                  </button>
                  </>
                )}
              </li>
            )
          })}
        </ul>
      )}
    </div>,
    document.body
  )
}
