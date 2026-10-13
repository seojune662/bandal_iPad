import type { DockviewApi, SerializedDockview, IDockviewGroupPanel } from 'dockview'

export type WorkspaceLayoutPreset = 'single' | 'columns' | 'rows' | 'grid'
export interface WorkspacePanelPosition {
  groupId: string
  direction?: 'within' | 'left' | 'right' | 'above' | 'below'
  /** Insertion index in the destination's order before the move. */
  index?: number
}
type Axis = 'HORIZONTAL' | 'VERTICAL'
interface Leaf {
  type: 'leaf'
  size?: number
  data: { id: string; views: string[]; activeView?: string; [key: string]: unknown }
}
interface Branch { type: 'branch'; size?: number; data: Node[] }
type Node = Leaf | Branch
const opposite = (axis: Axis): Axis => axis === 'HORIZONTAL' ? 'VERTICAL' : 'HORIZONTAL'
const tree = (layout: SerializedDockview): Branch => layout.grid.root as Branch
const copy = (api: DockviewApi): SerializedDockview => structuredClone(api.toJSON())
const newGroupId = (): string => `pane-${crypto.randomUUID()}`

function leaves(node: Node): Leaf[] {
  return node.type === 'leaf' ? [node] : node.data.flatMap(leaves)
}

/** Read visual row order from the split tree, also before DOM layout has run. */
function orderedLeaves(layout: SerializedDockview): Leaf[] {
  const positions: Array<{ leaf: Leaf; x: number; y: number }> = []
  const walk = (node: Node, axis: Axis, x: number, y: number, width: number, height: number): void => {
    if (node.type === 'leaf') { positions.push({ leaf: node, x, y }); return }
    const weights = node.data.map(child => Math.max(0, child.size ?? 1))
    const sum = weights.reduce((a, b) => a + b, 0) || node.data.length
    let offset = 0
    node.data.forEach((child, index) => {
      const part = (weights[index] || 1) / sum
      walk(child, opposite(axis), x + (axis === 'HORIZONTAL' ? width * offset : 0),
        y + (axis === 'VERTICAL' ? height * offset : 0),
        axis === 'HORIZONTAL' ? width * part : width, axis === 'VERTICAL' ? height * part : height)
      offset += part
    })
  }
  walk(tree(layout), layout.grid.orientation as Axis, 0, 0, 1, 1)
  return positions.sort((a, b) => Math.abs(a.y - b.y) > 0.001 ? a.y - b.y : a.x - b.x).map(item => item.leaf)
}

export function workspaceGroupsInVisualOrder(api: DockviewApi): IDockviewGroupPanel[] {
  return orderedLeaves(api.toJSON()).flatMap(leaf => {
    const group = api.getGroup(leaf.data.id)
    return group ? [group] : []
  })
}

/** All surviving panels retain their Dockview API, React content and native page. */
function apply(api: DockviewApi, layout: SerializedDockview): void {
  delete (layout.grid as SerializedDockview['grid'] & { maximizedNode?: unknown }).maximizedNode
  api.fromJSON(layout, { reuseExistingPanels: true })
}

function leaf(id: string, views: string[], selected: string | undefined, size: number): Leaf {
  return { type: 'leaf', size, data: { id, views, ...(selected && views.includes(selected)
    ? { activeView: selected } : views[0] ? { activeView: views[0] } : {}) } }
}

export function applyWorkspaceLayout(api: DockviewApi, preset: WorkspaceLayoutPreset): void {
  const layout = copy(api), previous = orderedLeaves(layout)
  const ids = previous.flatMap(group => group.data.views)
  const activePanel = api.activePanel?.id
  const count = preset === 'grid' ? 4 : preset === 'single' ? 1 : 2
  const width = Math.max(1, layout.grid.width), height = Math.max(1, layout.grid.height)
  let offset = 0
  const groups = Array.from({ length: count }, (_, index) => {
    const length = Math.floor(ids.length / count) + (index < ids.length % count ? 1 : 0)
    const views = ids.slice(offset, offset + length); offset += length
    return leaf(previous[index]?.data.id ?? newGroupId(), views, activePanel,
      preset === 'rows' || preset === 'grid' ? height / 2 : width / count)
  })
  // A horizontal root owns two columns; each column owns two vertical cells.
  layout.grid.orientation = (preset === 'rows' ? 'VERTICAL' : 'HORIZONTAL') as SerializedDockview['grid']['orientation']
  layout.grid.root = (preset === 'grid'
    ? { type: 'branch', size: height, data: [
        { type: 'branch', size: width / 2, data: [groups[0]!, groups[2]!] },
        { type: 'branch', size: width / 2, data: [groups[1]!, groups[3]!] }
      ] }
    : { type: 'branch', size: preset === 'rows' ? width : height, data: groups }) as SerializedDockview['grid']['root']
  layout.activeGroup = groups.find(group => activePanel && group.data.views.includes(activePanel))?.data.id ?? groups[0]!.data.id
  apply(api, layout)
}

