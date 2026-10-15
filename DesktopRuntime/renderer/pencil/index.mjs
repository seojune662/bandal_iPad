import { fileURLToPath } from 'node:url'

const inkSuffix = '/src/renderer/src/features/ink/InkLayer.tsx'
const samples = fileURLToPath(new URL('./samples.ts', import.meta.url))
const livePreview = fileURLToPath(new URL('./livePreview.ts', import.meta.url))
const eraserHitCache = fileURLToPath(new URL('./eraserHitCache.ts', import.meta.url))
const persistence = fileURLToPath(new URL('./persistence.ts', import.meta.url))
const drawingsSuffix = '/src/renderer/src/features/pdf/tools/useDrawings.ts'
const canvasSuffix = '/src/renderer/src/features/canvas/CanvasTab.tsx'
const queueSuffix = '/src/renderer/src/features/canvas/canvasSaveQueue.ts'

function replaceExactly(source, original, replacement, count = 1) {
  const matches = source.split(original).length - 1
  if (matches !== count) throw new Error(`iPad Pencil adapter: expected ${count} source anchor, found ${matches}: ${original.slice(0, 90)}`)
  return source.split(original).join(replacement)
}

/** Adapt input ownership/sampling and the transient live preview. Committed
 * geometry, tools, history, styling and persistence stay canonical. */
