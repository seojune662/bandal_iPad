import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react'
import type {
  CreateDrawingInput,
  Drawing,
  UpdateDrawingInput
} from '../../../../../shared/types/drawing'
import { invoke, onPush } from '../../../lib/ipc'
import {
  drawingFileKey,
  remapDrawingHistoryIds,
  usePdfToolStore,
  type DrawingHistoryAction
} from './toolStore'
import { instanceSurfaceKey } from '../../ink/inkToolStore'

export interface DrawingsApi {
  drawings: Drawing[]
  byPage: Map<number, Drawing[]>
  loading: boolean
  historyBusy: boolean
  canUndo: boolean
  canRedo: boolean
  error: string | null
  /** Resolve a temporary or restored row id while keeping an editor session alive. */
  resolveId?(id: string): string
  /** Wait for every queued save before reading persisted drawings for export. */
  flush?(): Promise<void>
  create(input: CreateDrawingInput): Promise<Drawing | null>
  update(input: UpdateDrawingInput): Promise<Drawing | null>
  /** 무음 보정(손상 박스 힐링) — undo 히스토리에 기록하지 않는다. */
  refine(input: UpdateDrawingInput): Promise<Drawing | null>
  remove(ids: string[]): Promise<boolean>
  undo(): Promise<void>
  redo(): Promise<void>
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  return '필기 내용을 저장하는 중 오류가 발생했어요.'
}

function sortDrawings(drawings: Drawing[]): Drawing[] {
  return [...drawings].sort((left, right) =>
    left.page - right.page || left.createdAt.localeCompare(right.createdAt)
  )
}

function inputFor(drawing: Drawing): CreateDrawingInput {
  return {
    courseId: drawing.courseId,
    relPath: drawing.relPath,
    page: drawing.page,
    kind: drawing.kind,
    data: drawing.data,
    style: drawing.style
  }
}

interface DrawingPreview {
  order: number
  apply(drawings: Drawing[]): Drawing[]
}

function temporaryDrawing(input: CreateDrawingInput): Drawing {
  const now = new Date().toISOString()
  return { ...input, id: `pending:${crypto.randomUUID()}`, createdAt: now, updatedAt: now }
}

interface DrawingSession {
  drawings: Drawing[]
  saved: Drawing[]
  previews: DrawingPreview[]
  order: number
  loading: boolean
  historyBusy: boolean
  error: string | null
  loadError: string | null
  saveError: string | null
  generation: number
  pending: number
  refreshRequested: boolean
  loadPending: boolean
  queue: Promise<void>
  ids: Map<string, string>
}

const EMPTY_DRAWINGS: Drawing[] = []

