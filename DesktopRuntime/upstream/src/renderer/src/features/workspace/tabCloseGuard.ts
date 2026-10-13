import type { TabDescriptor } from '../../../../shared/tabs'

type CloseGuard = (descriptor: TabDescriptor) => boolean | Promise<boolean>
let guard: CloseGuard | null = null

/** Native browser pages can veto a user close through their beforeunload flow. */
export function registerTabCloseGuard(next: CloseGuard): () => void {
  guard = next
  return () => {
    if (guard === next) guard = null
  }
}

export function canCloseTab(
  descriptor: TabDescriptor
): boolean | Promise<boolean> {
  return guard?.(descriptor) ?? true
}
