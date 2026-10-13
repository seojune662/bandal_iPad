import { useViewportBounds } from '../../lib/useViewportBounds'
/**
 * 페이지 진단.
 *
 * The OZ Report Viewer failure took a codebase archaeology session to reason
 * about because the app knew exactly what it had blocked and told nobody. This
 * is the artifact a student can paste into a message instead — and unlike
 * DevTools it needs no walkthrough over KakaoTalk.
 *
 * The environment line is the valuable half: it answers, in one row, every
 * question we previously had to answer by reading our own source. Is the PDF
 * viewer on? Did `window.open` come back null? What actually threw?
 */

import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { showToast } from '../../app/toast'
import { Icon } from '../../app/icons'
import {
  BROWSER_DIAGNOSTICS_EVENT,
  diagnosticsFor,
  diagnosticsReport,
  type DiagnosticEntry
} from './diagnosticsBridge'

const KIND_LABELS: Record<DiagnosticEntry['kind'], string> = {
  http: '서버 응답',
  error: '오류',
  rejection: '처리 안 된 오류',
  console: '콘솔',
  'open-null': '팝업 막힘',
  env: '환경',
  blocked: '차단됨'
}

export function BrowserDiagnosticsPanel({
  tabId,
  anchor,
  onClose
}: {
  tabId: string
  anchor: DOMRect
  onClose: () => void
}): JSX.Element {
  const [, bump] = useState(0)
  const ref = useRef<HTMLDivElement>(null)
  useViewportBounds(ref)

  useEffect(() => {
    const onUpdate = (): void => bump((n) => n + 1)
    const onPointerDown = (event: PointerEvent): void => {
      const target = event.target
      if (target instanceof Node && ref.current?.contains(target) === true) return
      onClose()
    }
    window.addEventListener(BROWSER_DIAGNOSTICS_EVENT, onUpdate)
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') onClose()
    }
    const onBlur = (): void => onClose()
    window.addEventListener('pointerdown', onPointerDown, true)
    window.addEventListener('keydown', onKey)
    window.addEventListener('blur', onBlur)
    return () => {
      window.removeEventListener(BROWSER_DIAGNOSTICS_EVENT, onUpdate)
      window.removeEventListener('pointerdown', onPointerDown, true)
      window.removeEventListener('keydown', onKey)
      window.removeEventListener('blur', onBlur)
    }
  }, [onClose])

  const diagnostics = diagnosticsFor(tabId)
  const entries = diagnostics?.entries ?? []

  return createPortal(
    <div
      ref={ref}
      className="browser-diagnostics"
      role="dialog"
      aria-label="페이지 진단"
      style={{
        top: anchor.bottom,
        right: Math.max(0, window.innerWidth - anchor.right)
      }}
    >
      <header className="browser-diagnostics__head">
        <h2>이 페이지 진단</h2>
        <button
          type="button"
          className="browser-diagnostics__close"
          aria-label="닫기"
          onClick={onClose}
        >
          <Icon name="x" />
        </button>
      </header>

      {entries.length === 0 ? (
        <p className="browser-diagnostics__empty">
          이 페이지에서 오류가 잡히지 않았어요. 새로고침하면 처음부터 다시
          기록해요.
        </p>
      ) : (
        <ul className="browser-diagnostics__list">
          {entries
            .slice()
            .reverse()
            .map((entry, index) => (
              <li key={index} className="browser-diagnostics__row">
                <span className="browser-diagnostics__kind">
                  {KIND_LABELS[entry.kind]}
                </span>
                <span className="browser-diagnostics__message">
                  {entry.message}
                </span>
              </li>
            ))}
        </ul>
      )}

      <footer className="browser-diagnostics__actions">
        <button
          type="button"
          className="browser-diagnostics__action"
          disabled={entries.length === 0}
          onClick={() => {
            void navigator.clipboard
              .writeText(diagnosticsReport(tabId))
              .then(() => showToast('진단 내용을 복사했어요.'))
              .catch(() => showToast('복사하지 못했어요.', 'danger'))
          }}
        >
          복사
        </button>
      </footer>
    </div>,
    document.body
  )
}
