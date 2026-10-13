import { useEffect, useId, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Icon } from '../../app/icons'
import { useFocusTrap } from '../../components/useFocusTrap'
import { useViewportBounds } from '../../lib/useViewportBounds'
import { BrowserIcon } from './browserIcons'
import { acquirePointerPassthrough } from './webviewPassthrough'
import './browserLoginPrompt.css'

/** A pending save lives in the toolbar; only an explicit click opens the card. */
export function BrowserLoginPrompt({
  kind, origin, username, pending = false, onSave, onDecline, onSuppress
}: {
  kind: 'save' | 'update'
  origin: string
  username: string
  pending?: boolean
  onSave: () => void
  onDecline: () => void
  onSuppress: () => void
}): JSX.Element {
  const [anchor, setAnchor] = useState<DOMRect | null>(null)
  const dialogRef = useRef<HTMLDivElement>(null)
  const titleId = useId()
  const descriptionId = useId()
  const title = kind === 'update' ? '비밀번호 업데이트' : '비밀번호 저장'
  let site = origin
  try { site = new URL(origin).hostname } catch { /* Keep the known origin. */ }
  const close = (): void => setAnchor(null)
  useFocusTrap(dialogRef, { active: anchor !== null, onEscape: close })
  useViewportBounds(dialogRef)
  useEffect(() => {
    if (anchor === null) return
    const release = acquirePointerPassthrough()
    // The anchor is a snapshot. Close on window geometry changes instead of
    // leaving a detached card over a different tab or split pane.
    window.addEventListener('resize', close)
    window.addEventListener('blur', close)
    return () => {
      release()
      window.removeEventListener('resize', close)
      window.removeEventListener('blur', close)
    }
  }, [anchor])

  return <>
    <button
      type="button"
      className="browser-password-trigger"
      aria-label={`${title} 확인`}
      aria-haspopup="dialog"
      aria-expanded={anchor !== null}
      title={`${site} · ${title}`}
      onClick={event => setAnchor(anchor === null ? event.currentTarget.getBoundingClientRect() : null)}
    >
      <BrowserIcon name="key" />
      <span>{kind === 'update' ? '업데이트' : '저장'}</span>
    </button>
    <span className="browser-password-announcement" role="status">{site} 로그인 정보를 저장할 수 있습니다.</span>
    {anchor !== null && createPortal(
      <div className="browser-password-backdrop" onMouseDown={event => {
        if (event.target === event.currentTarget) close()
      }}>
        <div
          ref={dialogRef}
          className="browser-password-card"
          role="dialog"
          aria-modal="true"
          aria-labelledby={titleId}
          aria-describedby={descriptionId}
          aria-busy={pending}
          style={{ top: anchor.bottom + 8, right: Math.max(12, window.innerWidth - anchor.right) }}
        >
          <header className="browser-password-card__header">
            <span className="browser-password-card__icon" aria-hidden="true"><BrowserIcon name="key" /></span>
            <h2 id={titleId}>{title}</h2>
            <button type="button" className="browser-password-card__close" aria-label="비밀번호 안내 닫기" onClick={close}><Icon name="x" /></button>
          </header>
          <p id={descriptionId} className="browser-password-card__description">
            {kind === 'update' ? '이 계정에 저장된 비밀번호를 새로 입력한 비밀번호로 바꿉니다.' : '다음 로그인에 사용할 수 있도록 이 기기에 저장합니다.'}
          </p>
          <div className="browser-password-card__account">
            <strong>{site}</strong>
            <span>{username || '아이디 없음'}</span>
          </div>
          <div className="browser-password-card__actions">
            <button type="button" disabled={pending} onClick={onDecline}>이번엔 안 함</button>
            <button type="button" className="browser-password-card__primary" disabled={pending} onClick={onSave}>
              {pending ? '저장 중…' : kind === 'update' ? '업데이트' : '저장'}
            </button>
          </div>
          <footer className="browser-password-card__footer">
            <button type="button" disabled={pending} onClick={onSuppress}>이 사이트는 묻지 않기</button>
          </footer>
        </div>
      </div>, document.body
    )}
  </>
}
