export type IpadSide = 'left' | 'right'
export type IpadAuxiliary = 'left' | 'materials' | 'assistant'
export type IpadPanelMode = 'auto' | 'overlay'
export type IpadPanelModes = Record<IpadAuxiliary, IpadPanelMode>
export type IpadPresentation = 'closed' | 'suspended' | 'docked' | 'overlay'
export const IPAD_CHROME_HEIGHT = 48
export const IPAD_NAVIGATION_WIDTH = 56
export const IPAD_LEFT_WIDTH = 280
export const IPAD_RIGHT_WIDTH = 320
export const IPAD_DOCUMENT_MIN_WIDTH = 560

type SplitNode = { type: string; size?: number; data: unknown }
type SplitLayout = { grid: { orientation: unknown; root: unknown } }
function sameSplit(a: SplitNode, b: SplitNode): boolean {
  if (a.type !== b.type) return false
  if (a.type === 'leaf') return (a.data as { id?: string }).id === (b.data as { id?: string }).id
  return Array.isArray(a.data) && Array.isArray(b.data) && a.data.length === b.data.length &&
    a.data.every((node, index) => sameSplit(node, (b.data as SplitNode[])[index]!))
}
/** toJSON temporarily unmaximizes Dockview and can change cached proportions. */
export function retainSplitProportions(current: SplitLayout, retained: SplitLayout): boolean {
  if (current.grid.orientation !== retained.grid.orientation || !sameSplit(current.grid.root as SplitNode, retained.grid.root as SplitNode)) return false
  const apply = (node: SplitNode, saved: SplitNode): void => {
    if (!Array.isArray(node.data) || !Array.isArray(saved.data)) return
    const sum = node.data.reduce((value, child) => value + (child.size ?? 1), 0)
    const savedSum = saved.data.reduce((value, child) => value + (child.size ?? 1), 0)
    node.data.forEach((child, index) => {
      child.size = sum * ((saved.data as SplitNode[])[index]!.size ?? 1) / savedSum
      apply(child, (saved.data as SplitNode[])[index]!)
    })
  }
  apply(current.grid.root as SplitNode, retained.grid.root as SplitNode)
  return true
}
export function splitGroupFractions(layout: SplitLayout): Array<{ id: string; width: number; height: number }> {
  const result: Array<{ id: string; width: number; height: number }> = []
  const visit = (node: SplitNode, horizontal: boolean, width: number, height: number): void => {
    if (node.type === 'leaf') { const id = (node.data as { id?: string }).id; if (id) result.push({ id, width, height }); return }
    if (!Array.isArray(node.data)) return
    const children = node.data as SplitNode[], sum = children.reduce((value, child) => value + (child.size ?? 1), 0)
    for (const child of children) { const fraction = (child.size ?? 1) / sum; visit(child, !horizontal, horizontal ? width * fraction : width, horizontal ? height : height * fraction) }
  }
  visit(layout.grid.root as SplitNode, layout.grid.orientation === 'HORIZONTAL', 1, 1)
  return result
}
/** Preserve unequal split proportions: each document still gets 560px. */
export function minimumSplitWidth(layout: SplitLayout, extraWidths: Record<string, number> = {}): number {
  const measure = (node: SplitNode, horizontal: boolean): number => {
    if (node.type === 'leaf' || !Array.isArray(node.data) || !node.data.length) return IPAD_DOCUMENT_MIN_WIDTH + (extraWidths[(node.data as { id?: string })?.id ?? ''] ?? 0)
    const children = node.data as SplitNode[]
    const widths = children.map(child => measure(child, !horizontal))
    if (!horizontal) return Math.max(...widths)
    const weights = children.map(child => Math.max(1, child.size ?? 1)), sum = weights.reduce((a, b) => a + b, 0)
    return Math.ceil(Math.max(...widths.map((width, index) => width * sum / weights[index]!)) + 8 * (children.length - 1))
  }
  return Math.max(700, measure(layout.grid.root as SplitNode, layout.grid.orientation === 'HORIZONTAL'))
}

export function ipadLayout(width: number, requested: { left: boolean; materials: boolean; assistantWidth?: number }, modes: IpadPanelModes, last: IpadAuxiliary) {
  const sizes = { left: IPAD_LEFT_WIDTH, materials: IPAD_RIGHT_WIDTH, assistant: requested.assistantWidth ?? IPAD_RIGHT_WIDTH }
  const open = { left: requested.left, materials: requested.materials && !requested.assistantWidth, assistant: !!requested.assistantWidth }
  const panels: Record<IpadAuxiliary, IpadPresentation> = { left: 'closed', materials: 'closed', assistant: 'closed' }
  const order = [last, ...(['left', 'materials', 'assistant'] as const).filter(side => side !== last)].filter(side => open[side])
  let budget = width - IPAD_NAVIGATION_WIDTH - IPAD_DOCUMENT_MIN_WIDTH
  let overlayOwner: IpadAuxiliary | null = null
  for (const [index, side] of order.entries()) {
    if (width >= 700 && modes[side] === 'auto' && budget >= sizes[side]) {
      panels[side] = 'docked'; budget -= sizes[side]
    } else if (index === 0) {
      panels[side] = 'overlay'; overlayOwner = side
    } else panels[side] = 'suspended'
  }
  const leftVisible = panels.left === 'docked' || panels.left === 'overlay'
  const rightVisible = panels.materials === 'docked' || panels.materials === 'overlay'
  const side = leftVisible && rightVisible ? 'both' : leftVisible ? 'left' : rightVisible ? 'right' : null
  const pinned = panels.left === 'docked' && panels.materials === 'docked' ? 'both' : panels.left === 'docked' ? 'left' : panels.materials === 'docked' ? 'right' : null
  return { panels, overlayOwner, side, pinned, presentation: width < 700 ? 'fullscreen' : 'sheet',
    overlay: overlayOwner === 'left' || overlayOwner === 'materials',
    leftInset: IPAD_NAVIGATION_WIDTH + (panels.left === 'docked' ? sizes.left : 0), rightInset: panels.materials === 'docked' ? sizes.materials : 0 }
}
