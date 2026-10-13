/**
 * Keeps 파일 ▸ 인쇄… in step with the focused tab, and opens the preview when
 * it fires.
 *
 * Enabling the menu item is what claims ⌘P; disabling it is what gives ⌘P
 * back to 빠른 파일 검색, because a disabled macOS menu item does not perform
 * its key equivalent. So this hook is the whole context-sensitivity mechanism
 * — not a cosmetic greying-out.
 */

import { useEffect } from 'react'
import { invoke, onPush } from '../../lib/ipc'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { useBrowserGuests } from '../browser/browserGuestsStore'
import { printTargetFor } from './printTarget'
import { usePrintStore } from './printStore'

/** The title the print job and the saved file are named after. */
function titleForTarget(): string {
  const descriptor = useWorkspaceStore.getState().activeTabDescriptor()
  const target = printTargetFor(descriptor)
  if (target === null) return ''
  if (target.kind === 'pdf') {
    return target.relPath.split('/').pop() ?? target.relPath
  }
  const nav = useBrowserGuests.getState().nav[target.tabId]
  return nav?.title ?? ''
}

export function usePrintRequests(): void {
  useEffect(() => {
    let lastEnabled: boolean | null = null
    const sync = (): void => {
      const descriptor = useWorkspaceStore.getState().activeTabDescriptor()
      const enabled = printTargetFor(descriptor) !== null
      if (enabled === lastEnabled) return
      lastEnabled = enabled
      // Guarded rather than just `.catch`: this runs inside a store
      // subscription, and a synchronous throw here would take the whole
      // subscriber down with it.
      try {
        void invoke('window:setPrintEnabled', { enabled }).catch(() => {
          // The menu item stays where it was; ⌘P still does something.
        })
      } catch {
        // No bridge yet. The next tab change tries again.
        lastEnabled = null
      }
    }

    sync()
    const unsubscribe = useWorkspaceStore.subscribe(sync)
    const unsubscribePrint = onPush('ui:print', () => {
      const descriptor = useWorkspaceStore.getState().activeTabDescriptor()
      const target = printTargetFor(descriptor)
      if (target === null) return
      usePrintStore.getState().open(target, titleForTarget())
    })
    return () => {
      unsubscribe()
      unsubscribePrint()
    }
  }, [])
}
