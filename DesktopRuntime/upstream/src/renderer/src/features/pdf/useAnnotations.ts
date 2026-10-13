/**
 * Annotation state for one open PDF: loads the file's annotations over IPC
 * and exposes create/update/remove that keep local state in sync with the
 * main-process store (immutably — new arrays on every change).
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { invoke, onPush } from '../../lib/ipc'
import type {
  Annotation,
  CreateAnnotationInput,
  HighlightColor,
  UpdateAnnotationInput
} from '../../../../shared/types/annotation'

export interface AnnotationsApi {
  annotations: Annotation[]
  byPage: Map<number, Annotation[]>
  loading: boolean
  /** Non-null after a failed IPC call; cleared by the next success. */
  error: string | null
  flush?(): Promise<void>
  retryUpdates?(): Promise<void>
  hasUnsavedUpdates?: boolean
  create(input: CreateAnnotationInput): Promise<Annotation | null>
  update(input: UpdateAnnotationInput): Promise<Annotation | null>
  remove(id: string): Promise<boolean>
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  return '주석 저장 중 오류가 발생했어요.'
}

export function useAnnotations(
  courseId: string,
  relPath: string
): AnnotationsApi {
  // The load and every write share one queue. A late initial read must not
  // erase a highlight created while the PDF itself was already usable.
  const session = useMemo(() => ({
    annotations: [] as Annotation[],
    loading: true,
    loadError: null as string | null,
    saveError: null as string | null,
    failedUpdates: new Map<string, { input: UpdateAnnotationInput; error: string }>(),
    queue: Promise.resolve()
  }), [courseId, relPath])
  const active = useRef<typeof session | null>(session)
  active.current = session
  const [snapshot, setSnapshot] = useState({ session, annotations: session.annotations,
    loading: true, error: null as string | null })
  const publish = useCallback((): void => {
    if (active.current !== session) return
    setSnapshot({ session, annotations: session.annotations.map(entry => ({ ...entry, ...session.failedUpdates.get(entry.id)?.input })), loading: session.loading,
      error: session.saveError ?? session.loadError })
  }, [session])
  const enqueue = useCallback(<T,>(operation: () => Promise<T>): Promise<T> => {
    const result = session.queue.then(operation)
    session.queue = result.then(() => undefined, () => undefined)
    return result
  }, [session])

  useEffect(() => {
    active.current = session
    void enqueue(async () => {
      try {
        session.annotations = await invoke('annotations:listForFile', { courseId, relPath })
        session.loadError = null
      } catch (cause) {
        session.loadError = errorMessage(cause)
      } finally {
        session.loading = false
        publish()
      }
    })
    return () => { if (active.current === session) active.current = null }
  }, [courseId, relPath, enqueue, publish, session])

  useEffect(() => onPush('materials:changed', ({ courseId: changedCourseId }) => {
    if (changedCourseId !== courseId) return
    void enqueue(async () => {
      try {
        session.annotations = await invoke('annotations:listForFile', { courseId, relPath })
        session.loadError = null
      } catch (cause) { session.loadError = errorMessage(cause) }
      finally { publish() }
    })
  }), [courseId, relPath, enqueue, publish, session])

  const create = useCallback((input: CreateAnnotationInput): Promise<Annotation | null> => {
    if (input.courseId !== courseId || input.relPath !== relPath) return Promise.resolve(null)
    return enqueue(async () => {
      try {
        const created = await invoke('annotations:create', input)
        session.annotations = [...session.annotations, created]
        session.saveError = session.failedUpdates.values().next().value?.error ?? null
        return created
      } catch (cause) {
        session.saveError = errorMessage(cause)
        return null
      } finally { publish() }
    })
  }, [courseId, relPath, enqueue, publish, session])

  const update = useCallback((input: UpdateAnnotationInput): Promise<Annotation | null> =>
    enqueue(async () => {
      try {
        const updated = await invoke('annotations:update', input)
        session.annotations = session.annotations.map((entry) => entry.id === updated.id ? updated : entry)
        const failed = session.failedUpdates.get(input.id)
        if (failed !== undefined) {
          const remaining = { ...failed.input }
          if (input.color !== undefined) delete remaining.color
          if (input.comment !== undefined) delete remaining.comment
          if (remaining.color === undefined && remaining.comment === undefined) session.failedUpdates.delete(input.id)
          else session.failedUpdates.set(input.id, { ...failed, input: remaining })
        }
        session.saveError = session.failedUpdates.values().next().value?.error ?? null
        return updated
      } catch (cause) {
        session.saveError = errorMessage(cause)
        session.failedUpdates.set(input.id, {
          input: { ...session.failedUpdates.get(input.id)?.input, ...input }, error: session.saveError
        })
        return null
      } finally { publish() }
    }), [enqueue, publish, session])

  const remove = useCallback((id: string): Promise<boolean> => enqueue(async () => {
    try {
      await invoke('annotations:delete', { id })
      session.annotations = session.annotations.filter((entry) => entry.id !== id)
      session.failedUpdates.delete(id)
      session.saveError = session.failedUpdates.values().next().value?.error ?? null
      return true
    } catch (cause) {
      session.saveError = errorMessage(cause)
      return false
    } finally { publish() }
  }), [enqueue, publish, session])

  const retryUpdates = useCallback(async (): Promise<void> => {
    for (const pending of [...session.failedUpdates.values()]) await update(pending.input)
  }, [session, update])
  const flush = useCallback(async (): Promise<void> => {
    let queue: Promise<void>
    do { queue = session.queue; await queue } while (queue !== session.queue)
    const error = session.saveError ?? session.loadError
    if (error !== null) throw new Error(error)
  }, [session])
  const { annotations, loading, error } = snapshot.session === session
    ? snapshot
    : { annotations: [] as Annotation[], loading: true, error: null }

  const byPage = useMemo(() => {
    const map = new Map<number, Annotation[]>()
    for (const annotation of annotations) {
      const list = map.get(annotation.page)
      if (list === undefined) {
        map.set(annotation.page, [annotation])
      } else {
        list.push(annotation)
      }
    }
    for (const list of map.values()) {
      list.sort((a, b) => {
        const ay = a.rects[0]?.y ?? 0
        const by = b.rects[0]?.y ?? 0
        return ay - by
      })
    }
    return map
  }, [annotations])

  return { annotations, byPage, loading, error, flush, retryUpdates, hasUnsavedUpdates: session.failedUpdates.size > 0, create, update, remove }
}

export const HIGHLIGHT_COLORS: readonly HighlightColor[] = [
  'yellow',
  'green',
  'pink',
  'blue'
]