export function transformInkLayer(source) {
  let code = `import { pencilSamples, pencilPredictions, pencilPressure, acceptsInkPointer } from ${JSON.stringify(samples)}\nimport { LiveInkPreview } from ${JSON.stringify(livePreview)}\n` + source
  code = `import { EraserGestureHitCache } from ${JSON.stringify(eraserHitCache)}\n` + code
  code = replaceExactly(code, '  const gestureRef = useRef<Gesture | null>(null)', '  const eraserHits = useRef(new EraserGestureHitCache())\n  const gestureRef = useRef<Gesture | null>(null)')
  code = replaceExactly(code, 'if (!ids.has(shape.id) && drawingHit(shape, point, aspect)) ids.add(shape.id)', 'if (!ids.has(shape.id) && eraserHits.current.hit(shape, point, aspect)) ids.add(shape.id)')
  code = replaceExactly(code, "    } else if (activeTool === 'eraser') {\n      setGesture(eraseAt", "    } else if (activeTool === 'eraser') {\n      eraserHits.current.begin()\n      setGesture(eraseAt")
  code = replaceExactly(code, '    gestureRef.current = next\n    setGestureState(next)', "    if (next?.kind !== 'erase') eraserHits.current.clear()\n    gestureRef.current = next\n    setGestureState(next)")
  code = replaceExactly(code, '      ref={svgRef}', '      data-bandal-ink-tool={activeTool}\n      ref={svgRef}')
  code = replaceExactly(code, '      points: DrawingPoint[]', '      points: DrawingPoint[]\n      style: DrawingStyle\n      startedAt: number')
  code = replaceExactly(code, '      setGesture({ ...current, points: [...current.points, point] })', `      const measured = { ...point, t: Math.max(0, (sample.timestamp ?? current.startedAt) - current.startedAt) }
      current.points.push(measured)
      gestureRef.current = current`)
  code = replaceExactly(code, 'interface PointerSample {', 'interface PointerSample {\n  timestamp?: number\n  tiltX?: number\n  tiltY?: number')
  code = replaceExactly(code, `    const point = normalizedPoint(
      event.currentTarget,
      event.clientX,
      event.clientY,
      event.pressure,
      clampToBounds
    )`, `    const point = pencilPressure(normalizedPoint(
      event.currentTarget, event.clientX, event.clientY, event.pressure, clampToBounds
    ), event.nativeEvent)!`)
  code = replaceExactly(code, '        points: [point]', `        points: [{ ...point, t: 0 }],
        style: drawingStyle(activeTool, width, opacity, color),
        startedAt: event.timeStamp`)
  code = replaceExactly(code, '      const nextStyle = drawingStyle(completed.tool, width, opacity, color)', '      const nextStyle = completed.style')
  code = replaceExactly(code, "          completed.tool === 'highlighter'", "          completed.tool === 'highlighter', 5")
  code = replaceExactly(code, '        data: { points: completed.points },', '        data: { points: completed.points, inkVersion: 5 },')
  code = replaceExactly(code, `          gesture.points,
          style,
          aspect,
          gesture.tool === 'highlighter'`, `          gesture.points,
          gesture.style,
          aspect,
          gesture.tool === 'highlighter', 5`)
  code = replaceExactly(code, `                fill={drawingColorVariable(style.color)}
                opacity={style.opacity}`, `                fill={drawingColorVariable(gesture.style.color)}
                opacity={gesture.style.opacity}`)
  code = replaceExactly(code, '    setGesture, startTextBox, surfaceReady])', '    setGesture, startTextBox, surfaceReady, width, opacity, color])')
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
  code = replaceExactly(code, 'if (sample !== null) processSample(sample)', 'for (const point of sample) processSample(point)\n    if (gestureRef.current?.kind === \'stroke\') setGesture({ ...gestureRef.current })', 2)
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
  code = replaceExactly(code, '  const gestureRef = useRef<Gesture | null>(null)', `  const gestureRef = useRef<Gesture | null>(null)
  const liveInkHost = useRef<SVGGElement>(null)
  const liveInk = useRef(new LiveInkPreview())`)
  code = replaceExactly(code, `    gestureRef.current = next
    setGestureState(next)
  }, [])`, `    gestureRef.current = next
    if (next?.kind === 'stroke') {
      liveInk.current.render(liveInkHost.current, next.points, next.style, aspect,
        next.tool === 'highlighter', drawingColorVariable(next.style.color))
    } else if (next !== null) liveInk.current.clear()
    setGestureState(next)
  }, [aspect])`)
  code = replaceExactly(code, '  const finishTextSession = useCallback((token?: number, cancelled = false): void => {', `  // Keep the final measured preview until React mounts the optimistic saved
  // shape. Layout effects remove it before that commit can paint twice.
  useLayoutEffect(() => {
    if (gesture?.kind !== 'stroke') liveInk.current.clear()
  })

  const finishTextSession = useCallback((token?: number, cancelled = false): void => {`)
  code = replaceExactly(code, `    if (gestureRef.current === null || !acceptsInkPointer(event, gestureRef.current.pointerId)) return
    pendingSample.current.push(...pencilSamples(event.nativeEvent))
    if (pointerFrame.current === null)`, `    if (gestureRef.current === null || !acceptsInkPointer(event, gestureRef.current.pointerId)) return
    const current = gestureRef.current
    if (current.kind === 'stroke') {
      for (const sample of pencilSamples(event.nativeEvent)) processSample(sample)
      const predicted: DrawingPoint[] = []
      for (const sample of pencilPredictions(event.nativeEvent)) {
        const point = pointFromSample(sample, clampToBounds)
        if (point) predicted.push({ ...point,
          t: Math.max(0, (sample.timestamp ?? current.startedAt) - current.startedAt) })
      }
      liveInk.current.render(liveInkHost.current, current.points, current.style, aspect,
        current.tool === 'highlighter', drawingColorVariable(current.style.color), predicted)
      return
    }
    pendingSample.current.push(...pencilSamples(event.nativeEvent))
    if (pointerFrame.current === null)`)
  code = replaceExactly(code, `      })
    }
  }, [processSample])`, `      })
    }
  }, [aspect, clampToBounds, pointFromSample, processSample])`)
  code = replaceExactly(code, `  useEffect(() => () => {
    if (pointerFrame.current !== null) cancelAnimationFrame(pointerFrame.current)
  }, [])`, `  useEffect(() => () => {
    if (pointerFrame.current !== null) cancelAnimationFrame(pointerFrame.current)
    liveInk.current.clear()
    eraserHits.current.clear()
  }, [])`)
  const previewStart = code.indexOf("      {gesture?.kind === 'stroke' && (() => {")
  const previewEnd = code.indexOf("      {gesture?.kind === 'shape' && (() => {", previewStart)
  if (previewStart < 0 || previewEnd < 0) throw new Error('iPad Pencil adapter: live stroke preview source anchor changed')
  code = replaceExactly(code, code.slice(previewStart, previewEnd), '      <g ref={liveInkHost} data-ink-live-host="" />\n')
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
