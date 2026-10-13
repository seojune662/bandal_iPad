import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Tooltip } from '../../components/Tooltip'
import { Icon } from '../../app/icons'
import { useLocale } from '../../i18n'
import { useViewportBounds } from '../../lib/useViewportBounds'
import { useUiStore } from '../../stores/uiStore'
import { useUpdateStore } from '../../stores/updateStore'
import './rail-update.css'

export function RailUpdateButton(): JSX.Element | null {
  const ko = useLocale() === 'ko-KR'
  const { status, knownVersion, pendingAction, actionError, init, download, install, check } = useUpdateStore()
  const buttonRef = useRef<HTMLButtonElement>(null)
  const dialogRef = useRef<HTMLDivElement>(null)
  const [errorOpen, setErrorOpen] = useState(false)
  useViewportBounds(dialogRef)
  useEffect(() => { init() }, [init])

  const version = status && 'version' in status ? status.version : knownVersion
  const visible = !!status && !!version && !['unsupported', 'idle', 'checking'].includes(status.phase)
  const error = actionError ?? (status?.phase === 'error' ? status.message : null)
  const busy = pendingAction === 'download' || pendingAction === 'install' || status?.phase === 'downloading'
  const downloading = pendingAction === 'download' || status?.phase === 'downloading'
  const percent = status?.phase === 'downloading' ? Math.min(100, Math.max(0, Math.round(status.percent))) : 0
  const ready = status?.phase === 'ready'
  const label = pendingAction === 'install'
    ? ko ? '업데이트 적용을 준비하는 중' : 'Preparing to restart and update'
    : downloading ? ko ? `업데이트 다운로드 중 ${percent}%` : `Downloading update ${percent}%`
      : error ? ko ? '업데이트 오류 확인' : 'Review update error'
        : ready ? ko ? '업데이트 적용하고 다시 시작' : 'Restart and apply update'
          : ko ? `새 버전 ${version} 다운로드` : `Download version ${version}`
  const tooltip = ready && !error && pendingAction !== 'install'
    ? ko ? `${version} 적용을 위해 필기 저장 후 다시 시작합니다` : `Save notes and restart to apply ${version}`
    : error && !busy ? `${label} — ${error}` : label

  useEffect(() => {
    if (!errorOpen || !visible || !error) { if (errorOpen) setErrorOpen(false); return }
    const outside = (event: PointerEvent): void => {
      if (!(event.target instanceof Node) || dialogRef.current?.contains(event.target) || buttonRef.current?.contains(event.target)) return
      setErrorOpen(false)
    }
    const key = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') { event.preventDefault(); setErrorOpen(false); buttonRef.current?.focus() }
      if (event.key !== 'Tab') return
      const buttons = [...(dialogRef.current?.querySelectorAll<HTMLButtonElement>('button') ?? [])]
      const first = buttons[0], last = buttons.at(-1)
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus() }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus() }
    }
    document.addEventListener('pointerdown', outside, true)
    document.addEventListener('keydown', key)
    dialogRef.current?.querySelector<HTMLButtonElement>('button')?.focus()
    return () => { document.removeEventListener('pointerdown', outside, true); document.removeEventListener('keydown', key) }
  }, [errorOpen, visible, error])

  if (!visible) return null
  const bounds = buttonRef.current?.getBoundingClientRect()
  const retry = (): void => { setErrorOpen(false); void (ready ? install() : knownVersion ? download() : check()) }
  return <>
    <Tooltip label={tooltip} placement="right">
      <button ref={buttonRef} type="button" className="rail-nav__item rail-update-button"
        aria-label={label} aria-busy={busy || undefined} disabled={busy}
        aria-haspopup={error && !busy ? 'dialog' : undefined} aria-expanded={error && !busy ? errorOpen : undefined}
        data-update-phase={pendingAction === 'install' ? 'installing' : downloading ? 'downloading' : error ? 'error' : status!.phase}
        onClick={() => { if (error) setErrorOpen(open => !open); else void (ready ? install() : download()) }}>
        {ready || error ? <Icon name="refresh" /> : <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M12 4v11m-4-4 4 4 4-4M5 17v3h14v-3" /></svg>}
        {downloading && <svg className="rail-update-button__progress" viewBox="0 0 36 36" aria-hidden="true"><circle className="rail-update-button__track" cx="18" cy="18" r="16" /><circle cx="18" cy="18" r="16" pathLength="100" strokeDasharray={`${percent} 100`} /></svg>}
        {error && !busy && <span className="rail-update-button__error" aria-hidden="true">!</span>}
      </button>
    </Tooltip>
    {errorOpen && error && createPortal(<div ref={dialogRef} className="rail-update-dialog" role="dialog" aria-modal="true"
      aria-label={ko ? '업데이트 오류' : 'Update error'} style={{ left: (bounds?.right ?? 44) + 8, top: Math.max(8, (bounds?.top ?? 100) - 130) }}>
      <strong>{ko ? '업데이트를 완료하지 못했어요' : 'The update could not finish'}</strong>
      <p>{error}</p>
      <div className="rail-update-dialog__actions">
        <button type="button" className="primary-button" onClick={retry}>{ko ? '다시 시도' : 'Retry'}</button>
        <button type="button" className="secondary-button" onClick={() => { setErrorOpen(false); useUiStore.getState().openSettings('about') }}>{ko ? '설정에서 확인' : 'Open update settings'}</button>
        <button type="button" className="rail-update-dialog__close" onClick={() => { setErrorOpen(false); buttonRef.current?.focus() }}>{ko ? '닫기' : 'Close'}</button>
      </div>
    </div>, document.body)}
  </>
}