export function useDrawings(courseId: string, relPath: string): DrawingsApi {
  // A session owns its asynchronous work as well as its undo stack. Saving a
  // box in one file must never replace the newly opened file's drawings.
  const instanceId = useId()
  const fileKey = instanceSurfaceKey(drawingFileKey(courseId, relPath), instanceId)
  const session = useMemo<DrawingSession>(() => ({
    drawings: [], saved: [], previews: [], order: 0, loading: true, historyBusy: false, error: null,
    loadError: null, saveError: null,
    generation: 0, pending: 0, refreshRequested: false, loadPending: false,
    queue: Promise.resolve(), ids: new Map()
  }), [fileKey])
  const activeSessionRef = useRef<DrawingSession | null>(session)
  activeSessionRef.current = session
  const [snapshot, setSnapshot] = useState({ session, drawings: session.drawings,
    loading: session.loading, historyBusy: session.historyBusy, error: session.error })
  const publish = useCallback((): void => {
    session.error = session.saveError ?? session.loadError
    session.drawings = sortDrawings(session.previews.reduce(
      (drawings, preview) => preview.apply(drawings), session.saved
    ))
    if (activeSessionRef.current !== session) return
    setSnapshot({ session, drawings: session.drawings, loading: session.loading,
      historyBusy: session.historyBusy, error: session.error })
  }, [session])
  const current = snapshot.session === session ? snapshot : {
    drawings: EMPTY_DRAWINGS, loading: true, historyBusy: false, error: null
  }
  const { drawings, loading, historyBusy, error } = current
  const canUndo = usePdfToolStore((state) =>
    (state.histories[fileKey]?.undo.length ?? 0) > 0
  )
  const canRedo = usePdfToolStore((state) =>
    (state.histories[fileKey]?.redo.length ?? 0) > 0
  )

  const replace = useCallback((next: Drawing[]): void => {
    session.saved = sortDrawings(next)
    publish()
  }, [publish, session])
  const setError = useCallback((next: string | null): void => {
    session.saveError = next
    publish()
  }, [publish, session])

  const load = useCallback((initial: boolean): void => {
    if (session.pending > 0) {
      session.refreshRequested = true
      return
    }
    const generation = ++session.generation
    session.loadPending = true
    if (initial) {
      session.saved = []
      session.loading = true
      publish()
    }
    void invoke('drawings:listForFile', { courseId, relPath })
      .then((list) => {
        if (session.generation !== generation || activeSessionRef.current !== session) return
        session.loadPending = false
        session.saved = sortDrawings(list)
        session.loadError = null
        session.loading = false
        publish()
      })
      .catch((cause: unknown) => {
        if (session.generation !== generation || activeSessionRef.current !== session) return
        session.loadPending = false
        session.loadError = errorMessage(cause)
        session.loading = false
        publish()
      })
  }, [courseId, relPath, publish, session])

  useEffect(() => {
    activeSessionRef.current = session
    load(true)
    return () => {
      session.generation += 1
      if (activeSessionRef.current === session) activeSessionRef.current = null
      usePdfToolStore.getState().clearHistory(fileKey)
    }
  }, [fileKey, load, session])

  useEffect(() => onPush('materials:changed', ({ courseId: changedCourseId }) => {
    if (changedCourseId === courseId) load(false)
  }), [courseId, load])

  // Queue writes in the order the user made them. Each undo snapshot and
  // failure rollback then starts from the preceding *saved* box, and a late
  // response cannot overwrite a newer text edit or resurrect a deleted box.
  const enqueue = useCallback(<T,>(operation: () => Promise<T>): Promise<T> => {
    session.pending += 1
    session.generation += 1
    if (session.loading || session.loadPending) session.refreshRequested = true
    session.loadPending = false
    const result = session.queue.then(operation)
    session.queue = result.then(() => undefined, () => undefined).finally(() => {
      session.pending -= 1
      if (session.pending === 0 && session.refreshRequested && activeSessionRef.current === session) {
        session.refreshRequested = false
        load(false)
      }
    })
    return result
  }, [load, session])

  const resolveId = useCallback((id: string): string => {
    let resolved = id
    while (session.ids.has(resolved)) resolved = session.ids.get(resolved)!
    return resolved
  }, [session])

  const flush = useCallback(async (): Promise<void> => {
    let queue: Promise<void>
    do {
      queue = session.queue
      await queue
    } while (queue !== session.queue)
    if (session.error !== null) throw new Error(session.error)
  }, [session])

  const addPreview = useCallback((
    apply: DrawingPreview['apply'],
    order = ++session.order
  ): DrawingPreview => {
    const preview = { apply, order }
    session.previews.push(preview)
    session.previews.sort((left, right) => left.order - right.order)
    publish()
    return preview
  }, [publish, session])
  const dropPreview = useCallback((preview: DrawingPreview): void => {
    session.previews = session.previews.filter((entry) => entry !== preview)
    publish()
  }, [publish, session])
  const previewUpdate = useCallback((input: UpdateDrawingInput, order?: number): DrawingPreview => {
    const updatedAt = new Date().toISOString()
    return addPreview((drawings) => drawings.map((drawing) => drawing.id === resolveId(input.id) ? {
      ...drawing,
      data: input.data ?? drawing.data,
      style: input.style ?? drawing.style,
      updatedAt
    } : drawing), order)
  }, [addPreview, resolveId])
  const previewRemove = useCallback((ids: string[], order?: number): DrawingPreview =>
    addPreview((drawings) => {
      const resolved = new Set(ids.map(resolveId))
      return drawings.filter((drawing) => !resolved.has(drawing.id))
    }, order),
  [addPreview, resolveId])

  const createInternal = useCallback(async (
    input: CreateDrawingInput,
    recordHistory: boolean,
    optimistic?: { drawing: Drawing; preview: DrawingPreview },
    order?: number
  ): Promise<Drawing | null> => {
    const temporary = optimistic?.drawing ?? temporaryDrawing(input)
    const preview = optimistic?.preview ?? addPreview((drawings) =>
      drawings.some((drawing) => drawing.id === resolveId(temporary.id)) ? drawings : [...drawings, temporary], order)
    try {
      const created = await invoke('drawings:create', input)
      session.ids.set(temporary.id, created.id)
      replace([...session.saved.filter((drawing) => drawing.id !== created.id), created])
      if (recordHistory && activeSessionRef.current === session) {
        usePdfToolStore.getState().recordHistory(fileKey, { kind: 'remove', drawings: [created] })
      }
      setError(null)
      return created
    } catch (cause: unknown) {
      setError(errorMessage(cause))
      return null
    } finally {
      dropPreview(preview)
    }
  }, [addPreview, dropPreview, fileKey, replace, resolveId, session, setError])

  const updateInternal = useCallback(async (
    input: UpdateDrawingInput,
    recordHistory: boolean,
    optimistic?: DrawingPreview,
    order?: number
  ): Promise<Drawing | null> => {
    const id = resolveId(input.id)
    const before = session.saved.find((drawing) => drawing.id === id)
    const preview = optimistic ?? previewUpdate(input, order)
    try {
      if (before === undefined) return null
      const updated = await invoke('drawings:update', { ...input, id })
      replace(session.saved.map((drawing) => drawing.id === updated.id ? updated : drawing))
      if (recordHistory && activeSessionRef.current === session) {
        usePdfToolStore.getState().recordHistory(fileKey, { kind: 'update', drawings: [before] })
      }
      setError(null)
      return updated
    } catch (cause: unknown) {
      setError(errorMessage(cause))
      return null
    } finally {
      dropPreview(preview)
    }
  }, [dropPreview, fileKey, previewUpdate, replace, resolveId, session, setError])

  const removeInternal = useCallback(async (
    idsInput: string[],
    recordHistory: boolean,
    optimistic?: DrawingPreview,
    order?: number
  ): Promise<{ ok: boolean; removed: Drawing[] }> => {
    const idSet = new Set(idsInput.map(resolveId))
    const removed = session.saved.filter((drawing) => idSet.has(drawing.id))
    const preview = optimistic ?? previewRemove(idsInput, order)
    try {
      if (removed.length === 0) return { ok: true, removed: [] }
      await invoke('drawings:delete', { ids: removed.map((drawing) => drawing.id) })
      replace(session.saved.filter((drawing) => !idSet.has(drawing.id)))
      if (recordHistory && activeSessionRef.current === session) {
        usePdfToolStore.getState().recordHistory(fileKey, { kind: 'restore', drawings: removed })
      }
      setError(null)
      return { ok: true, removed }
    } catch (cause: unknown) {
      setError(errorMessage(cause))
      return { ok: false, removed: [] }
    } finally {
      dropPreview(preview)
    }
  }, [dropPreview, fileKey, previewRemove, replace, resolveId, session, setError])

  const create = useCallback((input: CreateDrawingInput): Promise<Drawing | null> => {
    if (input.courseId !== courseId || input.relPath !== relPath) return Promise.resolve(null)
    const drawing = temporaryDrawing(input)
    const preview = addPreview((drawings) =>
      drawings.some((entry) => entry.id === resolveId(drawing.id)) ? drawings : [...drawings, drawing])
    return enqueue(() => createInternal(input, true, { drawing, preview }))
  }, [addPreview, courseId, createInternal, enqueue, relPath, resolveId])
  const update = useCallback((input: UpdateDrawingInput): Promise<Drawing | null> => {
    const preview = previewUpdate(input)
    return enqueue(() => updateInternal(input, true, preview))
  }, [enqueue, previewUpdate, updateInternal])
  const refine = useCallback((input: UpdateDrawingInput): Promise<Drawing | null> => {
    // Healing is geometry-only: a box measured before a text save cannot
    // reintroduce that earlier text or its inline formatting.
    const refineData = (drawings: Drawing[]): UpdateDrawingInput => {
      const current = drawings.find((drawing) => drawing.id === resolveId(input.id))
      const data = current?.kind === 'textbox' && input.data?.box !== undefined
        ? { ...current.data, box: input.data.box }
        : input.data
      return { ...input, ...(data === undefined ? {} : { data }) }
    }
    const preview = addPreview((drawings) => {
      const patch = refineData(drawings)
      return drawings.map((drawing) => drawing.id === resolveId(input.id) ? {
        ...drawing, data: patch.data ?? drawing.data, style: patch.style ?? drawing.style
      } : drawing)
    })
    return enqueue(() => updateInternal(refineData(session.saved), false, preview))
  }, [addPreview, enqueue, resolveId, session, updateInternal])
  const remove = useCallback((ids: string[]): Promise<boolean> => {
    const preview = previewRemove(ids)
    return enqueue(async () => (await removeInternal(ids, true, preview)).ok)
  }, [enqueue, previewRemove, removeInternal])

  const executeHistory = useCallback(async (
    action: DrawingHistoryAction,
    order: number
  ): Promise<DrawingHistoryAction | null> => {
    if (action.kind === 'remove') {
      const result = await removeInternal(
        action.drawings.map((drawing) => drawing.id),
        false, undefined, order
      )
      return result.ok ? { kind: 'restore', drawings: result.removed } : null
    }
    if (action.kind === 'restore') {
      const created: Drawing[] = []
      for (const drawing of action.drawings) {
        const restored = await createInternal(inputFor(drawing), false, undefined, order)
        if (restored === null) {
          const failure = session.error
          if (created.length > 0) {
            await removeInternal(created.map((entry) => entry.id), false, undefined, order)
          }
          setError(failure)
          return null
        }
        created.push(restored)
      }
      const ids = new Map(action.drawings.map((drawing, index) => [drawing.id, created[index]!.id]))
      for (const [oldId, newId] of ids) session.ids.set(oldId, newId)
      if (activeSessionRef.current === session) remapDrawingHistoryIds(fileKey, ids)
      return { kind: 'remove', drawings: created }
    }

    const previous = action.drawings
      .map((target) => session.saved.find((drawing) => drawing.id === resolveId(target.id)))
      .filter((drawing): drawing is Drawing => drawing !== undefined)
    if (previous.length !== action.drawings.length) return null
    const changed: Drawing[] = []
    for (const target of action.drawings) {
      const updated = await updateInternal({
        id: target.id,
        data: target.data,
        style: target.style
      }, false, undefined, order)
      if (updated === null) {
        const failure = session.error
        for (const before of changed) {
          await updateInternal({ id: before.id, data: before.data, style: before.style }, false, undefined, order)
        }
        setError(failure)
        return null
      }
      changed.push(previous.find((drawing) => drawing.id === updated.id)!)
    }
    return { kind: 'update', drawings: previous }
  }, [createInternal, fileKey, removeInternal, resolveId, session, setError, updateInternal])

  const runHistory = useCallback(async (direction: 'undo' | 'redo'): Promise<void> => {
    // A ref-backed lock also rejects two shortcuts in the same React render.
    if (session.historyBusy) return
    session.historyBusy = true
    const order = ++session.order
    publish()
    try {
      await enqueue(async () => {
        if (activeSessionRef.current !== session) return
        const store = usePdfToolStore.getState()
        const action = direction === 'undo' ? store.beginUndo(fileKey) : store.beginRedo(fileKey)
        if (action === null) return
        const inverse = await executeHistory(action, order)
        if (activeSessionRef.current !== session) return
        if (direction === 'undo') {
          if (inverse === null) store.cancelUndo(fileKey, action)
          else store.finishUndo(fileKey, inverse)
        } else {
          if (inverse === null) store.cancelRedo(fileKey, action)
          else store.finishRedo(fileKey, inverse)
        }
      })
    } finally {
      session.historyBusy = false
      publish()
    }
  }, [enqueue, executeHistory, fileKey, publish, session])
  const undo = useCallback(() => runHistory('undo'), [runHistory])
  const redo = useCallback(() => runHistory('redo'), [runHistory])

  const byPage = useMemo(() => {
    const result = new Map<number, Drawing[]>()
    for (const drawing of drawings) {
      const page = result.get(drawing.page)
      if (page === undefined) result.set(drawing.page, [drawing])
      else page.push(drawing)
    }
    return result
  }, [drawings])

  return useMemo(() => ({
    drawings,
    byPage,
    loading,
    historyBusy,
    canUndo,
    canRedo,
    error,
    resolveId,
    flush,
    create,
    update,
    refine,
    remove,
    undo,
    redo
  }), [drawings, byPage, loading, historyBusy, canUndo, canRedo, error, resolveId, flush, create, update, refine, remove, undo, redo])
}
