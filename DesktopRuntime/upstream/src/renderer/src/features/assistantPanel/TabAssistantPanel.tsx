import { lazy, Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type FunctionComponent } from 'react'
import type { IDockviewPanelProps } from 'dockview'
import { isTabDescriptor, tabTitle, descriptorFor } from '../workspace/tabIdentity'
import { useCoursesStore } from '../../stores/coursesStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { usePanelActive } from '../workspace/usePanelActive'
import { useWorkspacePlacement } from '../workspace/placementContext'
import { PanelAssistantContext, normalizeAssistantPanel, type AssistantPanelState } from './panelContext'
import { updateComposerDraft } from '../chat/composerDraftStore'
import { Icon } from '../../app/icons'
import { registerDocumentContext } from '../agent/documentContext'
import { useBrowserGuests } from '../browser/browserGuestsStore'
import { ConversationListMenu } from '../chat/ConversationListMenu'
import { Tooltip } from '../../components/Tooltip'
import './assistant-panel.css'
import { registerAssistantController } from './assistantController'
import { AssistantPanelToggle } from './AssistantPanelToggle'
const ChatSurface = lazy(() => import('../chat/ChatSurface').then(m => ({ default: m.ChatSurface })))
export function withAssistantPanel(Component: FunctionComponent<IDockviewPanelProps>): FunctionComponent<IDockviewPanelProps> {
  return function AssistantPanel(props) {
    const descriptor = isTabDescriptor(props.params.descriptor) ? props.params.descriptor : null
    const [panelTitle, setPanelTitle] = useState(props.api.title ?? '')
    useEffect(() => {
      const subscription = props.api.onDidTitleChange?.(event => setPanelTitle(event.title))
      return () => subscription?.dispose()
    }, [props.api])
    const selectedCourseId = useCoursesStore(s => s.selectedCourseId)
    const placement = useWorkspacePlacement()
    const active = usePanelActive(props.api)
    const [state, setState] = useState(() => normalizeAssistantPanel(props.params.assistant))
    const [ownerCourseId] = useState(() => state.courseId ?? (placement ? placement.courseId : selectedCourseId))
    const workspaceCourseId = placement ? placement.courseId : useWorkspaceStore.getState().activeCourseId
    const resourceCourseId = descriptor && 'courseId' in descriptor.payload ? descriptor.payload.courseId : null
    const courseId = resourceCourseId ?? state.courseId ?? ownerCourseId ?? placement?.courseId ?? null
    const [initialized, setInitialized] = useState(state.open)
    const [focusRequested, setFocusRequested] = useState(false)
    const resizeCleanup = useRef<(() => void) | null>(null)
    const stateRef = useRef(state); stateRef.current = state
    const root = useRef<HTMLDivElement>(null)
    const [availableWidth, setAvailableWidth] = useState(1000)
    const selection = useRef('')
    const update = useCallback((patch: Partial<AssistantPanelState>) => {
      const next = { ...stateRef.current, ...(courseId ? { courseId } : {}), ...patch }
      stateRef.current = next; setState(next)
      props.api.updateParameters({ assistant: next })
      useWorkspaceStore.getState().notifyLayoutChanged()
    }, [props.api, courseId])
    useLayoutEffect(() => {
      // An assistant opened before the first course only acquires an owner when
      // it can actually initialize a conversation. Keep that owner after moves.
      if (initialized && courseId && !state.courseId && ownerCourseId === null && resourceCourseId === null) update({ courseId })
    }, [initialized, courseId, state.courseId, ownerCourseId, resourceCourseId, update])
    useEffect(() => () => resizeCleanup.current?.(), [])
    useEffect(() => {
      if (!root.current) return
      const observer = new ResizeObserver(([entry]) => { if (entry) setAvailableWidth(entry.contentRect.width) })
      observer.observe(root.current)
      return () => observer.disconnect()
    }, [])
    useEffect(() => {
      if (!descriptor || !courseId || descriptor.kind === 'chat') return
      return registerDocumentContext(props.api.id, () => {
        const nav = descriptor.kind === 'browser' ? useBrowserGuests.getState().nav[descriptor.payload.tabId] : null
        return { courseId, documentId: props.api.id, kind: descriptor.kind, title: nav?.title || (descriptor.kind === 'learning' ? props.api.title || '학습 공간' : tabTitle(descriptor)),
          ...('relPath' in descriptor.payload ? { relPath: descriptor.payload.relPath } : {}),
          ...(descriptor.kind === 'browser' ? { browserTabId: descriptor.payload.tabId, url: nav?.url || descriptor.payload.initialUrl } : {}),
          ...(selection.current ? { selection: selection.current } : {}) }
      })
    }, [props.api.id, descriptor, courseId])
    useEffect(() => {
      const saveSelection = () => {
        const selected = window.getSelection()
        if (selected?.anchorNode && root.current?.querySelector('.tab-document')?.contains(selected.anchorNode)) selection.current = selected.toString().trim().slice(0, 8000)
      }
      document.addEventListener('selectionchange', saveSelection)
      return () => document.removeEventListener('selectionchange', saveSelection)
    }, [])
    const show = useCallback(() => { setInitialized(true); update({ open: true }) }, [update])
    const close = useCallback(() => update({ open: false }), [update])
    const focus = useCallback(() => setFocusRequested(true), [])
    const isChat = descriptor?.kind === 'chat'
    useLayoutEffect(() => registerAssistantController(props.api.id, {
      courseId,
      open: isChat || state.open,
      show: isChat ? () => {} : show,
      focus
    }, workspaceCourseId), [props.api.id, courseId, workspaceCourseId, isChat, state.open, show, focus])
    useEffect(() => {
      if (!focusRequested) return
      if (!active || (!isChat && !state.open)) { setFocusRequested(false); return }
      const element = root.current
      if (!element) return
      const target = isChat ? element : element.querySelector('.tab-assistant')
      if (!target) return
      const tryFocus = (): boolean => {
        const workspace = useWorkspaceStore.getState()
        if (workspace.activeCourseId !== workspaceCourseId || workspace.activePanelSource()?.panelId !== props.api.id) return false
        const composer = target.querySelector<HTMLTextAreaElement>('.chat-composer__input')
        if (!composer?.isConnected || composer.closest('[inert], [hidden]')) return false
        composer.focus()
        if (document.activeElement !== composer) return false
        setFocusRequested(false)
        return true
      }
      if (tryFocus()) return
      // ChatSurface is lazy: focus once the real composer has mounted, without
      // stealing focus if the user switches to another panel meanwhile.
      const observer = new MutationObserver(() => { if (tryFocus()) observer.disconnect() })
      // Settings fades out before its ancestor inert attribute is released.
      // Observe ancestors too, so opening AI during that fade still focuses.
      observer.observe(document.body, { childList: true, subtree: true, attributes: true,
        attributeFilter: ['inert', 'hidden', 'aria-hidden', 'class', 'style'] })
      return () => observer.disconnect()
    }, [focusRequested, active, isChat, state.open, props.api.id, workspaceCourseId])
    const ask = useCallback((text: string) => {
      updateComposerDraft(stateRef.current.conversationId, draft => ({ text: draft.text ? `${draft.text}\n\n${text}` : text }))
      show()
    }, [show])
    const setHighlightsOpen = useCallback((highlightsOpen: boolean) => update({ highlightsOpen }), [update])
    const toggle = useCallback(() => state.open ? close() : show(), [state.open, close, show])
    const context = useMemo(() => ({ panelId: props.api.id, open: state.open, toggle, highlightsOpen: state.highlightsOpen, setHighlightsOpen, ask }), [props.api.id, state.open, toggle, state.highlightsOpen, setHighlightsOpen, ask])
    if (isChat) return <div className="tab-assistant-chat-host" ref={root}><Component {...props} /></div>
    const overlay = availableWidth < state.width + 360
    return <PanelAssistantContext.Provider value={context}>
      <div className="tab-with-assistant" data-tour-panel={props.api.id} ref={root} data-assistant-open={state.open} data-assistant-overlay={overlay}>
        <div className="tab-document">
          {descriptor?.kind !== 'browser' && <div className="tab-assistant-launchbar"><span>{descriptor?.kind === 'learning' ? panelTitle || '학습 공간' : descriptor ? tabTitle(descriptor) : '현재 자료'}</span><AssistantPanelToggle /></div>}
          <div className="tab-document-content"><Component {...props} /></div>
        </div>
        {initialized && <aside hidden={!state.open} className="tab-assistant" data-tour={active && state.open ? "document-assistant" : undefined} role={overlay ? 'dialog' : 'complementary'} aria-label="탭 보조 사이드바" style={{ width: Math.min(state.width, availableWidth) }}>
          {!overlay && <div className="tab-assistant-resize" role="separator" aria-label="AI 사이드바 너비" aria-orientation="vertical" tabIndex={0}
            onKeyDown={e => { if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') { e.preventDefault(); update({ width: Math.max(280, Math.min(480, state.width + (e.key === 'ArrowLeft' ? 16 : -16))) }) } }}
            onPointerDown={e => {
              e.preventDefault()
              resizeCleanup.current?.()
              e.currentTarget.setPointerCapture(e.pointerId)
              const origin = e.clientX, width = state.width
              const move = (event: PointerEvent) => update({ width: Math.max(280, Math.min(480, width + origin - event.clientX)) })
              const end = () => { window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', end); window.removeEventListener('pointercancel', end) }
              resizeCleanup.current = end
              window.addEventListener('pointermove', move); window.addEventListener('pointerup', end, { once: true }); window.addEventListener('pointercancel', end, { once: true })
            }} />}
          <header className="tab-assistant-header">
            <span className="tab-assistant-title">✦ <span>AI</span></span>
            <div className="tab-assistant-header-actions">
              {courseId && <ConversationListMenu courseId={courseId} currentConversationId={state.conversationId}
                onNewConversation={() => update({ conversationId: crypto.randomUUID() })}
                onOpenConversation={conversationId => update({ conversationId })} />}
              <Tooltip label="대화 크게 열기" placement="bottom">
                <button className="bare-icon-button" aria-label="AI 대화 크게 열기" disabled={!courseId} onClick={() => {
                  if (!courseId) return
                  close()
                  useWorkspaceStore.getState().openTab(descriptorFor('chat', { courseId, conversationId: state.conversationId, sourcePanelId: props.api.id }))
                }}><svg viewBox="0 0 24 24" width="1em" height="1em" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M14 4h6v6M20 4l-8 8M10 20H4v-6M4 20l8-8" /></svg></button>
              </Tooltip>
              <Tooltip label="AI 닫기" placement="bottom">
                <button className="bare-icon-button" aria-label="AI 보조 사이드바 접기" onClick={close}><Icon name="x" /></button>
              </Tooltip>
            </div>
          </header>
          <div className="tab-assistant-ai">
            {courseId ? <Suspense fallback={<p className="tab-assistant-empty" role="status">AI를 준비하는 중…</p>}><ChatSurface courseId={courseId} conversationId={state.conversationId} sourcePanelId={props.api.id} variant="sidebar" hideHeader active={active && state.open} onOpenConversation={conversationId => update({ conversationId })} /></Suspense> : <p className="tab-assistant-empty">과목을 선택하면 AI와 대화할 수 있어요.</p>}
          </div>
        </aside>}
      </div>
    </PanelAssistantContext.Provider>
  }
}
