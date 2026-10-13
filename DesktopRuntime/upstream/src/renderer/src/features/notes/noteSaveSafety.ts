import type {
  CreateNoteInput,
  NoteRef
} from '../../../../shared/types/note'
import { invoke } from '../../lib/ipc'

export type NoteFlushResult =
  | { status: 'saved' }
  | { status: 'conflict'; detail: string }
  | { status: 'error'; detail: string }
  | { status: 'unavailable' }

export interface NoteCloseSnapshot {
  ref: NoteRef
  markdown: string
  persistedMarkdown: string
  conflict: boolean
}

export type NoteCloseResult =
  | { status: 'saved' }
  | { status: 'copied'; copy: NoteRef }
  | { status: 'failed'; reason: 'write' | 'copy' }

interface NoteCloseActions {
  flush: () => Promise<NoteFlushResult>
  snapshot: () => NoteCloseSnapshot
  createConflictCopy: (ref: NoteRef, markdown: string) => Promise<NoteRef>
  notify: (message: string, tone: 'info' | 'danger') => void
}

interface NoteFlushTriggers {
  windowTarget: EventTarget
  documentTarget: EventTarget
  visibilityState: () => DocumentVisibilityState
  flush: () => void
  close: () => void
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function conflictCopyInput(ref: NoteRef): CreateNoteInput {
  const separator = ref.relPath.lastIndexOf('/')
  const dirRelPath = separator === -1 ? '' : ref.relPath.slice(0, separator)
  const fileName = separator === -1 ? ref.relPath : ref.relPath.slice(separator + 1)
  const stem = fileName.toLowerCase().endsWith('.md')
    ? fileName.slice(0, -3)
    : fileName

  return {
    courseId: ref.courseId,
    dirRelPath,
    title: `${stem || '필기'} (충돌 사본)`
  }
}

/**
 * Creates through notes:create so its existing `-2`, `-3`, ... collision
 * handling selects the path, then replaces the generated heading with the
 * student's complete editor contents.
 */
export async function createNoteConflictCopy(
  ref: NoteRef,
  markdown: string
): Promise<NoteRef> {
  const copy = await invoke('notes:create', conflictCopyInput(ref))
  await invoke('notes:write', { ...copy, markdown })
  return copy
}

/** Installs early, non-blocking flush points around the final unload attempt. */
export function registerNoteFlushTriggers(
  triggers: NoteFlushTriggers
): () => void {
  const handleBeforeUnload = (): void => triggers.close()
  const handleWindowBlur = (): void => triggers.flush()
  const handleVisibilityChange = (): void => {
    if (triggers.visibilityState() === 'hidden') triggers.flush()
  }

  triggers.windowTarget.addEventListener('beforeunload', handleBeforeUnload)
  triggers.windowTarget.addEventListener('blur', handleWindowBlur)
  triggers.documentTarget.addEventListener(
    'visibilitychange',
    handleVisibilityChange
  )

  return () => {
    triggers.windowTarget.removeEventListener('beforeunload', handleBeforeUnload)
    triggers.windowTarget.removeEventListener('blur', handleWindowBlur)
    triggers.documentTarget.removeEventListener(
      'visibilitychange',
      handleVisibilityChange
    )
  }
}

/**
 * Runs independently of React mounted state. A tab can disappear while this
 * awaits IPC, but its outcome still reaches the app-level toast host.
 */
export async function preserveNoteOnClose(
  actions: NoteCloseActions
): Promise<NoteCloseResult> {
  let flushResult: NoteFlushResult
  try {
    flushResult = await actions.flush()
  } catch (error) {
    flushResult = { status: 'error', detail: errorMessage(error) }
  }

  const snapshot = actions.snapshot()
  if (snapshot.markdown === snapshot.persistedMarkdown) {
    return { status: 'saved' }
  }

  if (snapshot.conflict || flushResult.status === 'conflict') {
    try {
      const copy = await actions.createConflictCopy(snapshot.ref, snapshot.markdown)
      actions.notify(
        `“${snapshot.ref.relPath}”의 충돌 중 편집 내용을 “${copy.relPath}”에 저장했어요.`,
        'info'
      )
      return { status: 'copied', copy }
    } catch (error) {
      actions.notify(
        `“${snapshot.ref.relPath}”의 충돌 사본을 저장하지 못했어요: ${errorMessage(error)}`,
        'danger'
      )
      return { status: 'failed', reason: 'copy' }
    }
  }

  const detail =
    flushResult.status === 'error'
      ? `: ${flushResult.detail}`
      : ''
  actions.notify(
    `“${snapshot.ref.relPath}”을 저장하지 못했어요${detail}`,
    'danger'
  )
  return { status: 'failed', reason: 'write' }
}
