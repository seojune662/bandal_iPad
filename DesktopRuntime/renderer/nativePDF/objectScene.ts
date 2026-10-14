import type { DrawingShape, DrawingStyle, DrawingBox, DrawingPoint } from '../../upstream/src/shared/types/drawing'
import { strokePath } from '../../upstream/src/renderer/src/features/ink/inkGeometry'

interface SceneInput {
  shapes: readonly DrawingShape[]
  aspect: number
  selectedId: string | null
  editingId: string | null
  preview: { kind: string; data: { box: DrawingBox; points?: DrawingPoint[] }; style: DrawingStyle } | null
}
export interface NativeObjectScene { objects: unknown[]; selection: DrawingBox | null; resizable: boolean; textHandles: boolean }

/** Exposes the original object's LOCAL editing state. Only normalized model
 * data crosses this seam; native pen geometry never reads browser positions. */
export function publishNativePDFScene(svg: SVGSVGElement | null, input: SceneInput): void {
  if (!svg?.closest('[data-native-pdf="true"]')) return
  const selection = input.shapes.find(shape => shape.id === input.selectedId)
  const objects = input.shapes.filter(shape => shape.id !== input.editingId).map(shape => {
    if (shape.kind !== 'ink' && shape.kind !== 'highlighter') return shape
    const points = shape.data.points ?? []
    const nativePath = strokePath(points, shape.style, input.aspect, shape.kind === 'highlighter', shape.data.inkVersion)
    return { ...shape, nativePath }
  })
  if (input.preview) objects.push({ ...input.preview, id: 'native-object-preview', createdAt: '', updatedAt: '' } as DrawingShape)
  svg.dispatchEvent(new CustomEvent<NativeObjectScene>('bandal-native-pdf-object-scene', { bubbles: true, detail: {
    objects, selection: selection?.data.box ?? null,
    resizable: !!selection && !['line', 'arrow', 'ink', 'highlighter'].includes(selection.kind), textHandles: selection?.kind === 'textbox'
  } }))
}
