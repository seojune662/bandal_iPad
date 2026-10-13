import { useCallback, useEffect, useId, useRef, useState, type KeyboardEvent, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import type { IDockviewHeaderActionsProps, IDockviewPanel } from 'dockview'
import { Icon } from '../../app/icons'
import { useLocale } from '../../i18n'
import { useViewportBounds } from '../../lib/useViewportBounds'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { isTabDescriptor } from './tabIdentity'
import { WorkspaceTabIcon } from './workspaceIcons'
import { focusWorkspaceHeader, layoutAdaptiveTabs } from './adaptiveTabs'
import { useCourseActive } from './courseActivity'
import './adaptive-tabs.css'

interface OpenTabsActionProps extends IDockviewHeaderActionsProps {
  menuActions?: (close: () => void) => ReactNode
}

function OpenTabsMenu({ panels, activeId, anchor, trigger, close, select, menuActions, focusAfterHeaderReplacement }: {
  panels: readonly IDockviewPanel[]
  activeId: string | undefined
  anchor: DOMRect
  trigger: HTMLButtonElement | null
  close: () => void
  select: (panel: IDockviewPanel) => void
  menuActions: OpenTabsActionProps['menuActions']
  focusAfterHeaderReplacement: () => void
}): JSX.Element {
  const ko = useLocale() === 'ko-KR'
  const [query, setQuery] = useState('')
  const [closing, setClosing] = useState<string | null>(null)
  const menu = useRef<HTMLDivElement>(null)
  const search = useRef<HTMLInputElement>(null)
  const headingId = useId()
  useViewportBounds(menu)
  const filtered = panels.filter(panel => (panel.title ?? '').toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()))
  useEffect(() => {
    search.current?.focus()
    const outside = (event: PointerEvent): void => {
      if (event.target instanceof Node && !menu.current?.contains(event.target) && !trigger?.contains(event.target)) close()
    }
    document.addEventListener('pointerdown', outside)
    return () => document.removeEventListener('pointerdown', outside)
  }, [close, trigger])
  const choices = (): HTMLButtonElement[] => [...(menu.current?.querySelectorAll<HTMLButtonElement>('.workspace-open-tabs-menu__select') ?? [])]
  const onKeyDown = (event: KeyboardEvent): void => {
    if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); close(); return }
    if (event.target instanceof Element && event.target.closest('.workspace-open-tabs-menu__actions')) return
    const buttons = choices()
    const current = event.target instanceof Element ? event.target.closest('li')?.querySelector<HTMLButtonElement>('.workspace-open-tabs-menu__select') : null
    const index = current ? buttons.indexOf(current) : -1
    let next: number | undefined
    if (event.key === 'ArrowDown') next = (index + 1) % buttons.length
    if (event.key === 'ArrowUp') next = index <= 0 ? buttons.length - 1 : index - 1
    if (event.target !== search.current && event.key === 'Home') next = 0
    if (event.target !== search.current && event.key === 'End') next = buttons.length - 1
    if (event.target === search.current && event.key === 'Enter' && filtered[0]) { event.preventDefault(); select(filtered[0]); return }
    const target = next === undefined ? undefined : buttons[next]
    if (target) { event.preventDefault(); target.focus(); target.scrollIntoView({ block: 'nearest' }) }
  }
  const closePanel = async (panel: IDockviewPanel): Promise<void> => {
    if (closing) return
    const index = filtered.findIndex(candidate => candidate.id === panel.id)
    setClosing(panel.id)
    try { await useWorkspaceStore.getState().closeTab(panel.id) }
    finally { setClosing(null) }
    requestAnimationFrame(() => {
      const buttons = choices()
      const next = buttons[Math.min(index, buttons.length - 1)] ?? search.current
      if (next) next.focus()
      else if (trigger && !trigger.isConnected && document.activeElement === document.body) focusAfterHeaderReplacement()
    })
  }
  return createPortal(<div ref={menu} className="workspace-open-tabs-menu" role="dialog" aria-labelledby={headingId}
    style={{ left: Math.max(8, anchor.right - 320), top: anchor.bottom + 4 }} onKeyDown={onKeyDown}>
    <div className="workspace-open-tabs-menu__heading"><strong id={headingId}>{ko ? `열린 탭 ${panels.length}개` : `${panels.length} open tabs`}</strong>
      <button type="button" className="workspace-open-tabs-menu__close" aria-label={ko ? '탭 목록 닫기' : 'Close tab list'} onClick={close}><Icon name="x" /></button></div>
    <input ref={search} type="search" className="workspace-open-tabs-menu__search" aria-label={ko ? '열린 탭 검색' : 'Search open tabs'} placeholder={ko ? '열린 탭 검색' : 'Search open tabs'} value={query} onChange={event => setQuery(event.target.value)} />
    <ul className="workspace-open-tabs-menu__list" aria-label={ko ? '이 분할의 열린 탭' : 'Tabs in this pane'}>
      {filtered.map(panel => {
        const descriptor: unknown = panel.params?.descriptor
        return <li key={panel.id} className="workspace-open-tabs-menu__row" data-selected={panel.id === activeId || undefined}>
          <button type="button" className="workspace-open-tabs-menu__select" aria-current={panel.id === activeId ? 'page' : undefined} onClick={() => select(panel)}>
            {isTabDescriptor(descriptor) && <WorkspaceTabIcon descriptor={descriptor} />}<span>{panel.title}</span>
          </button>
          <button type="button" className="workspace-open-tabs-menu__close" aria-label={ko ? `${panel.title} 탭 닫기` : `Close ${panel.title}`} disabled={closing !== null} onClick={() => void closePanel(panel)}><Icon name="x" /></button>
        </li>
      })}
    </ul>
    {!filtered.length && <p className="workspace-open-tabs-menu__empty" role="status">{ko ? '일치하는 탭이 없어요.' : 'No matching tabs.'}</p>}
    {menuActions && <div className="workspace-open-tabs-menu__actions" aria-label={ko ? '작업 영역 동작' : 'Pane actions'}>{menuActions(close)}</div>}
  </div>, document.body)
}

