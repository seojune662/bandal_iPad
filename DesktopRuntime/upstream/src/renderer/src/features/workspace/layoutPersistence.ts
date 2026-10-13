/**
 * Per-course layout persistence logic (pure).
 *
 * The persisted document is dockview's own `SerializedDockview` JSON: every
 * panel carries its `TabDescriptor` in `params.descriptor`, so no side-table
 * is needed. This module owns the two hard parts:
 *
 *  1. `validateLayout` — hard validation on hydration. Unknown tab kinds or
 *     malformed descriptors drop the panel (and the grid tree is pruned so
 *     dockview never sees a dangling reference). A structurally broken
 *     document returns `null` → caller starts from an empty layout. Never
 *     throws.
 *  2. `structuralKey` — a fingerprint that ignores decorative churn (active
 *     group / active tab focus changes) so pure focus changes do not
 *     trigger a save, while open/close/move/resize do.
 *
 * Rotating backups + atomic writes happen main-side; `layout:save` is a
 * plain upsert from the renderer's point of view.
 */

import type { SerializedDockview } from 'dockview'
import type { TabDescriptor } from '../../../../shared/tabs'
import { isTabDescriptor } from './tabIdentity'
import { panelIdMatchesDescriptor } from './tabDuplication'

export const LAYOUT_SAVE_DEBOUNCE_MS = 1000

interface LeafData {
  id: string
  views: string[]
  activeView?: string
  [key: string]: unknown
}

interface GridNode {
  type: 'leaf' | 'branch'
  data: LeafData | GridNode[]
  size?: number
  visible?: boolean
}

export interface ValidatedLayout {
  layout: SerializedDockview
  /** Descriptors of the panels that survived validation, by panel id. */
  tabs: Record<string, TabDescriptor>
  /** Panel ids dropped during validation (for logging / resave). */
  droppedPanelIds: string[]
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asGridNode(value: unknown): GridNode | null {
  if (!isRecord(value)) return null
  if (value['type'] === 'leaf') {
    const data = value['data']
    if (!isRecord(data)) return null
    if (typeof data['id'] !== 'string') return null
    if (!Array.isArray(data['views'])) return null
    return value as unknown as GridNode
  }
  if (value['type'] === 'branch') {
    if (!Array.isArray(value['data'])) return null
    return value as unknown as GridNode
  }
  return null
}

/** Keep intentional empty panes; invalid references alone never create a pane. */
function pruneNode(raw: unknown, keep: ReadonlySet<string>, preserveEmptied = false): GridNode | null {
  const node = asGridNode(raw)
  if (node === null) return null

  if (node.type === 'leaf') {
    const data = node.data as LeafData
    const views = data.views.filter(
      (view): view is string => typeof view === 'string' && keep.has(view)
    )
    if (views.length === 0 && data.views.length > 0 && !preserveEmptied) return null
    const activeView =
      typeof data.activeView === 'string' && views.includes(data.activeView)
        ? data.activeView
        : views[0]
    const nextData: LeafData = { ...data, views }
    if (activeView !== undefined) nextData.activeView = activeView
    else delete nextData.activeView
    return { ...node, data: nextData }
  }

  const children = (node.data as unknown[])
    .map((child) => pruneNode(child, keep, preserveEmptied))
    .filter((child): child is GridNode => child !== null)
  if (children.length === 0) return null
  return { ...node, data: children }
}

function collectGroupIds(node: GridNode, into: Set<string>): void {
  if (node.type === 'leaf') {
    into.add((node.data as LeafData).id)
    return
  }
  for (const child of node.data as GridNode[]) collectGroupIds(child, into)
}

function collectViewIds(node: GridNode, into: Set<string>): void {
  if (node.type === 'leaf') {
    for (const view of (node.data as LeafData).views) into.add(view)
    return
  }
  for (const child of node.data as GridNode[]) collectViewIds(child, into)
}

/**
 * Validate a raw persisted document. Returns the cleaned layout plus the
 * surviving tab descriptors, or `null` when the document is unusable and
 * the caller should fall back to an empty workspace. Never throws.
 */
export function validateLayout(raw: unknown): ValidatedLayout | null {
  if (!isRecord(raw)) return null
  const grid = raw['grid']
  const panels = raw['panels']
  if (!isRecord(grid) || !isRecord(panels)) return null
  if (typeof grid['width'] !== 'number' || typeof grid['height'] !== 'number') {
    return null
  }
  if (typeof grid['orientation'] !== 'string') return null

  // 1. Validate each panel's descriptor; drop anything suspicious.
  const tabs: Record<string, TabDescriptor> = {}
  const droppedPanelIds: string[] = []
  const validPanels: Record<string, Record<string, unknown>> = {}
  for (const [panelId, state] of Object.entries(panels)) {
    if (!isRecord(state)) {
      droppedPanelIds.push(panelId)
      continue
    }
    const params = state['params']
    const descriptor = isRecord(params) ? params['descriptor'] : undefined
    const isValid =
      isTabDescriptor(descriptor) &&
      // Canonical ids round-trip to the dedupe key. Explicit duplicate-view
      // ids retain that canonical prefix and are validated by the same helper.
      panelIdMatchesDescriptor(panelId, descriptor) &&
      state['contentComponent'] === descriptor.kind
    if (!isValid) {
      droppedPanelIds.push(panelId)
      continue
    }
    tabs[panelId] = descriptor
    validPanels[panelId] = state
  }

  // 2. Prune the split tree down to surviving panels.
  const keep = new Set(Object.keys(validPanels))
  const root = pruneNode(grid['root'], keep)
  if (root === null) return null

  // 3. Panels referenced by no surviving group are dropped too (this also
  //    sheds panels that only lived in floating/popout groups, which M2
  //    does not restore).
  const referenced = new Set<string>()
  collectViewIds(root, referenced)
  const panelsOut: Record<string, Record<string, unknown>> = {}
  for (const [panelId, state] of Object.entries(validPanels)) {
    if (referenced.has(panelId)) panelsOut[panelId] = state
    else {
      droppedPanelIds.push(panelId)
      delete tabs[panelId]
    }
  }
  const groupIds = new Set<string>()
  collectGroupIds(root, groupIds)

  const layout: Record<string, unknown> = {
    grid: {
      root,
      width: grid['width'],
      height: grid['height'],
      orientation: grid['orientation']
    },
    panels: panelsOut
  }
  const activeGroup = raw['activeGroup']
  if (typeof activeGroup === 'string' && groupIds.has(activeGroup)) {
    layout['activeGroup'] = activeGroup
  }

  return {
    layout: layout as unknown as SerializedDockview,
    tabs,
    droppedPanelIds
  }
}

function stripDecorative(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stripDecorative)
  if (!isRecord(value)) return value
  const out: Record<string, unknown> = {}
  for (const [key, entry] of Object.entries(value)) {
    // `initialUrl` tracks where a browser tab currently IS, so it changes on
    // every navigation. Treating it as structural would schedule a debounced
    // write per page load (an SPA would hammer it); leaving it out means the
    // parked snapshot still carries it to disk on quit and course switch.
    if (key === 'activeGroup' || key === 'activeView' || key === 'initialUrl') {
      continue
    }
    out[key] = stripDecorative(entry)
  }
  return out
}

