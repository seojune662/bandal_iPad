import { fileURLToPath } from 'node:url'

const inkSuffix = '/src/renderer/src/features/ink/InkLayer.tsx'
const samples = fileURLToPath(new URL('./samples.ts', import.meta.url))
const persistence = fileURLToPath(new URL('./persistence.ts', import.meta.url))
const drawingsSuffix = '/src/renderer/src/features/pdf/tools/useDrawings.ts'
const canvasSuffix = '/src/renderer/src/features/canvas/CanvasTab.tsx'
const queueSuffix = '/src/renderer/src/features/canvas/canvasSaveQueue.ts'

function replaceExactly(source, original, replacement, count = 1) {
  const matches = source.split(original).length - 1
  if (matches !== count) throw new Error(`iPad Pencil adapter: expected ${count} source anchor, found ${matches}: ${original.slice(0, 90)}`)
  return source.split(original).join(replacement)
}

/** Only event ownership and sampling change; original component markup, tools,
 * geometry, history, styling and persistence remain the desktop implementation. */
export function transformInkLayer(source) {
  let code = `import { pencilSamples, pencilPressure, acceptsInkPointer } from ${JSON.stringify(samples)}\n` + source
  code = replaceExactly(code, 'interface PointerSample {', 'interface PointerSample {\n  pointerType?: string')
  code = replaceExactly(code, `return svg === null || !surfaceReady || !hasMeasuredBounds(svg)
      ? null
      : normalizedPoint(
        svg,
        sample.clientX,
        sample.clientY,
        sample.pressure,
        clamp
      )`, `return pencilPressure(svg === null || !surfaceReady || !hasMeasuredBounds(svg)
      ? null
      : normalizedPoint(
        svg,
        sample.clientX,
        sample.clientY,
        sample.pressure,
        clamp
      ), sample)`)
  code = replaceExactly(code, 'const pendingSample = useRef<PointerSample | null>(null)', 'const pendingSample = useRef<PointerSample[]>([])')
  code = replaceExactly(code, 'pendingSample.current = null', 'pendingSample.current = []', 3)
  code = replaceExactly(code, 'if (sample !== null) processSample(sample)', 'for (const point of sample) processSample(point)', 2)
  code = replaceExactly(code, 'if (!interactive || event.button !== 0) return',
    'if (!interactive || event.button !== 0 || !acceptsInkPointer(event, gestureRef.current?.pointerId)) return', 2)
  code = replaceExactly(code, 'if (gestureRef.current === null) return',
    'if (gestureRef.current === null || !acceptsInkPointer(event, gestureRef.current.pointerId)) return')
  const sampleAssignment = `pendingSample.current = {
      pointerId: event.pointerId,
      clientX: event.clientX,
      clientY: event.clientY,
      pressure: event.pressure
    }`
  code = replaceExactly(code, sampleAssignment, 'pendingSample.current.push(...pencilSamples(event.nativeEvent))', 2)
  code = replaceExactly(code, `const handlePointerUp = useCallback((event: ReactPointerEvent<SVGSVGElement>): void => {
    pendingSample`, `const handlePointerUp = useCallback((event: ReactPointerEvent<SVGSVGElement>): void => {
    if (gestureRef.current === null || !acceptsInkPointer(event, gestureRef.current.pointerId)) return
    pendingSample`)
  code = replaceExactly(code, `const handlePointerCancel = useCallback((): void => {
    pendingSample.current = []
    if (pointerFrame.current !== null) cancelAnimationFrame(pointerFrame.current)
    pointerFrame.current = null
    setGesture(null)
  }, [setGesture])`, `const handlePointerCancel = useCallback((event: ReactPointerEvent<SVGSVGElement>): void => {
    if (gestureRef.current === null || !acceptsInkPointer(event, gestureRef.current.pointerId)) return
    flushPointerFrame()
    const interrupted = gestureRef.current
    setGesture(null)
    if (interrupted?.kind === 'stroke') commitGesture(interrupted)
  }, [commitGesture, flushPointerFrame, setGesture])`)
  return code
}

export function transformDrawingPersistence(source) {
  let code = `import { registerNativeInk, markNativeInkDirty } from ${JSON.stringify(persistence)}\n` + source
  code = replaceExactly(code, 'session.pending += 1', 'markNativeInkDirty()\n    session.pending += 1')
  code = replaceExactly(code, '  const addPreview = useCallback((', `  useEffect(() => registerNativeInk({ key: fileKey, courseId, relPath }, flush), [fileKey, courseId, relPath, flush])

  const addPreview = useCallback((`)
  return code
}

export function transformCanvasPersistence(source) {
  let code = `import { registerNativeInk } from ${JSON.stringify(persistence)}\n` + source
  code = replaceExactly(code, '  const saveQueue = useMemo(() => createCanvasSaveQueue(setSaveState), [])', `  const saveQueue = useMemo(() => createCanvasSaveQueue(setSaveState), [])
  useEffect(() => registerNativeInk({ key: surfaceKey, courseId: initialBoard.courseId, relPath: 'canvas:' + initialBoard.id }, saveQueue.flush), [surfaceKey, initialBoard.courseId, initialBoard.id, saveQueue])`)
  return code
}

export function transformCanvasQueue(source) {
  let code = `import { markNativeInkDirty } from ${JSON.stringify(persistence)}\n` + source
  code = replaceExactly(code, '    const job: SaveJob =', '    markNativeInkDirty()\n    const job: SaveJob =')
  code = replaceExactly(code, '    pending++; publish()', '    markNativeInkDirty()\n    pending++; publish()')
  return code
}

export default function pencilInputPlugin() {
  return {
    name: 'bandal-ipad-pencil-input',
    enforce: 'pre',
    transform(code, id) {
      const path = id.replaceAll('\\', '/')
      const transform = path.endsWith(inkSuffix) ? transformInkLayer
        : path.endsWith(drawingsSuffix) ? transformDrawingPersistence
          : path.endsWith(canvasSuffix) ? transformCanvasPersistence
            : path.endsWith(queueSuffix) ? transformCanvasQueue : undefined
      return transform ? { code: transform(code), map: null } : null
    }
  }
}
