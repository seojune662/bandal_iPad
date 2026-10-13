import type { StoreApi, UseBoundStore } from 'zustand'
import type { Drawing } from '../../../../../shared/types/drawing'
import {
  drawingFileKey,
  useInkToolStore,
  type InkHistoryAction,
  type InkTool,
  type InkToolStore
} from '../../ink/inkToolStore'

export type PdfDrawingTool = InkTool
export type DrawingHistoryAction = InkHistoryAction<Drawing>

type PdfToolStore = InkToolStore<Drawing>

export { drawingFileKey }

/** PDF compatibility name backed by the surface-independent ink store. */
export const usePdfToolStore = useInkToolStore as unknown as UseBoundStore<StoreApi<PdfToolStore>>

/** Preserve older text edits and creation actions when undo restores a new row. */
export function remapDrawingHistoryIds(fileKey: string, ids: ReadonlyMap<string, string>): void {
  usePdfToolStore.setState((state) => {
    const history = state.histories[fileKey]
    if (history === undefined) return state
    const remap = (action: DrawingHistoryAction): DrawingHistoryAction => ({
      ...action,
      drawings: action.drawings.map((drawing) => {
        const id = ids.get(drawing.id)
        return id === undefined ? drawing : { ...drawing, id }
      })
    })
    return {
      histories: {
        ...state.histories,
        [fileKey]: { undo: history.undo.map(remap), redo: history.redo.map(remap) }
      }
    }
  })
}
