import { useId, useRef, type ReactNode } from 'react'
import { useFocusTrap } from '../../components/useFocusTrap'

export function MarketIcon(): JSX.Element {
  return <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true"><path d="M5 9h14l1 12H4L5 9Z" strokeLinejoin="round"/><path d="M8 9V7a4 4 0 0 1 8 0v2" strokeLinecap="round"/></svg>
}

export function MarketDialog({ title, onClose, busy = false, children, wide = false }: {
  title: string
  onClose: () => void
  busy?: boolean
  children: ReactNode
  wide?: boolean
}): JSX.Element {
  const ref = useRef<HTMLElement>(null)
  const titleId = useId()
  useFocusTrap(ref, { active: true, onEscape: busy ? undefined : onClose })
  return <div className="study-market__backdrop" onMouseDown={event => { if (!busy && event.target === event.currentTarget) onClose() }}>
    <section ref={ref} role="dialog" aria-modal="true" aria-labelledby={titleId} className={`study-market__dialog${wide ? ' study-market__dialog--wide' : ''}`}>
      <header className="study-market__dialog-header"><h2 id={titleId}>{title}</h2><button className="study-market__close" type="button" aria-label="닫기" disabled={busy} onClick={onClose}>×</button></header>
      {children}
    </section>
  </div>
}

export function MarketEmpty({ title, children, action }: { title: string; children?: ReactNode; action?: ReactNode }): JSX.Element {
  return <div className="study-market__empty"><span className="study-market__empty-icon"><MarketIcon /></span><h3>{title}</h3>{children && <p>{children}</p>}{action}</div>
}

export function MarketError({ message, retry }: { message: string | null; retry?: () => void }): JSX.Element | null {
  if (!message) return null
  return <div className="study-market__error" role="alert"><span>{message}</span>{retry && <button type="button" onClick={retry}>다시 시도</button>}</div>
}

export function Field({ label, children, hint }: { label: string; children: ReactNode; hint?: string }): JSX.Element {
  return <label className="study-market__field"><span>{label}</span>{children}{hint && <small>{hint}</small>}</label>
}
