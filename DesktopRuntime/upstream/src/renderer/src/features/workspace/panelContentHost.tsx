import { useContext, useLayoutEffect, useRef, useSyncExternalStore, type FunctionComponent } from 'react'
import type { DockviewApi, DockviewPanelApi, IDockviewPanelProps } from 'dockview'
import { CourseActivity } from './courseActivity'
import { WorkspaceCourseContext, WorkspacePlacementContext } from './placementContext'
import { createRebindingApi } from './rebindingApi'
import { tabDragSession } from './tabDragSession'

type PanelProps = IDockviewPanelProps
type Bounds = { x: number; y: number; width: number; height: number }
interface ContentEntry {
  instanceId: string
  courseId: string | null
  panelId: string
  props: PanelProps
  panel: ReturnType<typeof createRebindingApi<DockviewPanelApi>>
  container: ReturnType<typeof createRebindingApi<DockviewApi>>
  slot: HTMLElement | null
  groupContent: HTMLElement | null
  resize: ResizeObserver
  bounds: Bounds
  transferring: boolean
  dispose: (() => void)[]
}
const entries = new Map<string, ContentEntry>()
let byApi = new WeakMap<DockviewPanelApi, ContentEntry>()
let slots = new WeakMap<DockviewPanelApi, HTMLElement>()
const listeners = new Set<() => void>()
let snapshot: ContentEntry[] = []
let layoutFrame = 0
function publish(): void {
  snapshot = [...entries.values()]
  for (const listener of listeners) listener()
}
function measure(): void {
  layoutFrame = 0
  let changed = false
  for (const entry of entries.values()) {
    if (!entry.slot?.isConnected || entry.transferring) continue
    const root = entry.slot.closest('.workspace-host')
    if (!root) continue
    // Dockview's "always" overlay copies group bounds asynchronously. It can
    // retain a zero or pre-move rectangle even after the group has laid out.
    // Our live content is outside that overlay: measure the actual group area.
    const group = entry.props.api.group?.element
    const content = group && root.contains(group)
      ? group.querySelector<HTMLElement>(':scope > .dv-content-container') : null
    if (entry.groupContent !== content) {
      entry.resize.disconnect()
      entry.groupContent = content
      if (content) entry.resize.observe(content)
    }
    if (!entry.props.api.isVisible) continue
    const outer = root.getBoundingClientRect(), rect = (content ?? entry.slot).getBoundingClientRect()
    if (rect.width <= 0 || rect.height <= 0) continue
    const next = { x: rect.x - outer.x, y: rect.y - outer.y, width: rect.width, height: rect.height }
    if (Object.keys(next).some(key => next[key as keyof Bounds] !== entry.bounds[key as keyof Bounds])) {
      entry.bounds = next
      changed = true
    }
  }
  if (changed) publish()
}
export function schedulePanelContentLayout(): void {
  if (!layoutFrame) layoutFrame = requestAnimationFrame(measure)
}
function removeEntry(entry: ContentEntry): void {
  if (entries.get(entry.instanceId) !== entry) return
  entries.delete(entry.instanceId)
  entry.resize.disconnect()
  entry.dispose.forEach(dispose => dispose())
  entry.panel.dispose()
  entry.container.dispose()
  publish()
}
function registerSlot(props: PanelProps, courseId: string | null, slot: HTMLElement): ContentEntry {
  slots.set(props.api, slot)
  let entry = byApi.get(props.api)
  if (!entry) {
    const panel = createRebindingApi(props.api), container = createRebindingApi(props.containerApi)
    entry = { instanceId: crypto.randomUUID(), courseId, panelId: props.api.id,
      props: { ...props, api: panel.api, containerApi: container.api }, panel, container,
      slot, groupContent: null, resize: new ResizeObserver(schedulePanelContentLayout),
      bounds: { x: 0, y: 0, width: 0, height: 0 }, transferring: false, dispose: [] }
    entries.set(entry.instanceId, entry)
    byApi.set(props.api, entry)
    const current = entry
    current.dispose = [
      panel.api.onDidActiveChange(() => publish()).dispose,
      panel.api.onDidVisibilityChange(() => { schedulePanelContentLayout(); publish() }).dispose,
      panel.api.onDidDimensionsChange(() => schedulePanelContentLayout()).dispose,
      panel.api.onDidGroupChange(() => schedulePanelContentLayout()).dispose,
      panel.api.onDidParametersChange(parameters => {
        const params = { ...current.props.params, ...parameters }
        for (const key of Object.keys(parameters)) if (parameters[key] === undefined) delete params[key]
        current.props = { ...current.props, params }
        publish()
      }).dispose
    ]
  }
  entry.slot = slot
  entry.courseId = courseId
  entry.transferring = false
  entry.props = { ...props, api: entry.panel.api, containerApi: entry.container.api }
  publish()
  schedulePanelContentLayout()
  return entry
}

