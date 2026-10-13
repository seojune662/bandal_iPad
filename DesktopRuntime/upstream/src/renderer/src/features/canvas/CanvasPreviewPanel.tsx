import { useEffect, useRef } from 'react'
import type {
  DrawingBox,
  DrawingShape
} from '../../../../shared/types/drawing'
import { TEXT_FILL_OPACITY } from '../../../../shared/textBoxMetrics'
import type {
  BoardBackground,
  PersonalBoardShape
} from '../../../../shared/types/whiteboard'
import {
  arrowHeadPoints,
  drawingColorVariable,
  lineEndpoints,
  strokePath
} from '../ink'
import { DEFAULT_PAGE_ASPECT } from './CanvasPage'
import './canvasPreview.css'

export const CANVAS_PREVIEW_SHAPE_LIMIT = 160

function renderBoxShape(
  shape: DrawingShape,
  box: DrawingBox
): JSX.Element | null {
  const color = drawingColorVariable(shape.style.color)
  const common = {
    stroke: color,
    strokeWidth: shape.style.width,
    opacity: shape.style.opacity
  }
  if (shape.kind === 'rect') {
    return <rect key={shape.id} {...box} {...common} fill="none" />
  }
  if (shape.kind === 'ellipse') {
    return (
      <ellipse
        key={shape.id}
        cx={box.x + box.width / 2}
        cy={box.y + box.height / 2}
        rx={box.width / 2}
        ry={box.height / 2}
        {...common}
        fill="none"
      />
    )
  }
  if (shape.kind === 'textbox') {
    const text = (shape.data.text ?? '').trim()
    if (text.length === 0) return null
    const align = shape.style.align ?? 'left'
    const x = align === 'left'
      ? box.x
      : align === 'center'
        ? box.x + box.width / 2
        : box.x + box.width
    const textDecoration = [
      shape.style.underline === true ? 'underline' : '',
      shape.style.strike === true ? 'line-through' : ''
    ].filter(Boolean).join(' ') || undefined
    return (
      <g key={shape.id}>
        {shape.style.fill !== undefined && (
          <rect
            {...box}
            fill={drawingColorVariable(shape.style.fill)}
            opacity={TEXT_FILL_OPACITY}
          />
        )}
        <text
          x={x}
          y={box.y + Math.min(box.height, 0.055)}
          fill={color}
          opacity={shape.style.opacity}
          fontSize={0.045 * (shape.style.fontScale ?? 1)}
          fontWeight={shape.style.bold === true ? 700 : 400}
          fontStyle={shape.style.italic === true ? 'italic' : 'normal'}
          textAnchor={align === 'left' ? 'start' : align === 'center' ? 'middle' : 'end'}
          textDecoration={textDecoration}
        >
          {text.slice(0, 24)}
        </text>
      </g>
    )
  }
  if (shape.kind === 'clip' || shape.kind === 'image') {
    return (
      <g key={shape.id} className="canvas-preview__reference" opacity={shape.style.opacity}>
        <rect {...box} />
        <path
          d={`M ${box.x} ${box.y} L ${box.x + box.width} ${box.y + box.height} M ${box.x + box.width} ${box.y} L ${box.x} ${box.y + box.height}`}
        />
      </g>
    )
  }
  return null
}

function PreviewShape({ shape }: { shape: DrawingShape }): JSX.Element | null {
  const color = drawingColorVariable(shape.style.color)
  if (shape.kind === 'ink' || shape.kind === 'highlighter') {
    const path = strokePath(
      shape.data.points ?? [],
      shape.style,
      DEFAULT_PAGE_ASPECT,
      shape.kind === 'highlighter'
    )
    return path.length === 0 ? null : (
      <path
        d={path}
        fill={color}
        opacity={shape.style.opacity}
      />
    )
  }
  if (shape.kind === 'line' || shape.kind === 'arrow') {
    const endpoints = lineEndpoints(shape)
    if (endpoints === null) return null
    return (
      <g
        stroke={color}
        strokeWidth={shape.style.width}
        opacity={shape.style.opacity}
        strokeLinecap="round"
        strokeLinejoin="round"
        fill="none"
      >
        <line
          x1={endpoints[0].x}
          y1={endpoints[0].y}
          x2={endpoints[1].x}
          y2={endpoints[1].y}
        />
        {shape.kind === 'arrow' && (
          <polyline
            points={arrowHeadPoints(
              endpoints[0],
              endpoints[1],
              shape.style.width,
              DEFAULT_PAGE_ASPECT
            )}
          />
        )}
      </g>
    )
  }
  const box = shape.data.box
  return box === undefined ? null : renderBoxShape(shape, box)
}

export interface CanvasPreviewPanelProps {
  pageCount: number
  currentPage: number
  background: BoardBackground
  shapes: readonly PersonalBoardShape[]
  onJump: (page: number) => void
}

export function CanvasPreviewPanel({
  pageCount,
  currentPage,
  background,
  shapes,
  onJump
}: CanvasPreviewPanelProps): JSX.Element {
  const listRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    listRef.current
      ?.querySelector('[aria-current="page"]')
      ?.scrollIntoView({ block: 'nearest' })
  }, [currentPage])

  return (
    <aside className="canvas-preview" aria-label="화이트보드 미리보기">
      <div className="canvas-preview__header">
        <strong>미리보기</strong>
        <span>{pageCount}쪽</span>
      </div>
      <div ref={listRef} className="canvas-preview__list">
        {Array.from({ length: pageCount }, (_, index) => index + 1).map((page) => {
          const pageShapes = shapes
            .filter((shape) => shape.page === page)
            .slice(-CANVAS_PREVIEW_SHAPE_LIMIT)
          return (
            <button
              key={page}
              type="button"
              className="canvas-preview__item"
              aria-label={`${page}페이지로 이동`}
              aria-current={page === currentPage ? 'page' : undefined}
              onClick={() => onJump(page)}
            >
              <span
                className="canvas-preview__paper"
                data-background={background}
              >
                <svg
                  viewBox="0 0 1 1"
                  preserveAspectRatio="none"
                  aria-hidden="true"
                >
                  {pageShapes.map((shape) => (
                    <PreviewShape key={shape.id} shape={shape} />
                  ))}
                </svg>
              </span>
              <span className="canvas-preview__page-number">{page}</span>
            </button>
          )
        })}
      </div>
    </aside>
  )
}
