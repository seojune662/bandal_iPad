import { useEffect, useState } from 'react'
import type { DrawingShape } from '../../../../../shared/types/drawing'
import type { PersonalBoard, PersonalBoardShape } from '../../../../../shared/types/whiteboard'
import { TEXT_FILL_OPACITY } from '../../../../../shared/textBoxMetrics'
import { invoke, onPush } from '../../../lib/ipc'
import { arrowHeadPoints, drawingColorVariable, lineEndpoints, strokePath } from '../../ink/inkGeometry'
import { loadReferencedThumbnail } from './mediaThumbnails'

const PREVIEW_SHAPE_LIMIT = 160
const PREVIEW_REFERENCE_LIMIT = 6
const PAGE_ASPECT = Math.SQRT2

function ReferencePreview({ courseId, shape, load }: { courseId: string; shape: DrawingShape; load: boolean }): JSX.Element | null {
  const [image, setImage] = useState<string | null>(null)
  const source = shape.data.clip
  const imageSource = shape.data.image
  const box = shape.data.box
  useEffect(() => {
    setImage(null)
    const relPath = source?.relPath ?? (imageSource?.storage !== 'shared' ? imageSource?.relPath : undefined)
    if (!load || relPath === undefined) return
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), 10000)
    void loadReferencedThumbnail(courseId, relPath, controller.signal, source?.page, source?.crop)
      .then((thumbnail) => { if (!controller.signal.aborted) setImage(thumbnail.dataUrl) })
      .catch(() => undefined).finally(() => clearTimeout(timeout))
    return () => { clearTimeout(timeout); controller.abort() }
  }, [courseId, load, source, imageSource])
  if (box === undefined) return null
  const src = image
  return <g opacity={shape.style.opacity}>
    <rect {...box} fill="var(--material-preview-paper)" stroke="var(--drawing-color-ink)" strokeWidth={0.002} opacity={0.3} />
    {src === null
      ? <text x={box.x + 0.01} y={box.y + 0.03} fontSize={0.025} fill="var(--drawing-color-ink)">{(source?.label ?? imageSource?.label ?? '첨부 자료').slice(0, 18)}</text>
      : <image {...box} href={src} preserveAspectRatio="xMidYMid meet" />}
  </g>
}

function BoardShape({ courseId, shape, loadReference }: { courseId: string; shape: DrawingShape; loadReference: boolean }): JSX.Element | null {
  const color = drawingColorVariable(shape.style.color)
  if (shape.kind === 'ink' || shape.kind === 'highlighter') {
    const path = strokePath(shape.data.points ?? [], shape.style, PAGE_ASPECT, shape.kind === 'highlighter')
    return path.length === 0 ? null : <path d={path} fill={color} opacity={shape.style.opacity} />
  }
  if (shape.kind === 'line' || shape.kind === 'arrow') {
    const endpoints = lineEndpoints(shape)
    if (endpoints === null) return null
    return <g stroke={color} strokeWidth={shape.style.width} opacity={shape.style.opacity} strokeLinecap="round" strokeLinejoin="round" fill="none">
      <line x1={endpoints[0].x} y1={endpoints[0].y} x2={endpoints[1].x} y2={endpoints[1].y} />
      {shape.kind === 'arrow' && <polyline points={arrowHeadPoints(endpoints[0], endpoints[1], shape.style.width, PAGE_ASPECT)} />}
    </g>
  }
  const box = shape.data.box
  if (box === undefined) return null
  if (shape.kind === 'image' || shape.kind === 'clip') return <ReferencePreview courseId={courseId} shape={shape} load={loadReference} />
  const common = { stroke: color, strokeWidth: shape.style.width, opacity: shape.style.opacity, fill: 'none' }
  if (shape.kind === 'rect') return <rect {...box} {...common} />
  if (shape.kind === 'ellipse') return <ellipse cx={box.x + box.width / 2} cy={box.y + box.height / 2} rx={box.width / 2} ry={box.height / 2} {...common} />
  if (shape.kind === 'textbox') {
    const text = (shape.data.text ?? '').trim()
    if (text.length === 0) return null
    const align = shape.style.align ?? 'left'
    const x = align === 'left' ? box.x : align === 'center' ? box.x + box.width / 2 : box.x + box.width
    const fontSize = 0.028 * (shape.style.fontScale ?? 1)
    const lines = text.split('\n').flatMap((line) => line.match(/.{1,36}/gu) ?? ['']).slice(0, 8)
    return <g>
      {shape.style.fill !== undefined && <rect {...box} fill={drawingColorVariable(shape.style.fill)} opacity={TEXT_FILL_OPACITY} />}
      <text x={x} y={box.y + fontSize} fill={color} opacity={shape.style.opacity} fontSize={fontSize}
        fontWeight={shape.style.bold === true ? 700 : 400} fontStyle={shape.style.italic === true ? 'italic' : 'normal'}
        textAnchor={align === 'left' ? 'start' : align === 'center' ? 'middle' : 'end'}
        textDecoration={[shape.style.underline ? 'underline' : '', shape.style.strike ? 'line-through' : ''].filter(Boolean).join(' ') || undefined}>
        {lines.map((line, index) => <tspan key={index} x={x} dy={index === 0 ? 0 : fontSize * 1.3}>{line}</tspan>)}
      </text>
    </g>
  }
  return null
}

export function WhiteboardPreviewContent({ courseId, board }: { courseId: string; board: PersonalBoard }): JSX.Element {
  const [loaded, setLoaded] = useState<{ board: PersonalBoard; shapes: PersonalBoardShape[] | 'error' } | null>(null)
  useEffect(() => {
    let active = true
    let request = 0
    const refresh = (): void => {
      const sequence = ++request
      void invoke('canvas:hoverPreview', { boardId: board.id }).then((value) => {
        if (active && sequence === request) setLoaded({ board: value.board, shapes: value.shapes.filter((shape) => shape.page === 1).slice(-PREVIEW_SHAPE_LIMIT) })
      }).catch(() => { if (active && sequence === request) setLoaded({ board, shapes: 'error' }) })
    }
    refresh()
    const unsubscribe = onPush('canvas:changed', (event) => { if (event.courseId === courseId) refresh() })
    return () => { active = false; unsubscribe() }
  }, [courseId, board.id, board.updatedAt])
  const current = loaded?.board.id === board.id ? loaded : null
  const shapes = current?.shapes ?? null
  const metadata = current?.board ?? board
  let references = 0
  return <div className="material-preview-content">
    {shapes === null
      ? <p className="material-preview-content__message">미리보기 불러오는 중…</p>
      : shapes === 'error' ? <p className="material-preview-content__message">미리보기를 불러올 수 없어요</p>
        : shapes.length === 0 ? <p className="material-preview-content__message">첫 페이지에 아직 내용이 없어요</p>
          : <div className="material-preview-content__board" data-surface={metadata.surface} data-background={metadata.background}>
            <svg viewBox="0 0 1 1" preserveAspectRatio="none" role="img" aria-label="화이트보드 첫 페이지">
              {shapes.map((shape) => {
                if (shape.kind === 'image' || shape.kind === 'clip') references += 1
                return <BoardShape key={shape.id} courseId={courseId} shape={shape} loadReference={references <= PREVIEW_REFERENCE_LIMIT} />
              })}
            </svg>
          </div>}
    <span className="material-preview-content__caption">1 / {metadata.pageCount}쪽</span>
  </div>
}
