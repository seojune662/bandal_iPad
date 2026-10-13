/**
 * What ⌘P means right now.
 *
 * This one function drives three things at once — whether 파일 ▸ 인쇄… is
 * enabled, what the ⌘P push prints, and whether the context-menu entry does
 * anything — so it is the load-bearing piece of the whole print feature.
 *
 * Enablement is not cosmetic: a disabled macOS menu item does not perform its
 * key equivalent, so ⌘P falls through to the renderer and stays 빠른 파일
 * 검색. Returning a target here is literally what takes ⌘P away from search.
 */

import type { TabDescriptor } from '../../../../shared/tabs'

export type PrintTarget =
  | { kind: 'browser'; tabId: string }
  | { kind: 'pdf'; courseId: string; relPath: string }

export function printTargetFor(
  descriptor: TabDescriptor | null
): PrintTarget | null {
  if (descriptor === null) return null
  if (descriptor.kind === 'browser') {
    return { kind: 'browser', tabId: descriptor.payload.tabId }
  }
  if (descriptor.kind === 'pdf') {
    return {
      kind: 'pdf',
      courseId: descriptor.payload.courseId,
      relPath: descriptor.payload.relPath
    }
  }
  // Notes, boards, whiteboards, chats and group chats print nothing useful —
  // and claiming ⌘P for them would cost 빠른 파일 검색 its shortcut for no gain.
  return null
}
