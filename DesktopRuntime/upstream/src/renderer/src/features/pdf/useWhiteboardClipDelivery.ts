import { useCallback, useState, type RefObject } from 'react'
import type { DrawingClipSource } from '../../../../shared/types/drawing'
import type { PersonalBoard } from '../../../../shared/types/whiteboard'
import { showToast } from '../../app/toast'
import { invoke } from '../../lib/ipc'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { requestClipDelivery } from '../canvas/clipDelivery'
import { descriptorFor } from '../workspace/tabIdentity'
import type { ContentPoint } from './popovers'

export type WhiteboardDestination =
  | { kind: 'create' }
  | { kind: 'direct'; board: PersonalBoard }
  | { kind: 'choose'; boards: PersonalBoard[] }

export function destinationForBoards(
  boards: PersonalBoard[]
): WhiteboardDestination {
  if (boards.length === 0) return { kind: 'create' }
  const board = boards[0]
  if (boards.length === 1 && board !== undefined) return { kind: 'direct', board }
  return { kind: 'choose', boards }
}

export interface WhiteboardPickerState {
  source: DrawingClipSource
  boards: PersonalBoard[]
  position: ContentPoint
}

interface WhiteboardClipDelivery {
  picker: WhiteboardPickerState | null
  send: (
    source: DrawingClipSource,
    clientX: number,
    clientY: number
  ) => Promise<void>
  choose: (board: PersonalBoard) => void
  create: () => Promise<void>
  dismiss: () => void
}

export function useWhiteboardClipDelivery(
  courseId: string,
  contentRef: RefObject<HTMLDivElement>
): WhiteboardClipDelivery {
  const [picker, setPicker] = useState<WhiteboardPickerState | null>(null)

  const deliver = useCallback((board: PersonalBoard, source: DrawingClipSource): void => {
    requestClipDelivery(board.id, source)
    useWorkspaceStore.getState().openTab(
      descriptorFor('whiteboard', { courseId, boardId: board.id })
    )
    showToast(`${board.title}에 붙였어요`)
  }, [courseId])

  const createAndDeliver = useCallback(async (
    source: DrawingClipSource
  ): Promise<void> => {
    const board = await invoke('canvas:create', { courseId })
    deliver(board, source)
  }, [courseId, deliver])

  const send = useCallback(async (
    source: DrawingClipSource,
    clientX: number,
    clientY: number
  ): Promise<void> => {
    const content = contentRef.current
    if (content === null) return
    const contentBox = content.getBoundingClientRect()
    const position = {
      left: clientX - contentBox.left,
      top: clientY - contentBox.top + 6
    }

    try {
      const destination = destinationForBoards(
        await invoke('canvas:list', { courseId })
      )
      if (destination.kind === 'choose') {
        setPicker({ source, boards: destination.boards, position })
      } else if (destination.kind === 'direct') {
        setPicker(null)
        deliver(destination.board, source)
      } else {
        setPicker(null)
        await createAndDeliver(source)
      }
    } catch (error) {
      console.error('[Bandal] 화이트보드로 보내지 못했습니다.', error)
      showToast('화이트보드로 보내지 못했습니다.', 'danger')
    }
  }, [contentRef, courseId, createAndDeliver, deliver])

  const choose = useCallback((board: PersonalBoard): void => {
    if (picker === null) return
    const { source } = picker
    setPicker(null)
    deliver(board, source)
  }, [deliver, picker])

  const create = useCallback(async (): Promise<void> => {
    if (picker === null) return
    const { source } = picker
    setPicker(null)
    try {
      await createAndDeliver(source)
    } catch (error) {
      console.error('[Bandal] 화이트보드로 보내지 못했습니다.', error)
      showToast('화이트보드로 보내지 못했습니다.', 'danger')
    }
  }, [createAndDeliver, picker])

  const dismiss = useCallback((): void => setPicker(null), [])

  return { picker, send, choose, create, dismiss }
}
