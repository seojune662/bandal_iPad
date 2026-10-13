import { create } from 'zustand'
import type {
  DrawingColor,
  DrawingShape
} from '../../../../shared/types/drawing'

export type InkTool =
  | 'select'
  | 'pen'
  | 'highlighter'
  | 'eraser'
  | 'text'
  | 'rect'
  | 'ellipse'
  | 'arrow'
  | 'line'

export interface InkToolState {
  activeTool: InkTool
  color: DrawingColor
  /** Fraction of the surface width. */
  width: number
  opacity: number
}

export type InkHistoryAction<TShape extends DrawingShape = DrawingShape> =
  | { kind: 'remove'; drawings: TShape[] }
  | { kind: 'restore'; drawings: TShape[] }
  | { kind: 'update'; drawings: TShape[] }

export interface InkHistory<TShape extends DrawingShape = DrawingShape> {
  undo: InkHistoryAction<TShape>[]
  redo: InkHistoryAction<TShape>[]
}

export interface InkToolStore<TShape extends DrawingShape = DrawingShape> extends InkToolState {
  histories: Record<string, InkHistory<TShape>>
  setActiveTool: (tool: InkTool) => void
  setColor: (color: DrawingColor) => void
  setWidth: (width: number) => void
  setOpacity: (opacity: number) => void
  recordHistory: (surfaceKey: string, action: InkHistoryAction<TShape>) => void
  /** Drops a surface's undo/redo stacks (panel unmount cleanup). */
  clearHistory: (surfaceKey: string) => void
  beginUndo: (surfaceKey: string) => InkHistoryAction<TShape> | null
  finishUndo: (surfaceKey: string, inverse: InkHistoryAction<TShape>) => void
  cancelUndo: (surfaceKey: string, action: InkHistoryAction<TShape>) => void
  beginRedo: (surfaceKey: string) => InkHistoryAction<TShape> | null
  finishRedo: (surfaceKey: string, inverse: InkHistoryAction<TShape>) => void
  cancelRedo: (surfaceKey: string, action: InkHistoryAction<TShape>) => void
}

const HISTORY_LIMIT = 100

/** PDF compatibility key; every history API otherwise accepts any opaque surface key. */
export function drawingFileKey(courseId: string, relPath: string): string {
  return JSON.stringify([courseId, relPath])
}

/**
 * Same file, different panel → different undo stack. Without the instance
 * dimension, two duplicate views of one PDF share a history and undo in one
 * panel erases strokes drawn in the other.
 */
export function instanceSurfaceKey(fileKey: string, instanceId: string): string {
  return `${fileKey}#${instanceId}`
}

function historyFor<TShape extends DrawingShape>(
  histories: Record<string, InkHistory<TShape>>,
  surfaceKey: string
): InkHistory<TShape> {
  return histories[surfaceKey] ?? { undo: [], redo: [] }
}

function capped<TShape extends DrawingShape>(
  actions: InkHistoryAction<TShape>[]
): InkHistoryAction<TShape>[] {
  return actions.length > HISTORY_LIMIT ? actions.slice(-HISTORY_LIMIT) : actions
}

export const useInkToolStore = create<InkToolStore>()((set, get) => ({
  activeTool: 'select',
  color: 'ink',
  width: 0.004,
  opacity: 0.95,
  histories: {},

  setActiveTool: (activeTool) => set({ activeTool }),
  setColor: (color) => set({ color }),
  setWidth: (width) => set({ width: Math.min(0.04, Math.max(0.001, width)) }),
  setOpacity: (opacity) => set({ opacity: Math.min(1, Math.max(0.05, opacity)) }),

  clearHistory: (surfaceKey) => {
    set((state) => {
      if (!(surfaceKey in state.histories)) return state
      const { [surfaceKey]: _dropped, ...rest } = state.histories
      return { histories: rest }
    })
  },

  recordHistory: (surfaceKey, action) => {
    set((state) => {
      const history = historyFor(state.histories, surfaceKey)
      return {
        histories: {
          ...state.histories,
          [surfaceKey]: { undo: capped([...history.undo, action]), redo: [] }
        }
      }
    })
  },

  beginUndo: (surfaceKey) => {
    const history = historyFor(get().histories, surfaceKey)
    const action = history.undo[history.undo.length - 1]
    if (action === undefined) return null
    set((state) => ({
      histories: {
        ...state.histories,
        [surfaceKey]: {
          ...historyFor(state.histories, surfaceKey),
          undo: history.undo.slice(0, -1)
        }
      }
    }))
    return action
  },

  finishUndo: (surfaceKey, inverse) => {
    set((state) => {
      const history = historyFor(state.histories, surfaceKey)
      return {
        histories: {
          ...state.histories,
          [surfaceKey]: { ...history, redo: capped([...history.redo, inverse]) }
        }
      }
    })
  },

  cancelUndo: (surfaceKey, action) => {
    set((state) => {
      const history = historyFor(state.histories, surfaceKey)
      return {
        histories: {
          ...state.histories,
          [surfaceKey]: { ...history, undo: capped([...history.undo, action]) }
        }
      }
    })
  },

  beginRedo: (surfaceKey) => {
    const history = historyFor(get().histories, surfaceKey)
    const action = history.redo[history.redo.length - 1]
    if (action === undefined) return null
    set((state) => ({
      histories: {
        ...state.histories,
        [surfaceKey]: {
          ...historyFor(state.histories, surfaceKey),
          redo: history.redo.slice(0, -1)
        }
      }
    }))
    return action
  },

  finishRedo: (surfaceKey, inverse) => {
    set((state) => {
      const history = historyFor(state.histories, surfaceKey)
      return {
        histories: {
          ...state.histories,
          [surfaceKey]: { ...history, undo: capped([...history.undo, inverse]) }
        }
      }
    })
  },

  cancelRedo: (surfaceKey, action) => {
    set((state) => {
      const history = historyFor(state.histories, surfaceKey)
      return {
        histories: {
          ...state.histories,
          [surfaceKey]: { ...history, redo: capped([...history.redo, action]) }
        }
      }
    })
  }
}))
