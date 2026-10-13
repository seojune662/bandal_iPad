import { useEffect, useRef } from 'react'
import { pdfjs } from 'react-pdf'
import usePageContext from 'react-pdf/dist/shared/hooks/usePageContext.js'
import { makePageCallback } from 'react-pdf/dist/shared/utils.js'

/** Keep completed pixels visible until their replacement is fully rendered. */
export function BufferedPdfCanvas(): JSX.Element {
  const context = usePageContext()
  const holder = useRef<HTMLDivElement>(null)
  const ready = useRef<HTMLCanvasElement | null>(null)
  const callbacks = useRef(context)
  callbacks.current = context
  const page = context?.page
  const scale = context?.scale ?? 1
  const rotate = context?.rotate
  const background = context?.canvasBackground
  useEffect(() => {
    if (!page) return
    let disposed = false
    let render: ReturnType<typeof page.render> | undefined
    let pending: HTMLCanvasElement | null = null
    const timer = window.setTimeout(() => {
      const natural = page.getViewport({ scale, ...(rotate === undefined ? {} : { rotation: rotate }) })
      const ratio = Math.min(window.devicePixelRatio || 1, 2, Math.sqrt(16_000_000 / (natural.width * natural.height)))
      const viewport = page.getViewport({ scale: scale * ratio, ...(rotate === undefined ? {} : { rotation: rotate }) })
      const canvas = document.createElement('canvas')
      pending = canvas
      canvas.className = 'react-pdf__Page__canvas'
      canvas.width = Math.ceil(viewport.width)
      canvas.height = Math.ceil(viewport.height)
      canvas.style.cssText = 'display:block;width:100%;height:100%'
      const drawing = canvas.getContext('2d', { alpha: false })
      if (!drawing) { canvas.width = canvas.height = 0; return }
      render = page.render({ canvas, canvasContext: drawing, viewport,
        annotationMode: pdfjs.AnnotationMode.ENABLE,
        ...(background ? { background } : {}) })
      void render.promise.then(() => {
        if (disposed || !holder.current) return
        const previous = ready.current
        holder.current.replaceChildren(canvas)
        ready.current = canvas
        pending = null
        canvas.dataset.renderScale = String(scale)
        if (previous) previous.width = previous.height = 0
        callbacks.current?.onRenderSuccess?.(makePageCallback(page, scale))
      }).catch((error: Error) => {
        if (!disposed && error.name !== 'RenderingCancelledException') callbacks.current?.onRenderError?.(error)
      }).finally(() => {
        if (pending) pending.width = pending.height = 0
      })
    }, ready.current ? 150 : 0)
    return () => { disposed = true; window.clearTimeout(timer); render?.cancel() }
  }, [page, scale, rotate, background])
  useEffect(() => () => { if (ready.current) ready.current.width = ready.current.height = 0 }, [])
  return <div ref={holder} className="pdf-buffered-canvas" aria-hidden="true" />
}