/**
 * Structural fingerprint of a serialized layout. Two layouts that differ
 * only in focus (active group / active tab) produce the same key; adding,
 * closing, moving or resizing panels changes it.
 */
export function structuralKey(layout: unknown): string {
  return JSON.stringify(stripDecorative(layout))
}

/** Extract surviving descriptors from an already-live serialized layout. */
export function tabsFromLayout(layout: unknown): Record<string, TabDescriptor> {
  if (!isRecord(layout) || !isRecord(layout['panels'])) return {}
  const tabs: Record<string, TabDescriptor> = {}
  for (const [panelId, state] of Object.entries(layout['panels'])) {
    if (!isRecord(state)) continue
    const params = state['params']
    const descriptor = isRecord(params) ? params['descriptor'] : undefined
    if (isTabDescriptor(descriptor)) tabs[panelId] = descriptor
  }
  return tabs
}

/**
 * Remove private browser panels before a layout crosses the renderer/process
 * boundary. The live layout remains untouched, so private tabs can return
 * when the student switches back to a course during the same app run.
 */
export function persistentLayout(layout: unknown): unknown {
  if (!isRecord(layout) || !isRecord(layout['panels']) || !isRecord(layout['grid'])) {
    return layout
  }
  const panels: Record<string, unknown> = {}
  const keep = new Set<string>()
  for (const [panelId, state] of Object.entries(layout['panels'])) {
    const params = isRecord(state) ? state['params'] : undefined
    const descriptor = isRecord(params) ? params['descriptor'] : undefined
    if (
      isTabDescriptor(descriptor) &&
      descriptor.kind === 'browser' &&
      descriptor.payload.isPrivate === true
    ) {
      continue
    }
    panels[panelId] = state
    keep.add(panelId)
  }
  // Removing a private tab is an intentional close, not a corrupt descriptor.
  const root = pruneNode(layout['grid']['root'], keep, true)
  if (root === null) return {}
  return {
    ...layout,
    grid: { ...layout['grid'], root },
    panels
  }
}
