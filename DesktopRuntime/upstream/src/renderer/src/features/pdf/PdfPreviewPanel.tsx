import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type RefObject
} from 'react'
import type { PDFDocumentProxy } from 'pdfjs-dist'
import './pdfPreview.css'

export const PDF_THUMBNAIL_RENDER_WIDTH_PX = 160
const THUMBNAIL_CACHE_LIMIT = 24
const THUMBNAIL_ROOT_MARGIN = '50% 0px 50% 0px'

interface RenderedThumbnail {
  canvas: HTMLCanvasElement
}

const thumbnailCaches = new WeakMap<
  PDFDocumentProxy,
  Map<number, Promise<RenderedThumbnail | null>>
>()

function cacheFor(
  pdf: PDFDocumentProxy
): Map<number, Promise<RenderedThumbnail | null>> {
  const existing = thumbnailCaches.get(pdf)
  if (existing !== undefined) return existing
  const created = new Map<number, Promise<RenderedThumbnail | null>>()
  thumbnailCaches.set(pdf, created)
  return created
}

async function renderThumbnail(
  pdf: PDFDocumentProxy,
  pageNumber: number
): Promise<RenderedThumbnail | null> {
  try {
    const page = await pdf.getPage(pageNumber)
    const natural = page.getViewport({ scale: 1 })
    if (natural.width <= 0 || natural.height <= 0) return null
    const viewport = page.getViewport({
      scale: PDF_THUMBNAIL_RENDER_WIDTH_PX / natural.width
    })
    const canvas = document.createElement('canvas')
    canvas.width = Math.max(1, Math.round(viewport.width))
    canvas.height = Math.max(1, Math.round(viewport.height))
    const context = canvas.getContext('2d', { alpha: false })
    if (context === null) return null
    await page.render({ canvas, canvasContext: context, viewport }).promise
    return { canvas }
  } catch {
    return null
  }
}

function thumbnailFor(
  pdf: PDFDocumentProxy,
  pageNumber: number
): Promise<RenderedThumbnail | null> {
  const cache = cacheFor(pdf)
  const existing = cache.get(pageNumber)
  if (existing !== undefined) {
    cache.delete(pageNumber)
    cache.set(pageNumber, existing)
    return existing
  }
  const pending = renderThumbnail(pdf, pageNumber)
  cache.set(pageNumber, pending)
  while (cache.size > THUMBNAIL_CACHE_LIMIT) {
    const oldest = cache.keys().next().value as number | undefined
    if (oldest === undefined) break
    cache.delete(oldest)
  }
  void pending.then((result) => {
    if (result === null && cache.get(pageNumber) === pending) {
      cache.delete(pageNumber)
    }
  })
  return pending
}

function useVisibleThumbnails(
  listRef: RefObject<HTMLDivElement>
): {
  visiblePages: Set<number>
  register: (page: number) => (element: HTMLElement | null) => void
} {
  const [visiblePages, setVisiblePages] = useState<Set<number>>(new Set())
  const observerRef = useRef<IntersectionObserver | null>(null)
  const elementsRef = useRef(new Map<number, HTMLElement>())
  const pageByElementRef = useRef(new WeakMap<Element, number>())
  const callbacksRef = useRef(
    new Map<number, (element: HTMLElement | null) => void>()
  )

  useEffect(() => {
    const root = listRef.current
    if (root === null) return
    const visible = new Set<number>()
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const page = pageByElementRef.current.get(entry.target)
        if (page === undefined) continue
        if (entry.isIntersecting) visible.add(page)
        else visible.delete(page)
      }
      setVisiblePages(new Set(visible))
    }, { root, rootMargin: THUMBNAIL_ROOT_MARGIN })
    observerRef.current = observer
    for (const element of elementsRef.current.values()) observer.observe(element)
    return () => {
      observer.disconnect()
      observerRef.current = null
    }
  }, [listRef])

  const register = useCallback((page: number) => {
    const existing = callbacksRef.current.get(page)
    if (existing !== undefined) return existing
    const callback = (element: HTMLElement | null): void => {
      const previous = elementsRef.current.get(page)
      if (previous !== undefined && previous !== element) {
        observerRef.current?.unobserve(previous)
        elementsRef.current.delete(page)
      }
      if (element !== null) {
        elementsRef.current.set(page, element)
        pageByElementRef.current.set(element, page)
        observerRef.current?.observe(element)
      }
    }
    callbacksRef.current.set(page, callback)
    return callback
  }, [])

  return { visiblePages, register }
}

function PdfThumbnail({
  pdf,
  pageNumber,
  visible
}: {
  pdf: PDFDocumentProxy | null
  pageNumber: number
  visible: boolean
}): JSX.Element {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    if (!visible || pdf === null) return
    let active = true
    void thumbnailFor(pdf, pageNumber).then((rendered) => {
      if (!active || rendered === null || canvasRef.current === null) return
      const canvas = canvasRef.current
      canvas.width = rendered.canvas.width
      canvas.height = rendered.canvas.height
      canvas.getContext('2d', { alpha: false })?.drawImage(rendered.canvas, 0, 0)
      canvas.dataset['ready'] = 'true'
    })
    return () => {
      active = false
    }
  }, [pageNumber, pdf, visible])

  return <canvas ref={canvasRef} className="pdf-preview__canvas" aria-hidden="true" />
}

export interface PdfPreviewPanelProps {
  pdf: PDFDocumentProxy | null
  numPages: number
  currentPage: number
  onJump: (page: number) => void
}

export function PdfPreviewPanel({
  pdf,
  numPages,
  currentPage,
  onJump
}: PdfPreviewPanelProps): JSX.Element {
  const listRef = useRef<HTMLDivElement>(null)
  const { visiblePages, register } = useVisibleThumbnails(listRef)

  useEffect(() => {
    listRef.current
      ?.querySelector('[aria-current="page"]')
      ?.scrollIntoView({ block: 'nearest' })
  }, [currentPage])

  return (
    <aside className="pdf-preview" aria-label="PDF 미리보기">
      <div className="pdf-preview__header">
        <strong>미리보기</strong>
        <span>{numPages}쪽</span>
      </div>
      <div ref={listRef} className="pdf-preview__list">
        {Array.from({ length: numPages }, (_, index) => index + 1).map((page) => (
          <button
            key={page}
            ref={register(page)}
            type="button"
            className="pdf-preview__item"
            aria-label={`${page}쪽으로 이동`}
            aria-current={page === currentPage ? 'page' : undefined}
            onClick={() => onJump(page)}
          >
            <span className="pdf-preview__paper">
              <PdfThumbnail
                pdf={pdf}
                pageNumber={page}
                visible={visiblePages.has(page)}
              />
            </span>
            <span className="pdf-preview__page-number">{page}</span>
          </button>
        ))}
      </div>
    </aside>
  )
}