/** Header action receives the exact group; opening its list never steals another pane. */
export function OpenTabsAction(props: OpenTabsActionProps): JSX.Element {
  const ko = useLocale() === 'ko-KR'
  const courseActive = useCourseActive()
  const [anchor, setAnchor] = useState<DOMRect | null>(null)
  const [, refresh] = useState(0)
  const button = useRef<HTMLButtonElement>(null)
  const panels = props.group.panels
  useEffect(() => {
    const subscriptions = panels.map(panel => panel.api.onDidTitleChange(() => refresh(value => value + 1)))
    return () => subscriptions.forEach(subscription => subscription.dispose())
  }, [panels])
  useEffect(() => {
    const subscription = props.containerApi.onDidLayoutChange(() => refresh(value => value + 1))
    return () => subscription.dispose()
  }, [props.containerApi])
  useEffect(() => { if (!courseActive) setAnchor(null) }, [courseActive])
  const close = useCallback(() => { setAnchor(null); button.current?.focus() }, [])
  return <>
    <button ref={button} type="button" className="workspace-open-tabs-button" aria-label={ko ? `열린 탭 ${panels.length}개 목록` : `List ${panels.length} open tabs`}
      aria-haspopup="dialog" aria-expanded={anchor !== null} onClick={() => setAnchor(current => current ? null : button.current!.getBoundingClientRect())}>
      <Icon name="chevronRight" style={{ transform: 'rotate(90deg)' }} /><span aria-hidden="true">{panels.length}</span>
    </button>
    {anchor && courseActive && <OpenTabsMenu panels={panels} activeId={props.group.activePanel?.id} anchor={anchor} trigger={button.current} close={close} menuActions={props.menuActions}
      focusAfterHeaderReplacement={() => focusWorkspaceHeader(props.containerApi.groups.find(group => group.id === props.group.id)?.element)} select={panel => {
      panel.api.setActive()
      layoutAdaptiveTabs(props.group.element)
      setAnchor(null)
      props.group.element.querySelector<HTMLElement>('.dv-tab.dv-active-tab')?.focus()
    }} />}
  </>
}
