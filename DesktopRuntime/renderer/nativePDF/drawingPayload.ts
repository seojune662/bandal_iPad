import type { DrawingShape } from '../../upstream/src/shared/types/drawing'
import { strokePath } from '../../upstream/src/renderer/src/features/ink/inkGeometry'

/** Versioned ink is rendered from its measured points by the native renderer.
 * Expanding those points into SVG here duplicates work and makes every scene
 * update much larger. Historical ink still needs its original desktop path. */
export function nativePDFDrawingPayload<T extends DrawingShape>(drawing: T, aspect: number): T & { nativePath?: string } {
  if ((drawing.kind !== 'ink' && drawing.kind !== 'highlighter') || drawing.data.inkVersion === 2 || drawing.data.inkVersion === 3 || drawing.data.inkVersion === 4 || drawing.data.inkVersion === 5) return drawing
  return { ...drawing, nativePath: strokePath(drawing.data.points ?? [], drawing.style, aspect, drawing.kind === 'highlighter') }
}
