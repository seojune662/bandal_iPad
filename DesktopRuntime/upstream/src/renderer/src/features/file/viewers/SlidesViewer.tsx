import { useEffect, useRef, useState } from 'react'
import type { CSSProperties } from 'react'
import { usePageImageCopy } from '../../pageImageCopy/usePageImageCopy'
import { AnnotatedSlidesViewer } from '../pptx/AnnotatedSlidesViewer'
import {
  EMU_PER_INCH,
  parsePptx,
  type ParsedPresentation,
  type SlideFrame,
  type SlideParagraph,
  type SlideShape
} from '../pptx/parsePptx'

interface SlidesViewerProps {
  courseId: string
  relPath: string
  base64: string
  fileName: string
  onError: () => void
}

function base64ToBytes(base64: string): Uint8Array {
  const binary = window.atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }
  return bytes
}

async function loadPresentation(base64: string): Promise<ParsedPresentation> {
  const jszipModule = await import('jszip')
  const JSZip = (jszipModule as unknown as { default?: typeof import('jszip') })
    .default ?? jszipModule
  const zip = await JSZip.loadAsync(base64ToBytes(base64))
  const files = new Map<string, string | Uint8Array>()
  const loads: Promise<void>[] = []
  zip.forEach((path, entry) => {
    if (entry.dir) return
    if (path.endsWith('.xml') || path.endsWith('.rels')) {
      loads.push(entry.async('string').then((text) => void files.set(path, text)))
    } else if (path.startsWith('ppt/media/')) {
      loads.push(
        entry.async('uint8array').then((bytes) => void files.set(path, bytes))
      )
    }
  })
  await Promise.all(loads)
  return parsePptx(files)
}

function frameStyle(frame: SlideFrame, cx: number, cy: number): CSSProperties {
  return {
    left: `${(frame.x / cx) * 100}%`,
    top: `${(frame.y / cy) * 100}%`,
    width: `${(frame.w / cx) * 100}%`,
    height: `${(frame.h / cy) * 100}%`
  }
}

const DEFAULT_TEXT_PT = 18

function Paragraphs({
  paragraphs,
  scale
}: {
  paragraphs: SlideParagraph[]
  scale: number
}): JSX.Element {
  return (
    <>
      {paragraphs.map((runs, paragraphIndex) => (
        <p key={paragraphIndex} className="file-slides__paragraph">
          {runs.map((run, runIndex) => (
            <span
              key={runIndex}
              style={{
                fontSize: `${(run.sizePt ?? DEFAULT_TEXT_PT) * (96 / 72) * scale}px`,
                ...(run.bold === true ? { fontWeight: 700 } : {}),
                ...(run.color !== undefined ? { color: run.color } : {})
              }}
            >
              {run.text}
            </span>
          ))}
        </p>
      ))}
    </>
  )
}

