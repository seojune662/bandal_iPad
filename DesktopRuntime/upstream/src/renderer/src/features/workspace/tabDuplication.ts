import { v4 as uuidv4 } from 'uuid'
import type { TabDescriptor } from '../../../../shared/tabs'
import { tabPanelId } from './tabIdentity'

const DUPLICATE_PANEL_MARKER = '::duplicate::'

/** Documents share their data; browser copies must own a distinct native page. */
export function duplicateTabDescriptor(
  descriptor: TabDescriptor,
  browserUrl?: string
): TabDescriptor {
  if (descriptor.kind !== 'browser') return descriptor
  return {
    kind: 'browser',
    payload: {
      ...descriptor.payload,
      tabId: uuidv4(),
      initialUrl: browserUrl ?? descriptor.payload.initialUrl
    }
  }
}

/** Creates a persisted, unique dockview id for another view of the same tab. */
export function createDuplicatePanelId(descriptor: TabDescriptor): string {
  return `${tabPanelId(descriptor)}${DUPLICATE_PANEL_MARKER}${uuidv4()}`
}

/** Accepts the canonical identity and explicit duplicate-view identities. */
export function panelIdMatchesDescriptor(
  panelId: string,
  descriptor: TabDescriptor
): boolean {
  const canonicalId = tabPanelId(descriptor)
  if (panelId === canonicalId) return true
  const duplicatePrefix = `${canonicalId}${DUPLICATE_PANEL_MARKER}`
  return (
    panelId.startsWith(duplicatePrefix) &&
    panelId.length > duplicatePrefix.length
  )
}