/** Dockview owns only this empty presentation slot, never the live content. */
export function WorkspacePanelSlot(props: PanelProps): JSX.Element {
  const slot = useRef<HTMLDivElement>(null)
  const courseId = useContext(WorkspaceCourseContext)
  useLayoutEffect(() => {
    if (!slot.current) return
    const element = slot.current
    const entry = registerSlot(props, courseId, element)
    const resize = new ResizeObserver(schedulePanelContentLayout)
    resize.observe(element)
    return () => {
      resize.disconnect()
      if (slots.get(props.api) === element) slots.delete(props.api)
      if (entry.slot !== element) return
      entry.slot = null
      queueMicrotask(() => { if (!entry.slot && !entry.transferring) removeEntry(entry) })
    }
  }, [props.api])
  useLayoutEffect(() => {
    const entry = byApi.get(props.api)
    if (entry) {
      entry.props = { ...props, api: entry.panel.api, containerApi: entry.container.api }
      publish()
    }
  }, [props.params, props.api])
  return <div className="workspace-panel-slot" ref={slot} data-panel-slot={props.api.id} />
}

/** Called before the source presentation is disposed, with identity unchanged. */
export function rebindPanelContent(source: DockviewPanelApi, target: DockviewPanelApi,
  container: DockviewApi, courseId: string | null): void {
  const entry = byApi.get(source)
  if (!entry) return // An unvisited/lazy panel has no content state to retain.
  if (source.id !== target.id) throw new Error('Moving a panel must preserve its identity')
  entry.slot = slots.get(target) ?? null
  entry.transferring = entry.slot === null
  entry.courseId = courseId
  byApi.set(target, entry)
  entry.container.rebind(container)
  entry.panel.rebind(target)
  publish()
  schedulePanelContentLayout()
}

export function WorkspaceContentLayer({ components, activeCourseId, active }: {
  components: Record<string, FunctionComponent<PanelProps>>
  activeCourseId: string | null
  active: boolean
}): JSX.Element {
  const contents = useSyncExternalStore(listener => { listeners.add(listener); return () => { listeners.delete(listener) } }, () => snapshot)
  const dragging = useSyncExternalStore(tabDragSession.subscribe, tabDragSession.getSnapshot) !== null
  useLayoutEffect(() => {
    const resize = new ResizeObserver(schedulePanelContentLayout)
    const root = document.querySelector('.workspace-host')
    if (root) resize.observe(root)
    const mutations = new MutationObserver(schedulePanelContentLayout)
    if (root) mutations.observe(root, { subtree: true, attributes: true, attributeFilter: ['hidden', 'style', 'class'] })
    window.addEventListener('resize', schedulePanelContentLayout)
    window.addEventListener('scroll', schedulePanelContentLayout, true)
    schedulePanelContentLayout()
    return () => {
      resize.disconnect(); mutations.disconnect()
      window.removeEventListener('resize', schedulePanelContentLayout)
      window.removeEventListener('scroll', schedulePanelContentLayout, true)
    }
  }, [])
  useLayoutEffect(schedulePanelContentLayout, [activeCourseId, active])
  return <div className="workspace-content-layer" data-content-dragging={dragging || undefined}>
    {contents.map(entry => {
      const Component = components[entry.props.api.component]
      if (!Component) return null
      const courseActive = active && entry.courseId === activeCourseId
      const visible = courseActive && entry.props.api.isVisible
      return <CourseActivity.Provider key={entry.instanceId} value={courseActive}>
        <WorkspacePlacementContext.Provider value={{ courseId: entry.courseId, panelId: entry.panelId, instanceId: entry.instanceId }}>
          <div className="workspace-panel-content" data-panel-instance={entry.instanceId}
            data-content-panel={entry.panelId} data-content-course={entry.courseId ?? ''}
            hidden={!visible} aria-hidden={!visible} {...{ inert: !visible ? '' : undefined }}
            style={{ left: entry.bounds.x, top: entry.bounds.y, width: entry.bounds.width, height: entry.bounds.height }}
            onPointerDownCapture={() => { if (!entry.props.api.isActive) entry.props.api.setActive() }}>
            <Component {...entry.props} />
          </div>
        </WorkspacePlacementContext.Provider>
      </CourseActivity.Provider>
    })}
  </div>
}

export function resetPanelContentForTests(): void {
  for (const entry of [...entries.values()]) removeEntry(entry)
  byApi = new WeakMap()
  slots = new WeakMap()
  if (layoutFrame) cancelAnimationFrame(layoutFrame)
  layoutFrame = 0
}
