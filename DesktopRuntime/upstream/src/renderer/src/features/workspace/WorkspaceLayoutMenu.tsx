import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { IDockviewHeaderActionsProps } from 'dockview'
import { Tooltip } from '../../components/Tooltip'
import { useLocale } from '../../i18n'
import { useViewportBounds } from '../../lib/useViewportBounds'
import { applyWorkspaceLayout, splitWorkspaceGroup, removeEmptyWorkspaceGroup, type WorkspaceLayoutPreset } from './workspaceLayout'

export function WorkspaceLayoutMenu({ containerApi, group }: IDockviewHeaderActionsProps): JSX.Element {
  const ko = useLocale() === 'ko-KR'
  const button = useRef<HTMLButtonElement>(null)
  const menu = useRef<HTMLDivElement>(null)
  const [anchor, setAnchor] = useState<{ x: number; y: number } | null>(null)
  useViewportBounds(menu)
  useEffect(() => {
    if (!anchor) return
    menu.current?.querySelector<HTMLButtonElement>('button')?.focus()
    const close = (event: PointerEvent): void => {
      if (!menu.current?.contains(event.target as Node) && !button.current?.contains(event.target as Node)) setAnchor(null)
    }
    const blur = (): void => setAnchor(null)
    window.addEventListener('pointerdown', close)
    window.addEventListener('blur', blur)
    return () => { window.removeEventListener('pointerdown', close); window.removeEventListener('blur', blur) }
  }, [anchor])
  const run = (action: () => void): void => {
    setAnchor(null)
    action()
    requestAnimationFrame(() => {
      if (button.current?.isConnected) button.current.focus()
      else containerApi.activeGroup?.element.querySelector<HTMLElement>('.dv-active-tab, .workspace-open-tabs-button')?.focus()
    })
  }
  const layouts: [WorkspaceLayoutPreset, string][] = [
    ['single', ko ? '단일 영역' : 'Single pane'],
    ['columns', ko ? '좌우 2분할' : 'Two columns'],
    ['rows', ko ? '상하 2분할' : 'Two rows'],
    ['grid', ko ? '2×2 4분할' : 'Four panes (2×2)']
  ]
  return <>
    <Tooltip label={ko ? '작업 공간 배치' : 'Workspace layout'} placement="bottom">
      <button ref={button} type="button" className="titlebar-button" aria-label={ko ? '작업 공간 배치' : 'Workspace layout'} aria-haspopup="menu" aria-expanded={!!anchor}
        onClick={() => {
          if (anchor) { setAnchor(null); return }
          const rect = button.current!.getBoundingClientRect()
          setAnchor({ x: rect.left, y: rect.bottom + 4 })
        }}><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden="true"><rect x="3" y="3" width="18" height="18" rx="2" /><path d="M12 3v18M3 12h18" /></svg></button>
    </Tooltip>
    {anchor && createPortal(<div ref={menu} className="context-menu workspace-layout-menu" role="menu" aria-label={ko ? '작업 공간 배치' : 'Workspace layout'} style={{ left: anchor.x, top: anchor.y }}
      onKeyDown={event => {
        if (event.key === 'Escape') { event.preventDefault(); run(() => undefined); return }
        const items = [...menu.current!.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')]
        const current = items.indexOf(document.activeElement as HTMLButtonElement)
        let next: number | undefined
        if (event.key === 'ArrowDown' || (event.key === 'Tab' && !event.shiftKey)) next = (current + 1) % items.length
        if (event.key === 'ArrowUp' || (event.key === 'Tab' && event.shiftKey)) next = (current + items.length - 1) % items.length
        if (event.key === 'Home') next = 0
        if (event.key === 'End') next = items.length - 1
        if (next !== undefined) { event.preventDefault(); items[next]?.focus() }
      }}>
      {layouts.map(([preset, label]) => <button key={preset} type="button" role="menuitem" onClick={() => run(() => applyWorkspaceLayout(containerApi, preset))}>{label}</button>)}
      <span className="context-menu__separator" role="separator" />
      <button type="button" role="menuitem" onClick={() => run(() => splitWorkspaceGroup(containerApi, group.id, 'right'))}>{ko ? '이 영역을 좌우로 나누기' : 'Split this pane right'}</button>
      <button type="button" role="menuitem" onClick={() => run(() => splitWorkspaceGroup(containerApi, group.id, 'below'))}>{ko ? '이 영역을 상하로 나누기' : 'Split this pane down'}</button>
      {group.panels.length === 0 && containerApi.groups.length > 1 && <button type="button" role="menuitem" onClick={() => run(() => { removeEmptyWorkspaceGroup(containerApi, group.id) })}>{ko ? '빈 영역 닫기' : 'Close empty pane'}</button>}
    </div>, document.body)}
  </>
}
