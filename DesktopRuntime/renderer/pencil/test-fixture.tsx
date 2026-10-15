// Only loaded by test.mjs. Never imported by the application entry point.
import { Profiler, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { InkLayer } from '../../upstream/src/renderer/src/features/ink/InkLayer'
import type { DrawingShape } from '../../upstream/src/shared/types/drawing'
import { installPencilNavigation } from './navigation'

declare global {
  interface Window {
    __pencilTest: { created: DrawingShape[]; zooms: number[]; commits: number }
  }
}
window.__pencilTest = { created: [], zooms: [], commits: 0 }
installPencilNavigation()

function Fixture(): JSX.Element {
  const [shapes, setShapes] = useState<DrawingShape[]>([])
  return <div className="pdf-scroller" style={{ width: 600, height: 400, overflow: 'auto' }}
    ref={node => { if (node) node.onwheel = event => { if (event.ctrlKey) { event.preventDefault(); window.__pencilTest.zooms.push(event.deltaY) } } }}>
    <div data-pdf-page="1" style={{ width: 600, height: 1800 }}>
      <div style={{ width: 600, height: 900 }}>
        <InkLayer aspect={1.5} baseWidthPx={600} ariaLabel="real desktop ink fixture"
          className="test-ink" shapes={shapes} tool={{ activeTool: 'pen', width: 0.003, color: 'ink', opacity: 1 }}
          onCreate={input => {
            const shape = { ...input, id: `fixture-${window.__pencilTest.created.length}`, createdAt: '', updatedAt: '' }
            window.__pencilTest.created.push(shape); setShapes(current => [...current, shape])
          }} onUpdate={() => undefined} onRemove={() => undefined} />
      </div>
    </div>
  </div>
}
const style = document.createElement('style')
style.textContent = '.test-ink { width:600px; height:900px; background:white; display:block }'
document.head.append(style)
createRoot(document.getElementById('root')!).render(<Profiler id="ink" onRender={() => window.__pencilTest.commits++}><Fixture /></Profiler>)
