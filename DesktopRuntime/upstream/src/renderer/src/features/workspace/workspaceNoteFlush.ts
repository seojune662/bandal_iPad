import { retainedTabDescriptors } from '../../stores/workspaceStore'
import { flushOpenNoteSession } from '../notes/noteSessionRegistry'

/** Cache eviction follows placement; moved notes still save their original file. */
export async function flushWorkspaceNotes(courseId: string): Promise<boolean> {
  for (const descriptor of retainedTabDescriptors(courseId)) {
    if (descriptor.kind !== 'note') continue
    const flushed = await flushOpenNoteSession(descriptor.payload)
    if (flushed !== null && flushed.result.status !== 'saved') return false
  }
  return true
}
