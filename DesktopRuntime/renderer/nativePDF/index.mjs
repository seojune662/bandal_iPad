import { fileURLToPath } from 'node:url'
const adapter = fileURLToPath(new URL('./useNativePDF.ts', import.meta.url))
const pointerAdapter = fileURLToPath(new URL('./pointerRelay.ts', import.meta.url))
const sceneAdapter = fileURLToPath(new URL('./objectScene.ts', import.meta.url))
const developmentSetting = fileURLToPath(new URL('./NativePDFDevelopmentSetting.tsx', import.meta.url))

function replace(source, anchor, replacement) {
  if (source.split(anchor).length !== 2) throw new Error(`Native PDF adapter anchor changed: ${anchor.slice(0, 100)}`)
  return source.replace(anchor, replacement)
}
export function transformNativePDF(source) {
  let code = `import { useNativePDF } from ${JSON.stringify(adapter)}\n` + source
  code = replace(code, '  panelId,\n  pageNotePair\n}: {', '  panelId,\n  onNativeActivate,\n  pageNotePair\n}: {')
  code = replace(code, '  panelId: string\n  pageNotePair:', '  panelId: string\n  onNativeActivate(): void\n  pageNotePair:')
  code = replace(code, '        panelId={props.api.id}', '        panelId={props.api.id}\n        onNativeActivate={() => props.api.setActive()}')
  const anchor = '  if (loadError !== null) {'
  const hook = `  const nativePDF = useNativePDF({
    panelId, courseId, relPath, visible, interactive, scroller: scrollerRef,
    pdf: pdfProxy, drawings: drawingsApi, annotations, page: currentPage, zoom,
    activeAnnotation: editPopover?.annotationId ?? null, hoveredAnnotation: hoveredId,
    onBodyTap: () => { setPendingSelection(null); setEditPopover(null) },
    onActivate: onNativeActivate,
    blocked: isPageNoteDialogOpen || pendingSelection !== null || editPopover !== null || whiteboardClip.picker !== null,
    onReady: (sizes) => { setPageAspects(new Map(sizes.map(size => [size.page, size.height / size.width]))); markFirstRender() },
    onAnnotation: (id, x, y) => {
      const annotation = annotations.find(entry => entry.id === id), bounds = scrollerRef.current?.getBoundingClientRect()
      if (annotation && bounds) handleAnnotationClick(annotation, bounds.left+x, bounds.top+y)
    },
    onPageAction: (action, page, x, y) => {
      const viewport = scrollerRef.current?.getBoundingClientRect()
      if (!viewport) return
      const clientX = viewport.left+x, clientY = viewport.top+y
      if (action === 'whiteboard') {
        setPendingSelection(null); setEditPopover(null)
        void whiteboardClip.send({ relPath, page, pageAspect: pageAspects.get(page) ?? defaultAspect,
          label: pdfClipLabel(relPath, page, false) }, clientX, clientY)
      } else {
        const node = scrollerRef.current?.querySelector('[data-pdf-page="'+page+'"]')
        node?.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX, clientY }))
      }
    },
    onViewport: (view) => {
      cancelInitialRestore(); zoomRef.current = view.zoom; setZoom(view.zoom); setCurrentPage(view.page)
      requestAnimationFrame(() => {
        restoreViewportAnchor({ page: view.page, pageOffset: view.progress })
        const scroller = scrollerRef.current, page = scroller?.querySelector('[data-pdf-page="'+view.page+'"]')
        if (scroller && page && typeof view.horizontalProgress === 'number') {
          const viewport = scroller.getBoundingClientRect(), bounds = page.getBoundingClientRect()
          scroller.scrollLeft += bounds.left + bounds.width*view.horizontalProgress - viewport.left - viewport.width/2
        }
        if (pageNotePair) claimPageSyncInput(pageNotePair.pairId, panelId)
        rememberViewportAnchor()
      })
    },
    onSelection: (selection) => {
      const source = contentRef.current, scroller = scrollerRef.current
      if (!source || !scroller || activeTool !== 'select') return
      const sourceRect = source.getBoundingClientRect(), viewport = scroller.getBoundingClientRect()
      setPendingSelection({ page: selection.page, anchor: selection.anchor, rects: selection.rects,
        position: { left: viewport.left + selection.x - sourceRect.left, top: viewport.top + selection.y - sourceRect.top } })
    }
  })

`
  code = replace(code, anchor, hook + anchor)
  code = replace(code, '        drawingsApi={drawingsApi}', `        drawingsApi={{ ...drawingsApi,
          canUndo: drawingsApi.canUndo || nativePDF.hasPending,
          canRedo: drawingsApi.canRedo && !nativePDF.hasPending,
          flush: nativePDF.flush,
          undo: async () => { await nativePDF.flush(); await drawingsApi.undo() },
          redo: async () => { await nativePDF.flush(); await drawingsApi.redo() } }}`)
  code = replace(code, '<PdfPageView\n', '<PdfPageView\n                      nativeBody={nativePDF.active}\n')
  return code
}
export function transformNativePDFPage(source) {
  let code = replace(source, 'export interface PdfPageViewProps {', 'export interface PdfPageViewProps {\n  nativeBody?: boolean')
  code = replace(code, 'data-pdf-page={pageNumber}', 'data-pdf-page={pageNumber}\n      data-native-pdf={props.nativeBody ? "true" : undefined}')
  code = replace(code, '            renderTextLayer\n', '            renderTextLayer={!props.nativeBody}\n')
  code = replace(code, '><BufferedPdfCanvas /></Page>', '>{!props.nativeBody && <BufferedPdfCanvas />}</Page>')
  return code
}
export function transformNativePDFPointerCapture(source) {
  let code = replace(source, 'event.currentTarget.setPointerCapture(event.pointerId)', 'captureNativePDFPointer(event.currentTarget, event.pointerId, event.nativeEvent)')
  code = replace(code, 'svg.setPointerCapture(event.pointerId)', 'captureNativePDFPointer(svg, event.pointerId, event.nativeEvent)')
  code = replace(code, '  const selectionFrame = (box: DrawingBox): JSX.Element => (', `  useLayoutEffect(() => {
    if (activeTool === 'pen' || activeTool === 'highlighter') return
    const edited = shapes.filter(shape => !erasedIds.has(shape.id)).map(shape => {
      const box = boxForShape(shape, gesture, resolveShapeId)
      if (!box || !shape.data.box) return shape
      let points = shape.data.points
      if ((shape.kind === 'line' || shape.kind === 'arrow') && points && gesture?.kind === 'move') {
        const dx = box.x-shape.data.box.x, dy = box.y-shape.data.box.y
        points = points.map(point => ({ ...point, x: point.x+dx, y: point.y+dy }))
      }
      return { ...shape, data: { ...shape.data, box, ...(points ? { points } : {}) } }
    })
    publishNativePDFScene(svgRef.current, { shapes: edited, aspect, selectedId, editingId,
      preview: gesture?.kind === 'shape' ? { kind: gesture.tool, data: { box: normalizedBox(gesture.start, gesture.end),
        ...((gesture.tool === 'line' || gesture.tool === 'arrow') ? { points: [gesture.start, gesture.end] } : {}) }, style } : null })
  })

  const selectionFrame = (box: DrawingBox): JSX.Element => (`)
  return `import { captureNativePDFPointer } from ${JSON.stringify(pointerAdapter)}\nimport { publishNativePDFScene } from ${JSON.stringify(sceneAdapter)}\n` + code
}
export default function nativePDFPlugin() {
  return { name: 'bandal-native-pdf-body', enforce: 'pre', transform(source, id) {
    if (id.endsWith('/src/renderer/src/features/settings/SettingsApp.tsx')) return { code:
      `import { NativePDFDevelopmentSetting } from ${JSON.stringify(developmentSetting)}\n` +
      replace(source, 'experimental: <ExperimentalPanel settings={settings} />,', 'experimental: <><ExperimentalPanel settings={settings} /><NativePDFDevelopmentSetting /></>,'), map: null }
    if (id.endsWith('/src/renderer/src/features/pdf/PdfTab.tsx')) return { code: transformNativePDF(source), map: null }
    if (id.endsWith('/src/renderer/src/features/pdf/PdfPageView.tsx')) return { code: transformNativePDFPage(source), map: null }
    if (id.endsWith('/src/renderer/src/features/ink/InkLayer.tsx')) return { code: transformNativePDFPointerCapture(source), map: null }
    return null
  } }
}
