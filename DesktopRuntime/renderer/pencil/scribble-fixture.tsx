import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { InkLayer } from '../../upstream/src/renderer/src/features/ink/InkLayer'
import { PdfToolbar } from '../../upstream/src/renderer/src/features/pdf/PdfToolbar'
import { usePdfToolStore } from '../../upstream/src/renderer/src/features/pdf/tools/toolStore'
import type { DrawingShape } from '../../upstream/src/shared/types/drawing'
import type { DrawingsApi } from '../../upstream/src/renderer/src/features/pdf/tools/useDrawings'
import { installScribblePolicy } from './scribble'

const trace = { created: [] as DrawingShape[], regions: [] as unknown[], jumped: [] as number[] }
Object.assign(window, { scribbleTrace: trace })
installScribblePolicy(document, async value => { trace.regions.push(value) })
function Fixture(): JSX.Element {
  const [shapes, setShapes] = useState<DrawingShape[]>([])
  const tool = usePdfToolStore()
  const api = { drawings: shapes, byPage: new Map(), error: null, canUndo: false, canRedo: false } as unknown as DrawingsApi
  return <div className="pdf-tab">
    <input aria-label="normal search" />
    <PdfToolbar courseId="fixture" relPath="fixture.pdf" drawingsApi={api}
      currentPage={1} numPages={30} zoomPercent={100} isPreviewOpen={false} isRailOpen={false} annotationCount={0}
      pageNoteCount={0} pageNotePaired={false} pageNoteSyncEnabled={false}
      onJumpToPage={page => trace.jumped.push(page)} onZoomIn={() => undefined} onZoomOut={() => undefined}
      onZoomFit={() => undefined} onTogglePreview={() => undefined} onToggleRail={() => undefined}
      onOpenPageNotes={() => undefined} onTogglePageNoteSync={() => undefined} />
    <div style={{ position: 'relative', width: 600, height: 700 }}>
      <InkLayer aspect={7 / 6} baseWidthPx={600} tool={tool} shapes={shapes} ariaLabel="drawing page"
        onCreate={input => { const shape = { ...input, id: `ink-${trace.created.length}`, createdAt: '', updatedAt: '' }; trace.created.push(shape); setShapes(current => [...current, shape]) }}
        onUpdate={() => undefined} onRemove={() => undefined} />
    </div>
  </div>
}
createRoot(document.getElementById('root')!).render(<Fixture />)
