import { useCallback, useEffect, useRef, useState } from 'react'
import type {
  MaterialBacklinks,
  MaterialLinkRecord
} from '../../../../shared/types/link'
import { invoke, onPush } from '../../lib/ipc'

const MATERIAL_CONNECTIONS_REFRESH_EVENT =
  'bandal:material-connections-refresh'

const EMPTY_BACKLINKS: MaterialBacklinks = { notes: [], boards: [] }

export interface MaterialConnectionsState {
  backlinks: MaterialBacklinks
  outgoing: MaterialLinkRecord[]
  incoming: MaterialLinkRecord[]
  loading: boolean
  error: Error | null
  remove: (id: string) => Promise<void>
  refresh: () => Promise<void>
}

interface MaterialConnectionsRefreshDetail {
  courseId: string
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error))
}

/** Refreshes every mounted connection view for one course. */
export function requestMaterialConnectionsRefresh(courseId: string): void {
  window.dispatchEvent(
    new CustomEvent<MaterialConnectionsRefreshDetail>(
      MATERIAL_CONNECTIONS_REFRESH_EVENT,
      { detail: { courseId } }
    )
  )
}

/** 위 이벤트의 구독 — 반환값으로 해제한다. */
export function subscribeMaterialConnectionsRefresh(
  courseId: string,
  listener: () => void
): () => void {
  const handle = (event: Event): void => {
    if (!(event instanceof CustomEvent)) return
    const detail = event.detail as Partial<MaterialConnectionsRefreshDetail>
    if (detail.courseId === courseId) listener()
  }
  window.addEventListener(MATERIAL_CONNECTIONS_REFRESH_EVENT, handle)
  return () => {
    window.removeEventListener(MATERIAL_CONNECTIONS_REFRESH_EVENT, handle)
  }
}

export function useMaterialConnections(
  courseId: string,
  relPath: string
): MaterialConnectionsState {
  const [backlinks, setBacklinks] =
    useState<MaterialBacklinks>(EMPTY_BACKLINKS)
  const [outgoing, setOutgoing] = useState<MaterialLinkRecord[]>([])
  const [incoming, setIncoming] = useState<MaterialLinkRecord[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<Error | null>(null)
  const requestSequence = useRef(0)

  const refresh = useCallback(async (): Promise<void> => {
    const sequence = ++requestSequence.current
    setLoading(true)
    setError(null)
    try {
      const [nextBacklinks, nextConnections] = await Promise.all([
        invoke('links:forMaterial', { courseId, relPath }),
        invoke('links:listFor', { courseId, relPath })
      ])
      if (sequence !== requestSequence.current) return
      setBacklinks(nextBacklinks)
      setOutgoing(nextConnections.outgoing)
      setIncoming(nextConnections.incoming)
    } catch (caught) {
      if (sequence !== requestSequence.current) return
      const nextError = asError(caught)
      console.error('[Bandal] 자료 연결을 불러오지 못했습니다.', nextError)
      setBacklinks(EMPTY_BACKLINKS)
      setOutgoing([])
      setIncoming([])
      setError(nextError)
    } finally {
      if (sequence === requestSequence.current) setLoading(false)
    }
  }, [courseId, relPath])

  useEffect(() => {
    void refresh()
    return () => {
      requestSequence.current += 1
    }
  }, [refresh])

  useEffect(() => {
    const stopMaterials = onPush('materials:changed', (payload) => {
      if (payload.courseId === courseId) void refresh()
    })
    const handleRefresh = (event: Event): void => {
      if (!(event instanceof CustomEvent)) return
      const detail = event.detail as Partial<MaterialConnectionsRefreshDetail>
      if (detail.courseId === courseId) void refresh()
    }
    window.addEventListener(MATERIAL_CONNECTIONS_REFRESH_EVENT, handleRefresh)
    return () => {
      stopMaterials()
      window.removeEventListener(
        MATERIAL_CONNECTIONS_REFRESH_EVENT,
        handleRefresh
      )
    }
  }, [courseId, refresh])

  const remove = useCallback(
    async (id: string): Promise<void> => {
      await invoke('links:remove', { courseId, id })
      setOutgoing((records) => records.filter((record) => record.id !== id))
      setIncoming((records) => records.filter((record) => record.id !== id))
      requestMaterialConnectionsRefresh(courseId)
    },
    [courseId]
  )

  return {
    backlinks,
    outgoing,
    incoming,
    loading,
    error,
    remove,
    refresh
  }
}