function removeFromGroup(group: Leaf, panelId: string): void {
  const index = group.data.views.indexOf(panelId)
  group.data.views = group.data.views.filter(id => id !== panelId)
  if (group.data.activeView === panelId || !group.data.views.includes(group.data.activeView ?? '')) {
    const next = group.data.views[Math.max(0, Math.min(index, group.data.views.length - 1))]
    if (next) group.data.activeView = next
    else delete group.data.activeView
  }
}

/** Closing a tab does not implicitly close its pane. Close guards run at the caller. */
export function closeWorkspacePanel(api: DockviewApi, panelId: string, reason: 'close' | 'transfer' = 'close'): boolean {
  const panel = api.getPanel(panelId)
  if (!panel) return false
  if (!panel.group || panel.group.panels.length > 1) {
    if (reason === 'transfer') api.removePanel(panel)
    else panel.api.close()
    return true
  }
  const layout = copy(api)
  for (const group of leaves(tree(layout))) removeFromGroup(group, panelId)
  delete layout.panels[panelId]
  apply(api, layout)
  return true
}

function insertSplit(layout: SerializedDockview, groupId: string, direction: Exclude<WorkspacePanelPosition['direction'], 'within' | undefined>, next: Leaf): boolean {
  const desired: Axis = direction === 'left' || direction === 'right' ? 'HORIZONTAL' : 'VERTICAL'
  const before = direction === 'left' || direction === 'above'
  const walk = (parent: Branch, axis: Axis, width: number, height: number): boolean => {
    const weights = parent.data.map(child => Math.max(1, child.size ?? 1))
    const sum = weights.reduce((a, b) => a + b, 0)
    for (let index = 0; index < parent.data.length; index++) {
      const child = parent.data[index]!
      const part = weights[index]! / sum
      const childWidth = axis === 'HORIZONTAL' ? width * part : width
      const childHeight = axis === 'VERTICAL' ? height * part : height
      if (child.type === 'branch') {
        if (walk(child, opposite(axis), childWidth, childHeight)) return true
      } else if (child.data.id === groupId) {
        if (axis === desired) {
          child.size = (child.size ?? (axis === 'HORIZONTAL' ? childWidth : childHeight)) / 2
          next.size = child.size
          parent.data.splice(index + (before ? 0 : 1), 0, next)
        } else {
          const originalSize = child.size
          child.size = next.size = (desired === 'HORIZONTAL' ? childWidth : childHeight) / 2
          parent.data[index] = { type: 'branch', ...(originalSize === undefined ? {} : { size: originalSize }), data: before ? [next, child] : [child, next] }
        }
        return true
      }
    }
    return false
  }
  return walk(tree(layout), layout.grid.orientation as Axis, Math.max(1, layout.grid.width), Math.max(1, layout.grid.height))
}

export function splitWorkspaceGroup(api: DockviewApi, groupId: string, direction: 'right' | 'below'): string | null {
  if (!api.getGroup(groupId)) return null
  const layout = copy(api), id = newGroupId()
  if (!insertSplit(layout, groupId, direction, leaf(id, [], undefined, 1))) return null
  layout.activeGroup = id
  apply(api, layout)
  return id
}

export function moveWorkspacePanel(api: DockviewApi, panelId: string, position: WorkspacePanelPosition): boolean {
  const panel = api.getPanel(panelId)
  if (!panel || !api.getGroup(position.groupId)) return false
  const layout = copy(api), groups = leaves(tree(layout))
  const source = groups.find(group => group.data.views.includes(panelId))
  const target = groups.find(group => group.data.id === position.groupId)
  if (!source || !target) return false
  const sourceIndex = source.data.views.indexOf(panelId)
  let index = Math.max(0, Math.min(position.index ?? target.data.views.length, target.data.views.length))
  if (source === target && sourceIndex < index) index--
  removeFromGroup(source, panelId)
  if (position.direction && position.direction !== 'within') {
    const next = leaf(newGroupId(), [panelId], panelId, 1)
    if (!insertSplit(layout, target.data.id, position.direction, next)) return false
    layout.activeGroup = next.data.id
  } else {
    target.data.views.splice(index, 0, panelId)
    target.data.activeView = panelId
    layout.activeGroup = target.data.id
  }
  apply(api, layout)
  return true
}

export function removeEmptyWorkspaceGroup(api: DockviewApi, groupId: string): boolean {
  const group = api.getGroup(groupId)
  if (!group || group.panels.length) return false
  // No panels are destroyed, and Dockview normalizes the remaining split tree.
  api.removeGroup(group)
  return true
}