function ShapeView({
  shape,
  cx,
  cy,
  scale
}: {
  shape: SlideShape
  cx: number
  cy: number
  scale: number
}): JSX.Element | null {
  const positioned = shape.frame !== null
  const style = shape.frame !== null ? frameStyle(shape.frame, cx, cy) : undefined
  const className = positioned
    ? 'file-slides__shape'
    : 'file-slides__shape file-slides__shape--flow'

  if (shape.type === 'text') {
    if (shape.paragraphs.every((runs) => runs.every((run) => run.text.trim() === ''))) {
      return null
    }
    return (
      <div className={className} style={style}>
        <Paragraphs paragraphs={shape.paragraphs} scale={scale} />
      </div>
    )
  }
  if (shape.type === 'image') {
    if (shape.dataUrl === null) {
      return (
        <div className={`${className} file-slides__shape--placeholder`} style={style}>
          {shape.label}
        </div>
      )
    }
    return (
      <div className={className} style={style}>
        <img src={shape.dataUrl} alt={shape.label} draggable={false} />
      </div>
    )
  }
  if (shape.type === 'table') {
    return (
      <div className={className} style={style}>
        <table className="file-slides__table">
          <tbody>
            {shape.rows.map((cells, rowIndex) => (
              <tr key={rowIndex}>
                {cells.map((cell, cellIndex) => (
                  <td key={cellIndex}>
                    <Paragraphs paragraphs={[cell]} scale={scale} />
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    )
  }
  return (
    <div className={`${className} file-slides__shape--placeholder`} style={style}>
      {shape.label}
    </div>
  )
}

/**
 * PPTX 슬라이드 미리보기 — 텍스트·이미지·표를 원 배치대로, 차트류는
 * 자리표시로 렌더한다(테마 색·마스터 상속은 생략, 읽기 전용).
 */
function LegacySlidesViewer({
  base64,
  fileName,
  onError
}: SlidesViewerProps): JSX.Element {
  const [presentation, setPresentation] = useState<ParsedPresentation | null>(null)
  const [slideWidthPx, setSlideWidthPx] = useState(0)
  const columnRef = useRef<HTMLDivElement>(null)
  const pageImageCopy = usePageImageCopy(base64)

  useEffect(() => {
    let cancelled = false
    loadPresentation(base64)
      .then((parsed) => {
        if (!cancelled) setPresentation(parsed)
      })
      .catch((error: unknown) => {
        console.error('[Bandal] PPTX 해석 실패', error)
        if (!cancelled) onError()
      })
    return () => {
      cancelled = true
    }
  }, [base64, onError])

  useEffect(() => {
    const column = columnRef.current
    if (column === null) return
    const observer = new ResizeObserver(() => {
      const slide = column.querySelector('.file-slides__slide')
      if (slide instanceof HTMLElement) {
        setSlideWidthPx(slide.getBoundingClientRect().width)
      }
    })
    observer.observe(column)
    return () => observer.disconnect()
  }, [presentation])

  if (presentation === null) {
    return (
      <div className="file-status" role="status">
        슬라이드를 해석하는 중…
      </div>
    )
  }

  const { slideCx, slideCy, slides } = presentation
  const slideInchWidth = slideCx / EMU_PER_INCH
  const scale = slideWidthPx > 0 ? slideWidthPx / (slideInchWidth * 96) : 1

  return (
    <div className="file-slides">
      {pageImageCopy.overlay}
      <header className="file-slides__header">
        <strong>{fileName}</strong>
        <span>{slides.length}슬라이드 · 읽기 전용 미리보기</span>
      </header>
      <div className="file-slides__column" ref={columnRef}>
        {slides.map((slide, index) => {
          const flowShapes = slide.shapes.filter((shape) => shape.frame === null)
          return (
            <section
              key={index}
              className="file-slides__page"
              aria-label={`슬라이드 ${index + 1}`}
              tabIndex={-1}
              onContextMenu={(event) => pageImageCopy.openMenu(event, {
                label: `${index + 1}번 슬라이드`,
                disabledReason: '간단 미리보기에서는 이미지 복사를 지원하지 않아요. 자료를 다시 열거나 PDF로 변환해 주세요.'
              })}
            >
              <div
                className="file-slides__slide"
                style={{ aspectRatio: `${slideCx} / ${slideCy}` }}
              >
                {slide.shapes.map((shape, shapeIndex) =>
                  shape.frame === null ? null : (
                    <ShapeView
                      key={shapeIndex}
                      shape={shape}
                      cx={slideCx}
                      cy={slideCy}
                      scale={scale}
                    />
                  )
                )}
                <span className="file-slides__badge">{index + 1}</span>
              </div>
              {flowShapes.length > 0 && (
                <div className="file-slides__overflow">
                  {flowShapes.map((shape, shapeIndex) => (
                    <ShapeView
                      key={shapeIndex}
                      shape={shape}
                      cx={slideCx}
                      cy={slideCy}
                      scale={scale}
                    />
                  ))}
                </div>
              )}
            </section>
          )
        })}
      </div>
    </div>
  )
}


/**
 * Offline high-fidelity renderer first; the deliberately small OOXML parser
 * remains as a readable, crash-safe fallback for encrypted or malformed decks.
 */
export function SlidesViewer(props: SlidesViewerProps): JSX.Element {
  const [fallbackMessage, setFallbackMessage] = useState<string | null>(null)
  const onFallback = useRef((message: string) => setFallbackMessage(message)).current

  if (fallbackMessage !== null) {
    return (
      <div className="file-slides__fallback">
        <p role="status">{fallbackMessage}</p>
        <LegacySlidesViewer {...props} />
      </div>
    )
  }
  return <AnnotatedSlidesViewer {...props} onFallback={onFallback} />
}
