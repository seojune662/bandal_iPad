import {
  memo,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type FocusEvent as ReactFocusEvent,
  type PointerEvent as ReactPointerEvent
} from 'react'
import type {
  DrawingBox,
  DrawingClipSource,
  DrawingKind,
  DrawingPoint,
  DrawingShape,
  DrawingStyle,
  DrawingTextRun
} from '../../../../shared/types/drawing'
import {
  TEXT_BOX_BORDER_EM,
  TEXT_DEFAULT_FONT_PT,
  TEXT_BOX_PADDING_EM,
  TEXT_LINE_HEIGHT,
  textBoxFontPx
} from '../../../../shared/textBoxMetrics'
import { normalizeTextRuns } from '../../../../shared/textRuns'
import {
  arrowHeadPoints,
  drawingColorVariable,
  drawingHit,
  lineEndpoints,
  moveDrawingBox,
  normalizedBox,
  normalizedPoint,
  resizeDrawingBox,
  type ResizeHandle,
  strokePath
} from './inkGeometry'
import { healedImageBox } from './imagePlacement'
import type { InkTool, InkToolState } from './inkToolStore'
import type { RenderClip } from './ClipShape'
import { isEditableTarget } from './domTarget'
import { foreignObjectLayout } from './foreignObjectScale'
import { ReferencedShape } from './ReferencedShape'
import { ResizeHandles, TEXTBOX_HANDLES } from './ResizeHandles'
import { TextBoxEditor, type TextBoxEditorHandle } from './TextBoxEditor'
import {
  mergeTextStyle,
  TEXT_FORMAT_ROW_ATTR,
  isInsideTextFormatRow,
  useTextFormatStore,
  type TextFormatMode
} from './textFormatStore'
import {
  fittedTextBox,
  healedTextBox,
  textBoxAtClick
} from './textBoxLayout'
import './ink.css'

export interface InkLayerProps {
  aspect: number
  baseWidthPx: number
  /** Logical surface width in PDF points; A4 for board surfaces. */
  surfaceWidthPt?: number
  shapes: readonly DrawingShape[]
  tool: InkToolState
  onCreate: (shape: Omit<DrawingShape, 'id' | 'createdAt' | 'updatedAt'>) => void
  onUpdate: (
    id: string,
    patch: Partial<Pick<DrawingShape, 'data' | 'style'>>
  ) => void
  onRemove: (ids: string[]) => void
  clampToBounds?: boolean
  ariaLabel: string
  className?: string
  /** Course that owns image paths. Required only when image shapes are present. */
  courseId?: string
  /** Shared board that owns private image assets. */
  boardId?: string
  /** Surface-owned PDF renderer; omitted on PDF markup and group boards. */
  renderClip?: RenderClip
  onOpenClip?: (source: DrawingClipSource) => void
  /**
   * 이미지 원본 비율이 확정됐는데 box 비율이 어긋난 셰이프를 표면이 조용히
   * 보정(undo 미기록)할 수 있게 한다. 미배선 표면은 레터박스 폴백으로 렌더.
   */
  onRefineBox?: ((id: string, box: DrawingBox) => void) | undefined
  /**
   * 이 레이어가 지금 사용자 입력의 주인인지(패널 활성). false 면 선택을
   * 해제하고 키보드 삭제도 받지 않는다 — 열린 탭 여러 개가 Backspace 를
   * 동시에 먹는 사고 방지.
   */
  interactive?: boolean
  /** Maps an optimistic id to its saved id without replacing the user's editor draft. */
  resolveShapeId?: ((id: string) => string) | undefined
}

type ShapeTool = 'rect' | 'ellipse' | 'arrow' | 'line'

type Gesture =
  | {
      kind: 'stroke'
      pointerId: number
      tool: 'pen' | 'highlighter'
      points: DrawingPoint[]
    }
  | {
      kind: 'shape'
      pointerId: number
      tool: ShapeTool
      start: DrawingPoint
      end: DrawingPoint
    }
  | {
      kind: 'erase'
      pointerId: number
      ids: Set<string>
    }
  | {
      kind: 'move'
      pointerId: number
      shape: DrawingShape
      start: DrawingPoint
      /** 화면 px 원점 — 클릭/드래그 판정은 정규화 좌표가 아니라 px 로. */
      originClient: ClientPoint
      /** 클릭 허용 오차를 넘어 실제로 움직였는지. */
      moved: boolean
      box: DrawingBox
    }
  | {
      kind: 'resize'
      pointerId: number
      shape: DrawingShape
      start: DrawingPoint
      originClient: ClientPoint
      moved: boolean
      box: DrawingBox
      handle: ResizeHandle
    }

interface TextEditSession {
  token: number
  shapeId: string | null
  renderKey: string | null
  box: DrawingBox
  text: string
  runs: DrawingTextRun[]
  style: DrawingStyle
}

interface ClientPoint {
  x: number
  y: number
}

interface PointerSample {
  pointerId: number
  clientX: number
  clientY: number
  pressure: number
}

const SHAPE_TOOLS: readonly ShapeTool[] = ['rect', 'ellipse', 'arrow', 'line']
/** 이 거리(화면 px) 안의 pointerdown→up 은 드래그가 아니라 클릭이다. */
const CLICK_TOLERANCE_PX = 3
/** select 툴로 잡을 수 있는 셰이프 — 잉크 스트로크는 지우개 전용으로 남긴다. */
const SELECTABLE_KINDS: ReadonlySet<DrawingKind> = new Set([
  'textbox',
  'image',
  'clip',
  'rect',
  'ellipse',
  'line',
  'arrow'
])
/** 코너 리사이즈에서 박스 비율을 잠그는 셰이프. 텍스트박스는 자유
 * 리사이즈 + 줄바꿈 재배치라 여기 속하지 않는다. */
const ASPECT_LOCKED_KINDS: ReadonlySet<DrawingKind> = new Set([
  'image',
  'clip'
])

function isFinitePositive(value: number): boolean {
  return Number.isFinite(value) && value > 0
}

function isRenderableBox(box: DrawingBox | undefined): box is DrawingBox {
  return box !== undefined &&
    Number.isFinite(box.x) &&
    Number.isFinite(box.y) &&
    isFinitePositive(box.width) &&
    isFinitePositive(box.height)
}

function isRenderableSegment(
  start: DrawingPoint,
  end: DrawingPoint,
  aspect: number
): boolean {
  const coordinates = [start.x, start.y, end.x, end.y]
  return coordinates.every(Number.isFinite) &&
    isFinitePositive(aspect) &&
    Math.hypot(end.x - start.x, (end.y - start.y) * aspect) > 0
}

function hasMeasuredBounds(element: SVGSVGElement): boolean {
  const bounds = element.getBoundingClientRect()
  return isFinitePositive(bounds.width) && isFinitePositive(bounds.height)
}

export function createTextBoxShape(
  box: DrawingBox,
  text: string,
  style: DrawingStyle,
  textRuns: readonly DrawingTextRun[] = []
): Omit<DrawingShape, 'id' | 'createdAt' | 'updatedAt'> | null {
  const normalizedRuns = normalizeTextRuns(text, textRuns)
  return text.trim().length === 0 || !isRenderableBox(box)
    ? null
    : {
        kind: 'textbox',
        data: {
          box,
          text,
          ...(normalizedRuns.length > 0 ? { textRuns: normalizedRuns } : {})
        },
        style
      }
}

function drawingStyle(
  tool: InkTool,
  width: number,
  opacity: number,
  color: DrawingStyle['color']
): DrawingStyle {
  if (tool === 'highlighter') {
    return { color, width: Math.max(width * 4, 0.014), opacity: Math.min(opacity, 0.34) }
  }
  if (tool === 'text') return { color, width, opacity, fontSizePt: TEXT_DEFAULT_FONT_PT }
  return { color, width, opacity }
}

function renderTextRuns(
  text: string,
  sourceRuns: readonly DrawingTextRun[] | undefined,
  baseWidthPx: number,
  surfaceWidthPt: number,
  baseStyle: DrawingStyle
): JSX.Element[] {
  const runs = normalizeTextRuns(text, sourceRuns)
  const content: JSX.Element[] = []
  const append = (from: number, to: number, override: DrawingTextRun['style'] = {}): void => {
    if (to <= from) return
    const effective = { ...baseStyle, ...override }
    const decorations = [
      ...(effective.underline === true ? ['underline'] : []),
      ...(effective.strike === true ? ['line-through'] : [])
    ]
    const inlineStyle: CSSProperties = {
      ...(override.color === undefined ? {} : { color: drawingColorVariable(override.color) }),
      ...(override.fontSizePt === undefined ? {} : {
        fontSize: textBoxFontPx(baseWidthPx, undefined, override.fontSizePt, surfaceWidthPt)
      }),
      fontWeight: effective.bold === true ? 700 : 400,
      fontStyle: effective.italic === true ? 'italic' : 'normal',
      textDecoration: decorations.length > 0 ? decorations.join(' ') : 'none'
    }
    content.push(<span key={`${from}:${to}`} style={inlineStyle}>{text.slice(from, to)}</span>)
  }
  let offset = 0
  for (const run of runs) {
    append(offset, run.from)
    append(run.from, run.to, run.style)
    offset = run.to
  }
  append(offset, text.length)
  return content
}

function boxForShape(shape: DrawingShape, gesture: Gesture | null, resolveId?: (id: string) => string): DrawingBox | undefined {
  if (
    gesture !== null &&
    (gesture.kind === 'move' || gesture.kind === 'resize') &&
    (resolveId?.(gesture.shape.id) ?? gesture.shape.id) === shape.id
  ) {
    return gesture.box
  }
  return shape.data.box
}

// Existing strokes do not change as the pen moves. Keep perfect-freehand's
// outline calculation out of the pointer frame for every previously drawn line.
const InkStroke = memo(function InkStroke({ shape, aspect }: { shape: DrawingShape; aspect: number }): JSX.Element | null {
  const path = strokePath(shape.data.points ?? [], shape.style, aspect, shape.kind === 'highlighter')
  return path ? <path className={shape.kind === 'highlighter' ? 'ink-layer__mark is-highlighter' : 'ink-layer__mark'}
    d={path} fill={drawingColorVariable(shape.style.color)} opacity={shape.style.opacity} /> : null
})

export function InkLayer(props: InkLayerProps): JSX.Element {
  const {
    aspect,
    baseWidthPx,
    shapes,
    tool,
    onCreate,
    onUpdate,
    onRemove,
    clampToBounds = true,
    ariaLabel,
    className,
    courseId,
    boardId,
    renderClip,
    onOpenClip,
    onRefineBox,
    interactive = true,
    resolveShapeId,
    surfaceWidthPt = 595.28
  } = props
  const { activeTool, color, width, opacity } = tool
  const svgRef = useRef<SVGSVGElement>(null)
  const gestureRef = useRef<Gesture | null>(null)
  const pendingSample = useRef<PointerSample | null>(null)
  const pointerFrame = useRef<number | null>(null)
  const previousShapeIds = useRef(new Set(shapes.map((shape) => shape.id)))
  // A single owned session prevents drafts and saved boxes from sharing text.
  // The token also rejects blur/animation callbacks from an editor we replaced.
  const textSessionRef = useRef<TextEditSession | null>(null)
  const nextTextSession = useRef(0)
  const textEditorRef = useRef<TextBoxEditorHandle>(null)
  /** 서식 행(툴바)에 공개하는 대상의 소유자 키 — 페이지마다 레이어가 하나씩. */
  const ownerId = useId()
  // 서식 apply 가 낡은 클로저로 최신 필드를 덮어쓰지 않게 항상 최신을 읽는다.
  const shapesRef = useRef(shapes)
  shapesRef.current = shapes
  const onUpdateRef = useRef(onUpdate)
  onUpdateRef.current = onUpdate
  const onCreateRef = useRef(onCreate)
  onCreateRef.current = onCreate
  const onRemoveRef = useRef(onRemove)
  onRemoveRef.current = onRemove
  const resolveShapeIdRef = useRef(resolveShapeId)
  resolveShapeIdRef.current = resolveShapeId
  // A selected (not currently edited) textbox has no editor to report its
  // intrinsic height. Queue exactly those boxes whose typography changed and
  // measure their rendered rich-text DOM after React applies the new style.
  const pendingTextFitIds = useRef(new Set<string>())
  // 같은 셰이프 버전을 두 번 치유하지 않는다 — 줌(baseWidthPx) 변화나 렌더
  // 반복이 onRefineBox 를 다시 부르는 일을 막는다.
  const healedVersions = useRef(new Set<string>())
  const [gesture, setGestureState] = useState<Gesture | null>(null)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [newTextBox, setNewTextBox] = useState<DrawingBox | null>(null)
  const [textDraft, setTextDraft] = useState('')
  const [textRunsDraft, setTextRunsDraft] = useState<DrawingTextRun[]>([])
  const [draftEditorSession, setDraftEditorSession] = useState(0)
  const updateTextDraft = useCallback((
    text: string,
    runs: DrawingTextRun[]
  ): void => {
    const session = textSessionRef.current
    if (session !== null) {
      session.text = text
      session.runs = runs
    }
    setTextDraft(text)
    setTextRunsDraft(runs)
  }, [])
  const [inlineFormatStyle, setInlineFormatStyle] = useState<DrawingStyle | null>(null)
  /** 새 draft 박스의 서식 — 커밋 전에도 서식 바로 편집할 수 있게 로컬 보관. */
  const [draftStyle, setDraftStyle] = useState<DrawingStyle | null>(null)
  /** 편집 중 타이핑으로 자란 기존 박스의 로컬 프리뷰(확정 시 저장). */
  const [editingBoxOverride, setEditingBoxOverride] =
    useState<DrawingBox | null>(null)
  const surfaceReady = isFinitePositive(aspect) &&
    isFinitePositive(baseWidthPx) &&
    Number.isFinite(baseWidthPx * aspect)

  const setGesture = useCallback((next: Gesture | null): void => {
    gestureRef.current = next
    setGestureState(next)
  }, [])

  const finishTextSession = useCallback((token?: number, cancelled = false): void => {
    const session = textSessionRef.current
    if (session === null || (token !== undefined && session.token !== token)) return
    // Close ownership before saving or replacing the DOM. A subsequent blur
    // must never commit the next editor's content under this session's id.
    textSessionRef.current = null
    setEditingId(null)
    setNewTextBox(null)
    setEditingBoxOverride(null)
    setDraftStyle(null)
    setInlineFormatStyle(null)
    if (cancelled) return
    if (session.shapeId === null) {
      const shape = createTextBoxShape(session.box, session.text, session.style, session.runs)
      if (shape !== null) onCreateRef.current(shape)
      return
    }
    const shapeId = resolveShapeIdRef.current?.(session.shapeId) ?? session.shapeId
    const shape = shapesRef.current.find((entry) => entry.id === shapeId)
    if (shape === undefined) return
    if (session.text.trim().length === 0) {
      onRemoveRef.current([shape.id])
      return
    }
    const runs = normalizeTextRuns(session.text, session.runs)
    if (
      session.text === (shape.data.text ?? '') &&
      JSON.stringify(runs) === JSON.stringify(normalizeTextRuns(shape.data.text ?? '', shape.data.textRuns)) &&
      JSON.stringify(session.box) === JSON.stringify(shape.data.box)
    ) return
    const data: DrawingShape['data'] = { ...shape.data, box: session.box, text: session.text }
    if (runs.length > 0) data.textRuns = runs
    else delete data.textRuns
    onUpdateRef.current(shape.id, { data })
  }, [])

  const startEditing = useCallback((shape: DrawingShape): void => {
    if (!interactive || (activeTool !== 'text' && activeTool !== 'select')) return
    if (shape.data.box === undefined) return
    const currentId = textSessionRef.current?.shapeId
    if (currentId != null && (resolveShapeIdRef.current?.(currentId) ?? currentId) === shape.id) {
      textEditorRef.current?.focus()
      return
    }
    finishTextSession()
    const token = ++nextTextSession.current
    textSessionRef.current = {
      token,
      shapeId: shape.id,
      renderKey: shape.id,
      box: shape.data.box,
      text: shape.data.text ?? '',
      runs: shape.data.textRuns ?? [],
      style: shape.style
    }
    setDraftEditorSession(token)
    setSelectedId(shape.id)
    setEditingId(shape.id)
    updateTextDraft(shape.data.text ?? '', shape.data.textRuns ?? [])
    setInlineFormatStyle(shape.style)
    setEditingBoxOverride(null)
  }, [activeTool, finishTextSession, interactive, updateTextDraft])

  const handleNaturalAspect = useCallback(
    (shape: DrawingShape, naturalAspect: number): void => {
      if (onRefineBox === undefined) return
      const active = gestureRef.current
      if (
        active !== null &&
        (active.kind === 'move' || active.kind === 'resize') &&
        (resolveShapeIdRef.current?.(active.shape.id) ?? active.shape.id) === shape.id
      ) {
        return
      }
      const box = shape.data.box
      if (box === undefined) return
      const healed = healedImageBox(box, aspect, naturalAspect)
      if (healed !== null) onRefineBox(shape.id, healed)
    },
    [aspect, onRefineBox]
  )

  // 손상 텍스트박스 자가 치유: 예전 리사이즈 버그가 커밋한 거대/이탈
  // 박스는 그 영역의 클릭을 전부 흡수한다 — 표면 안으로 무음 보정
  // (undo 미기록, onRefineBox 채널). 경계 클램프가 없는 표면은 제외.
  useEffect(() => {
    if (onRefineBox === undefined || !clampToBounds) return
    const active = gestureRef.current
    for (const shape of shapes) {
      if (shape.kind !== 'textbox' || shape.data.box === undefined) continue
      if (shape.id === editingId) continue
      if (active !== null && 'shape' in active && (resolveShapeIdRef.current?.(active.shape.id) ?? active.shape.id) === shape.id) {
        continue
      }
      const version = `${shape.id}:${shape.updatedAt}`
      if (healedVersions.current.has(version)) continue
      healedVersions.current.add(version)
      const healed = healedTextBox(shape.data.box)
      if (healed !== null) onRefineBox(shape.id, healed)
    }
  }, [clampToBounds, editingId, onRefineBox, shapes])

  const pointFromSample = useCallback((
    sample: PointerSample,
    clamp: boolean
  ): DrawingPoint | null => {
    const svg = svgRef.current
    return svg === null || !surfaceReady || !hasMeasuredBounds(svg)
      ? null
      : normalizedPoint(
        svg,
        sample.clientX,
        sample.clientY,
        sample.pressure,
        clamp
      )
  }, [surfaceReady])

  const eraseAt = useCallback((
    current: Extract<Gesture, { kind: 'erase' }>,
    point: DrawingPoint
  ): Gesture => {
    const ids = new Set(current.ids)
    for (const shape of shapes) {
      if (!ids.has(shape.id) && drawingHit(shape, point, aspect)) ids.add(shape.id)
    }
    return { ...current, ids }
  }, [aspect, shapes])

  const processSample = useCallback((sample: PointerSample): void => {
    const current = gestureRef.current
    if (current === null || current.pointerId !== sample.pointerId) return
    // 이동/리사이즈는 클램프 없이 — 포인터가 페이지를 벗어나도 델타가
    // 포화되지 않는다(결과 박스는 move/resizeDrawingBox 가 클램프).
    const isManipulation = current.kind === 'move' || current.kind === 'resize'
    const point = pointFromSample(sample, clampToBounds && !isManipulation)
    if (point === null) return
    if (current.kind === 'stroke') {
      const previous = current.points[current.points.length - 1]
      if (
        previous !== undefined &&
        Math.hypot(point.x - previous.x, point.y - previous.y) < 0.0005
      ) {
        return
      }
      setGesture({ ...current, points: [...current.points, point] })
    } else if (current.kind === 'shape') {
      setGesture({ ...current, end: point })
    } else if (current.kind === 'erase') {
      setGesture(eraseAt(current, point))
    } else {
      const original = current.shape.data.box
      if (original === undefined) return
      const travelledPx = Math.hypot(
        sample.clientX - current.originClient.x,
        sample.clientY - current.originClient.y
      )
      if (travelledPx < CLICK_TOLERANCE_PX) {
        setGesture({ ...current, box: original, moved: false })
        return
      }
      const dx = point.x - current.start.x
      const dy = point.y - current.start.y
      const box = current.kind === 'move'
        ? moveDrawingBox(original, dx, dy, clampToBounds)
        : resizeDrawingBox(
            original,
            dx,
            dy,
            clampToBounds,
            current.handle,
            ASPECT_LOCKED_KINDS.has(current.shape.kind),
            aspect
          )
      setGesture({ ...current, box, moved: true })
    }
  }, [aspect, clampToBounds, eraseAt, pointFromSample, setGesture])

  const flushPointerFrame = useCallback((): void => {
    if (pointerFrame.current !== null) cancelAnimationFrame(pointerFrame.current)
    pointerFrame.current = null
    const sample = pendingSample.current
    pendingSample.current = null
    if (sample !== null) processSample(sample)
  }, [processSample])

  useEffect(() => () => {
    if (pointerFrame.current !== null) cancelAnimationFrame(pointerFrame.current)
  }, [])

  useLayoutEffect(() => {
    finishTextSession()
    setGesture(null)
    // Selection remains meaningful while moving between the two object tools.
    // Clearing it on every text → select transition raced the first click on
    // the object and made that click appear to do nothing.
    if (activeTool !== 'select' && activeTool !== 'text') setSelectedId(null)
    setNewTextBox(null)
    setEditingBoxOverride(null)
    updateTextDraft('', [])
    setInlineFormatStyle(null)
  }, [activeTool, finishTextSession, setGesture, updateTextDraft])

  // 패널이 비활성이 되면 선택도 내려놓는다 — 키보드 삭제 대상에서 제외.
  useEffect(() => {
    if (!interactive) {
      finishTextSession()
      setSelectedId(null)
      setGesture(null)
    }
  }, [finishTextSession, interactive, setGesture])

  useEffect(() => () => finishTextSession(), [finishTextSession])

  // Pointer handlers preserve focus during object manipulation. Commit an
  // editor before another page/panel takes ownership even if no blur follows.
  useEffect(() => {
    const outsidePointerDown = (event: PointerEvent): void => {
      const target = event.target
      if (!(target instanceof Node) || isInsideTextFormatRow(target)) return
      if (svgRef.current?.contains(target)) return
      finishTextSession()
    }
    document.addEventListener('pointerdown', outsidePointerDown, true)
    return () => document.removeEventListener('pointerdown', outsidePointerDown, true)
  }, [finishTextSession])

  useLayoutEffect(() => {
    if (editingId !== null && !shapes.some((shape) => shape.id === editingId)) {
      const resolved = resolveShapeId?.(editingId) ?? editingId
      const session = textSessionRef.current
      if (session !== null && resolved !== editingId && shapes.some((shape) => shape.id === resolved)) {
        session.shapeId = resolved
        setEditingId(resolved)
        setSelectedId(resolved)
      } else {
        finishTextSession(undefined, true)
        setSelectedId(null)
      }
    } else if (selectedId !== null && !shapes.some((shape) => shape.id === selectedId)) {
      const resolved = resolveShapeId?.(selectedId) ?? selectedId
      setSelectedId(shapes.some((shape) => shape.id === resolved) ? resolved : null)
    }
  }, [editingId, finishTextSession, resolveShapeId, selectedId, shapes])

  useEffect(() => {
    const priorIds = previousShapeIds.current
    previousShapeIds.current = new Set(shapes.map((shape) => shape.id))
    if (activeTool !== 'select') return
    const addedImage = [...shapes].reverse().find((shape) =>
      shape.kind === 'image' && !priorIds.has(shape.id)
    )
    if (addedImage !== undefined) setSelectedId(addedImage.id)
  }, [activeTool, shapes])

  // 바깥 클릭 = 선택 해제. PDF 에서는 svg 루트가 pointer-events:none 이라
  // 루트 클릭 핸들러가 못 받으므로 document 캡처로 처리한다.
  // 서식 바는 svg 밖의 형제 HTML 이지만 "안쪽"이다 — 해제하면 안 된다.
  useEffect(() => {
    if (selectedId === null) return
    const onPointerDown = (event: PointerEvent): void => {
      const svg = svgRef.current
      const target = event.target
      if (svg === null || !(target instanceof Node)) return
      if (isInsideTextFormatRow(target)) return
      if (!svg.contains(target) || target === svg) setSelectedId(null)
    }
    document.addEventListener('pointerdown', onPointerDown, true)
    return () => document.removeEventListener('pointerdown', onPointerDown, true)
  }, [selectedId])

  // Backspace/Delete = 선택 셰이프 삭제 (undo 는 onRemove 경로가 기록).
  useEffect(() => {
    if (!interactive || selectedId === null) return
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key !== 'Backspace' && event.key !== 'Delete') return
      if (isEditableTarget(event.target)) return
      if (editingId !== null || newTextBox !== null) return
      if (gestureRef.current !== null) return
      event.preventDefault()
      onRemove([selectedId])
      setSelectedId(null)
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [editingId, interactive, newTextBox, onRemove, selectedId])

  const startTextBox = useCallback((point: DrawingPoint): void => {
    setSelectedId(null)
    const previous = textSessionRef.current
    const style = previous?.shapeId === null && previous.text.trim().length === 0
      ? previous.style
      : drawingStyle('text', width, opacity, color)
    finishTextSession()
    const box = textBoxAtClick(
      point, aspect, baseWidthPx, style.fontScale, clampToBounds,
      style.fontSizePt, surfaceWidthPt
    )
    const token = ++nextTextSession.current
    textSessionRef.current = { token, shapeId: null, renderKey: null, box, text: '', runs: [], style }
    setDraftEditorSession(token)
    updateTextDraft('', [])
    setInlineFormatStyle(null)
    setDraftStyle(style)
    setNewTextBox(box)
  }, [aspect, baseWidthPx, clampToBounds, color, finishTextSession, opacity,
    surfaceWidthPt, updateTextDraft, width])

  const handlePointerDown = useCallback((event: ReactPointerEvent<SVGSVGElement>): void => {
    if (!interactive || event.button !== 0) return
    if (activeTool === 'select') {
      if (event.target === event.currentTarget) setSelectedId(null)
      return
    }
    if (!surfaceReady || !hasMeasuredBounds(event.currentTarget)) return
    if (activeTool === 'text' && textSessionRef.current?.shapeId != null) {
      finishTextSession()
      return
    }
    const point = normalizedPoint(
      event.currentTarget,
      event.clientX,
      event.clientY,
      event.pressure,
      clampToBounds
    )
    if (activeTool === 'text') {
      // Without this, the pointer event's default focus move runs after
      // autoFocus and immediately blurs/discards the empty local draft.
      event.preventDefault()
      startTextBox(point)
      return
    }
    event.preventDefault()
    event.currentTarget.setPointerCapture(event.pointerId)
    if (activeTool === 'pen' || activeTool === 'highlighter') {
      setGesture({
        kind: 'stroke',
        pointerId: event.pointerId,
        tool: activeTool,
        points: [point]
      })
    } else if (SHAPE_TOOLS.includes(activeTool as ShapeTool)) {
      setGesture({
        kind: 'shape',
        pointerId: event.pointerId,
        tool: activeTool as ShapeTool,
        start: point,
        end: point
      })
    } else if (activeTool === 'eraser') {
      setGesture(eraseAt({ kind: 'erase', pointerId: event.pointerId, ids: new Set() }, point))
    }
  }, [activeTool, clampToBounds, eraseAt, finishTextSession, interactive,
    setGesture, startTextBox, surfaceReady])

  const handlePointerMove = useCallback((event: ReactPointerEvent<SVGSVGElement>): void => {
    if (gestureRef.current === null) return
    pendingSample.current = {
      pointerId: event.pointerId,
      clientX: event.clientX,
      clientY: event.clientY,
      pressure: event.pressure
    }
    if (pointerFrame.current === null) {
      pointerFrame.current = requestAnimationFrame(() => {
        pointerFrame.current = null
        const sample = pendingSample.current
        pendingSample.current = null
        if (sample !== null) processSample(sample)
      })
    }
  }, [processSample])

  const commitGesture = useCallback((completed: Gesture): void => {
    if (completed.kind === 'stroke') {
      const kind: DrawingKind = completed.tool === 'pen' ? 'ink' : 'highlighter'
      const nextStyle = drawingStyle(completed.tool, width, opacity, color)
      if (
        !surfaceReady ||
        strokePath(
          completed.points,
          nextStyle,
          aspect,
          completed.tool === 'highlighter'
        ).length === 0
      ) {
        return
      }
      onCreate({
        kind,
        data: { points: completed.points },
        style: nextStyle
      })
    } else if (completed.kind === 'shape') {
      if (!surfaceReady) return
      const box = normalizedBox(completed.start, completed.end)
      const length = Math.hypot(
        completed.end.x - completed.start.x,
        (completed.end.y - completed.start.y) * aspect
      )
      if (
        (completed.tool === 'line' || completed.tool === 'arrow')
          ? length < 0.002
          : box.width < 0.002 || box.height < 0.002
      ) {
        return
      }
      const data = completed.tool === 'line' || completed.tool === 'arrow'
        ? { box, points: [completed.start, completed.end] }
        : { box }
      onCreate({
        kind: completed.tool,
        data,
        style: drawingStyle(completed.tool, width, opacity, color)
      })
    } else if (completed.kind === 'erase') {
      if (completed.ids.size > 0) onRemove([...completed.ids])
    } else {
      const original = completed.shape.data.box
      if (original === undefined || !completed.moved) {
        // text 툴에서 무변위 클릭 = 즉시 편집 (더블클릭 불필요 — 워드/키노트
        // 관례). select 툴은 선택만 유지.
        if (
          completed.kind === 'move' &&
          completed.shape.kind === 'textbox' &&
          activeTool === 'text'
        ) {
          startEditing(shapesRef.current.find((shape) => shape.id ===
            (resolveShapeIdRef.current?.(completed.shape.id) ?? completed.shape.id)) ?? completed.shape)
        }
        return
      }
      const targetId = resolveShapeIdRef.current?.(completed.shape.id) ?? completed.shape.id
      const latest = shapesRef.current.find((shape) => shape.id === targetId)
      if (latest === undefined) return
      const nextData: DrawingShape['data'] = {
        ...latest.data,
        box: completed.box
      }
      // 선/화살표의 실좌표는 points 다 — box 만 옮기면 그림이 안 따라온다.
      if (
        completed.kind === 'move' &&
        (completed.shape.kind === 'line' || completed.shape.kind === 'arrow') &&
        completed.shape.data.points !== undefined
      ) {
        const dx = completed.box.x - original.x
        const dy = completed.box.y - original.y
        nextData.points = completed.shape.data.points.map((point) => ({
          ...point,
          x: point.x + dx,
          y: point.y + dy
        }))
      }
      // 텍스트박스 리사이즈 = 줄바꿈 재배치(글자 크기 불변). 좁힌 폭에 내용이
      // 안 들어가면 높이를 내용에 맞춰 키운다 — 타이핑 자동 성장과 같은 규칙.
      if (completed.kind === 'resize' && completed.shape.kind === 'textbox') {
        const content = svgRef.current?.querySelector<HTMLElement>(
          `[data-textbox-id="${targetId}"]`
        )
        if (content !== null && content !== undefined) {
          const fitted = fittedTextBox(content.scrollHeight, completed.box, baseWidthPx, aspect, clampToBounds)
          if (fitted !== null && fitted.height >= completed.box.height) nextData.box = fitted
        }
      }
      onUpdate(targetId, { data: nextData })
    }
  }, [activeTool, aspect, baseWidthPx, clampToBounds, color, onCreate, onRemove, onUpdate,
    opacity, startEditing, surfaceReady, width])

  const handlePointerUp = useCallback((event: ReactPointerEvent<SVGSVGElement>): void => {
    pendingSample.current = {
      pointerId: event.pointerId,
      clientX: event.clientX,
      clientY: event.clientY,
      pressure: event.pressure
    }
    flushPointerFrame()
    const completed = gestureRef.current
    setGesture(null)
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
    if (completed !== null) commitGesture(completed)
  }, [commitGesture, flushPointerFrame, setGesture])

  const handlePointerCancel = useCallback((): void => {
    pendingSample.current = null
    if (pointerFrame.current !== null) cancelAnimationFrame(pointerFrame.current)
    pointerFrame.current = null
    setGesture(null)
  }, [setGesture])

  const beginManipulation = useCallback((
    event: ReactPointerEvent<Element>,
    shape: DrawingShape,
    kind: 'move' | 'resize',
    handle: ResizeHandle = 'se'
  ): void => {
    if (!interactive || event.button !== 0) return
    // select 툴 = 범용 조작(선/화살표는 이동만), text 툴 = 텍스트박스만.
    const canManipulate =
      (activeTool === 'select' &&
        SELECTABLE_KINDS.has(shape.kind) &&
        (kind === 'move' ||
          (shape.kind !== 'line' && shape.kind !== 'arrow'))) ||
      (activeTool === 'text' && shape.kind === 'textbox')
    if (
      !canManipulate ||
      !surfaceReady ||
      (editingId !== null && (resolveShapeId?.(editingId) ?? editingId) === shape.id) ||
      shape.data.box === undefined
    ) {
      return
    }
    event.stopPropagation()
    event.preventDefault()
    finishTextSession()
    setSelectedId(shape.id)
    const svg = svgRef.current
    if (svg === null) return
    svg.setPointerCapture(event.pointerId)
    // 시작점도 클램프 없이 — 샘플과 같은 좌표계여야 델타가 정확하다.
    const start = normalizedPoint(
      svg,
      event.clientX,
      event.clientY,
      event.pressure,
      false
    )
    const base = {
      pointerId: event.pointerId,
      shape,
      start,
      originClient: { x: event.clientX, y: event.clientY },
      moved: false,
      box: shape.data.box
    }
    setGesture(kind === 'resize'
      ? { kind, ...base, handle }
      : { kind, ...base })
  }, [activeTool, editingId, finishTextSession, interactive, resolveShapeId, setGesture, surfaceReady])

  /** 타이핑으로 내용이 넘치면 박스 높이를 따라 키운다 (로컬 프리뷰). */
  const growEditingBox = useCallback((
    scrollHeightPx: number,
    target: 'new' | 'existing',
    token: number
  ): void => {
    const session = textSessionRef.current
    if (session === null || session.token !== token) return
    const next = fittedTextBox(scrollHeightPx, session.box, baseWidthPx, aspect, clampToBounds)
    if (next === null) return
    session.box = next
    if (target === 'new') setNewTextBox(next)
    else setEditingBoxOverride(next)
  }, [aspect, baseWidthPx, clampToBounds])

  const textBoxContentStyle = useCallback((
    shapeStyle: DrawingStyle,
    contentStyle: CSSProperties
  ): CSSProperties => {
    const fontSize = textBoxFontPx(
      baseWidthPx,
      shapeStyle.fontScale,
      shapeStyle.fontSizePt,
      surfaceWidthPt
    )
    const typography: CSSProperties = {
      fontSize,
      opacity: shapeStyle.opacity,
      fontWeight: shapeStyle.bold === true ? 700 : 400,
      fontStyle: shapeStyle.italic === true ? 'italic' : 'normal',
      // Decorations belong to runs; a parent underline cannot be removed by a child.
      textDecoration: 'none',
      textAlign: shapeStyle.align ?? 'left',
      lineHeight: TEXT_LINE_HEIGHT,
      padding: `${TEXT_BOX_PADDING_EM}em`,
      borderWidth: `${TEXT_BOX_BORDER_EM}em`
    }
    return { ...contentStyle, ...typography }
  }, [baseWidthPx, surfaceWidthPt])

  useLayoutEffect(() => {
    if (pendingTextFitIds.current.size === 0 || svgRef.current === null) return
    const candidates = svgRef.current.querySelectorAll<HTMLElement>(
      '.ink-layer__textbox[data-textbox-id]'
    )
    for (const id of [...pendingTextFitIds.current]) {
      const element = [...candidates].find((candidate) => candidate.dataset.textboxId === id)
      const shape = shapes.find((candidate) => candidate.id === id)
      const box = shape?.data.box
      if (element === undefined || shape === undefined || box === undefined) continue
      const previousHeight = element.style.height
      element.style.height = 'auto'
      const contentHeight = element.getBoundingClientRect().height
      element.style.height = previousHeight
      pendingTextFitIds.current.delete(id)
      const fitted = fittedTextBox(contentHeight, box, baseWidthPx, aspect, clampToBounds)
      if (fitted === null) continue
      // The measured geometry is part of the format change, not another
      // user action. Undo should restore the previous style and box together.
      if (onRefineBox !== undefined) onRefineBox(id, fitted)
      else onUpdateRef.current(id, { data: { ...shape.data, box: fitted } })
    }
  }, [aspect, baseWidthPx, clampToBounds, onRefineBox, shapes])

  /**
   * 서식 행의 컨트롤이 포커스를 가져가 textarea 가 blur 되면(버튼은
   * mousedown 에서 preventDefault 하므로 사실상 range 입력만) 확정/취소를
   * 미룬다. 포커스가 행을 떠날 때 textarea 로 되돌려, 편집이 계속되고
   * 다음 바깥 클릭이 정상적으로 확정한다 — 편집 상태가 고아가 되지 않는다.
   */
  const deferBlurToFormatRow = (
    event: Pick<ReactFocusEvent<HTMLElement>, 'relatedTarget' | 'currentTarget'>
  ): boolean => {
    const next = event.relatedTarget ?? document.activeElement
    if (!isInsideTextFormatRow(next) || !(next instanceof Element)) return false
    const row = next.closest(`[${TEXT_FORMAT_ROW_ATTR}]`)
    if (!(row instanceof HTMLElement)) return false
    const editor = event.currentTarget
    const onFocusOut = (leave: FocusEvent): void => {
      if (isInsideTextFormatRow(leave.relatedTarget)) return
      row.removeEventListener('focusout', onFocusOut)
      if (editor.isConnected) editor.focus()
    }
    row.addEventListener('focusout', onFocusOut)
    return true
  }

  const erasedIds = gesture?.kind === 'erase' ? gesture.ids : new Set<string>()
  const style = drawingStyle(activeTool, width, opacity, color)
  const rootClassName = className === undefined ? 'ink-layer' : `ink-layer ${className}`

  // 서식 행 대상: 새 draft > 편집 중 > 선택된 텍스트박스(select/text 툴).
  // 제스처 중에도 유지한다 — 숨겼다 보였다 하면 툴바가 깜빡인다.
  const draftFallbackStyle = useMemo(
    () => drawingStyle('text', width, opacity, color),
    [color, opacity, width]
  )
  const draftOpen = newTextBox !== null
  const formatShapeId = editingId ??
    (activeTool === 'select' || activeTool === 'text' ? selectedId : null)
  const formatShape = draftOpen || formatShapeId === null
    ? undefined
    : shapes.find(
        (entry) => entry.id === formatShapeId && entry.kind === 'textbox'
      )
  const formatMode: TextFormatMode | null = !interactive
    ? null
    : draftOpen
      ? 'draft'
      : formatShape === undefined
        ? null
        : editingId === formatShape.id ? 'editing' : 'selected'
  const formatStyle = formatMode === 'draft'
    ? (inlineFormatStyle ?? draftStyle ?? draftFallbackStyle)
    : formatMode === 'editing'
      ? (inlineFormatStyle ?? formatShape?.style)
      : formatShape?.style
  const formatTargetId = formatShape?.id ?? null
  // 셀렉터로 구독 — target 이 바뀔 때마다 모든 페이지가 재렌더되지 않게.
  const publishFormat = useTextFormatStore((store) => store.publish)
  const clearFormat = useTextFormatStore((store) => store.clear)

  useEffect(() => {
    if (formatMode === null || formatStyle === undefined) {
      clearFormat(ownerId)
      return
    }
    if (formatMode === 'draft') {
      publishFormat({
        ownerId,
        mode: 'draft',
        style: formatStyle,
        apply: (patch) => {
          const session = textSessionRef.current
          if (session === null || session.shapeId !== null) return
          session.style = mergeTextStyle(session.style, patch)
          setDraftStyle(session.style)
        },
        applyInline: (patch) => textEditorRef.current?.apply(patch)
      })
      return
    }
    if (formatTargetId === null) {
      clearFormat(ownerId)
      return
    }
    publishFormat({
      ownerId,
      mode: formatMode,
      style: formatStyle,
      apply: (patch) => {
        const latest = shapesRef.current.find((entry) => entry.id === formatTargetId)
        if (latest === undefined) return
        if (
          'fontScale' in patch ||
          'fontSizePt' in patch ||
          'bold' in patch ||
          'italic' in patch
        ) {
          pendingTextFitIds.current.add(latest.id)
        }
        const data = { ...latest.data }
        const inlineFields = ['color', 'fontSizePt', 'bold', 'italic', 'underline', 'strike'] as const
        const changedFields = inlineFields.filter((field) => field in patch ||
          (field === 'fontSizePt' && 'fontScale' in patch))
        if (formatMode === 'selected' && changedFields.length > 0 && data.textRuns !== undefined) {
          const runs = normalizeTextRuns(data.text ?? '', data.textRuns.map((run) => {
            const style = { ...run.style }
            for (const field of changedFields) delete style[field]
            return { ...run, style }
          }))
          if (runs.length > 0) data.textRuns = runs
          else delete data.textRuns
        }
        onUpdateRef.current(latest.id, {
          style: mergeTextStyle(latest.style, patch),
          ...(formatMode === 'selected' && changedFields.length > 0 ? { data } : {})
        })
      },
      ...(formatMode === 'editing'
        ? { applyInline: (patch: Parameters<TextBoxEditorHandle['apply']>[0]) =>
            textEditorRef.current?.apply(patch) }
        : {})
    })
  }, [
    clearFormat,
    draftFallbackStyle,
    formatMode,
    formatStyle,
    formatTargetId,
    ownerId,
    publishFormat
  ])

  // 언마운트(탭 닫힘·페이지 가상화)에서 내 대상만 지운다.
  useEffect(() => () => clearFormat(ownerId), [clearFormat, ownerId])

  const selectionFrame = (box: DrawingBox): JSX.Element => (
    <rect
      className="ink-layer__selection-frame"
      x={box.x}
      y={box.y}
      width={box.width}
      height={box.height}
      vectorEffect="non-scaling-stroke"
    />
  )

  return (
    <svg
      ref={svgRef}
      className={rootClassName}
      viewBox="0 0 1 1"
      preserveAspectRatio="none"
      aria-label={ariaLabel}
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerCancel}
      onClick={(event) => event.stopPropagation()}
      onDoubleClick={(event) => {
        // Pointer capture retargets the click sequence to the SVG. Resolve the
        // object geometrically so a selection-tool double click still edits it.
        event.stopPropagation()
        if (!surfaceReady || !hasMeasuredBounds(event.currentTarget)) return
        const point = normalizedPoint(event.currentTarget, event.clientX, event.clientY, 0.5, false)
        const selected = selectedId === null ? undefined : shapesRef.current.find((entry) =>
          entry.id === (resolveShapeId?.(selectedId) ?? selectedId))
        if (selected !== undefined && selected.kind !== 'textbox') return
        const shape = [...shapesRef.current].reverse().find((entry) =>
          entry.kind === 'textbox' && isRenderableBox(entry.data.box) &&
          (entry.data.text ?? '').trim().length > 0 && drawingHit(entry, point, aspect)
        )
        if (shape !== undefined) startEditing(shape)
      }}
    >
      {shapes.filter((shape) => !erasedIds.has(shape.id)).map((shape) => {
        if (!surfaceReady) return null
        const markColor = drawingColorVariable(shape.style.color)
        const isSelected = selectedId === shape.id && activeTool === 'select'
        const selectProps = activeTool === 'select' && SELECTABLE_KINDS.has(shape.kind)
          ? {
              onPointerDown: (event: ReactPointerEvent<Element>) =>
                beginManipulation(event, shape, 'move')
            }
          : {}
        if (shape.kind === 'ink' || shape.kind === 'highlighter') {
          return <InkStroke key={shape.id} shape={shape} aspect={aspect} />
        }
        const box = boxForShape(shape, gesture, resolveShapeId)
        if (shape.kind === 'rect' && isRenderableBox(box)) {
          return (
            <g key={shape.id}>
              <rect className="ink-layer__mark ink-layer__mark--selectable" {...box} fill="none" stroke={markColor} strokeWidth={shape.style.width} opacity={shape.style.opacity} {...selectProps} />
              {isSelected && selectionFrame(box)}
              {isSelected && (
                <ResizeHandles
                  className="ink-layer__shape-resize"
                  box={box}
                  aspect={aspect}
                  baseWidthPx={baseWidthPx}
                  onPointerDown={(event, handle) =>
                    beginManipulation(event, shape, 'resize', handle)}
                />
              )}
            </g>
          )
        }
        if (shape.kind === 'ellipse' && isRenderableBox(box)) {
          return (
            <g key={shape.id}>
              <ellipse className="ink-layer__mark ink-layer__mark--selectable" cx={box.x + box.width / 2} cy={box.y + box.height / 2} rx={box.width / 2} ry={box.height / 2} fill="none" stroke={markColor} strokeWidth={shape.style.width} opacity={shape.style.opacity} {...selectProps} />
              {isSelected && selectionFrame(box)}
              {isSelected && (
                <ResizeHandles
                  className="ink-layer__shape-resize"
                  box={box}
                  aspect={aspect}
                  baseWidthPx={baseWidthPx}
                  onPointerDown={(event, handle) =>
                    beginManipulation(event, shape, 'resize', handle)}
                />
              )}
            </g>
          )
        }
        if (shape.kind === 'line' || shape.kind === 'arrow') {
          const endpoints = lineEndpoints(shape)
          if (
            endpoints === null ||
            !isRenderableSegment(endpoints[0], endpoints[1], aspect)
          ) {
            return null
          }
          // 이동 프리뷰: 제스처 box 오프셋을 좌표에 반영한다.
          const original = shape.data.box
          const offsetX = box !== undefined && original !== undefined
            ? box.x - original.x
            : 0
          const offsetY = box !== undefined && original !== undefined
            ? box.y - original.y
            : 0
          const from = {
            ...endpoints[0],
            x: endpoints[0].x + offsetX,
            y: endpoints[0].y + offsetY
          }
          const to = {
            ...endpoints[1],
            x: endpoints[1].x + offsetX,
            y: endpoints[1].y + offsetY
          }
          return (
            <g key={shape.id} className="ink-layer__mark ink-layer__mark--selectable" stroke={markColor} strokeWidth={shape.style.width} opacity={shape.style.opacity} strokeLinecap="round" strokeLinejoin="round" fill="none" {...selectProps}>
              <line x1={from.x} y1={from.y} x2={to.x} y2={to.y} />
              {shape.kind === 'arrow' && <polyline points={arrowHeadPoints(from, to, shape.style.width, aspect)} />}
              {isSelected && isRenderableBox(box) && selectionFrame(box)}
            </g>
          )
        }
        if ((shape.kind === 'clip' || shape.kind === 'image') && isRenderableBox(box)) {
          return (
            <ReferencedShape
              key={shape.id}
              shape={shape}
              box={box}
              aspect={aspect}
              baseWidthPx={baseWidthPx}
              courseId={courseId}
              boardId={boardId}
              selected={isSelected}
              renderClip={renderClip}
              onOpenClip={onOpenClip}
              onBeginManipulation={beginManipulation}
              onNaturalAspect={handleNaturalAspect}
            />
          )
        }
        if (shape.kind !== 'textbox' || !isRenderableBox(box)) return null
        const isEditing = editingId !== null && (resolveShapeId?.(editingId) ?? editingId) === shape.id
        if (!isEditing && (shape.data.text ?? '').trim().length === 0) return null
        const editedBox = isEditing && editingBoxOverride !== null
          ? editingBoxOverride
          : box
        const foreignLayout = foreignObjectLayout(editedBox, baseWidthPx, aspect)
        if (foreignLayout === null) return null
        // 리사이즈 중 글자 크기는 고정 — editedBox 가 제스처 박스라 줄바꿈이
        // 라이브로 재배치된다.
        const contentStyle = textBoxContentStyle(
          shape.style,
          foreignLayout.contentStyle
        )
        const textSelected =
          selectedId === shape.id &&
          (activeTool === 'select' || activeTool === 'text')
        return (
          <g key={isEditing ? textSessionRef.current?.renderKey ?? shape.id : shape.id}
            className="ink-layer__textbox-group" data-shape-id={shape.id}>
            <foreignObject
              {...foreignLayout.objectProps}
              className="ink-layer__textbox-object"
              onPointerDown={(event) => beginManipulation(event, shape, 'move')}
              onDoubleClick={(event) => {
                event.stopPropagation()
                startEditing(shape)
              }}
            >
              {isEditing ? (
                <TextBoxEditor
                  key={draftEditorSession}
                  autoFocus
                  ref={textEditorRef}
                  text={textDraft}
                  runs={textRunsDraft}
                  baseStyle={shape.style}
                  baseWidthPx={baseWidthPx}
                  surfaceWidthPt={surfaceWidthPt}
                  contentStyle={contentStyle}
                  color={shape.style.color}
                  {...(shape.style.fill === undefined ? {} : { fill: shape.style.fill })}
                  onChange={(nextText, nextRuns, scrollHeight) => {
                    if (textSessionRef.current?.token !== draftEditorSession) return
                    updateTextDraft(nextText, nextRuns)
                    growEditingBox(
                      scrollHeight,
                      'existing',
                      draftEditorSession
                    )
                  }}
                  onSelectionStyleChange={(style) => {
                    if (textSessionRef.current?.token === draftEditorSession) setInlineFormatStyle(style)
                  }}
                  onBlur={(event) => {
                    if (deferBlurToFormatRow(event)) return
                    finishTextSession(draftEditorSession)
                  }}
                  onCancel={() => finishTextSession(draftEditorSession, true)}
                  onCommit={() => finishTextSession(draftEditorSession)}
                />
              ) : (
                <div
                  className="ink-layer__textbox"
                  data-color={shape.style.color}
                  data-fill={shape.style.fill}
                  data-textbox-id={shape.id}
                  style={contentStyle}
                >
                  {renderTextRuns(
                    shape.data.text ?? '',
                    shape.data.textRuns,
                    baseWidthPx,
                    surfaceWidthPt,
                    shape.style
                  )}
                </div>
              )}
            </foreignObject>
            {!isEditing && (
              <rect
                className="ink-layer__textbox-hit-target ink-layer__mark--selectable"
                x={editedBox.x}
                y={editedBox.y}
                width={editedBox.width}
                height={editedBox.height}
                fill="transparent"
                strokeWidth={0}
                pointerEvents="fill"
                onPointerDown={(event) => beginManipulation(event, shape, 'move')}
                onDoubleClick={(event) => {
                  event.stopPropagation()
                  startEditing(shape)
                }}
              />
            )}
            {textSelected && !isEditing && selectionFrame(editedBox)}
            {textSelected && !isEditing && (
              <ResizeHandles
                className="ink-layer__textbox-resize"
                box={editedBox}
                aspect={aspect}
                baseWidthPx={baseWidthPx}
                fill={markColor}
                handles={TEXTBOX_HANDLES}
                onPointerDown={(event, handle) =>
                  beginManipulation(event, shape, 'resize', handle)}
              />
            )}
          </g>
        )
      })}

      {newTextBox !== null && surfaceReady && isRenderableBox(newTextBox) && (() => {
        const foreignLayout = foreignObjectLayout(newTextBox, baseWidthPx, aspect)
        if (foreignLayout === null) return null
        return (
          <foreignObject
            {...foreignLayout.objectProps}
            className="ink-layer__textbox-object"
            onPointerDown={(event) => event.stopPropagation()}
          >
            <TextBoxEditor
              key={draftEditorSession}
              autoFocus
              ref={textEditorRef}
              text={textDraft}
              runs={textRunsDraft}
              baseStyle={draftStyle ?? drawingStyle('text', width, opacity, color)}
              baseWidthPx={baseWidthPx}
              surfaceWidthPt={surfaceWidthPt}
              contentStyle={textBoxContentStyle(
                draftStyle ?? drawingStyle('text', width, opacity, color),
                foreignLayout.contentStyle
              )}
              color={draftStyle?.color ?? color}
              {...(draftStyle?.fill === undefined ? {} : { fill: draftStyle.fill })}
              onChange={(nextText, nextRuns, scrollHeight) => {
                if (textSessionRef.current?.token !== draftEditorSession) return
                updateTextDraft(nextText, nextRuns)
                growEditingBox(scrollHeight, 'new', draftEditorSession)
              }}
              onSelectionStyleChange={(style) => {
                if (textSessionRef.current?.token === draftEditorSession) setInlineFormatStyle(style)
              }}
              onBlur={(event) => {
                if (deferBlurToFormatRow(event)) return
                finishTextSession(draftEditorSession)
              }}
              onCancel={() => finishTextSession(draftEditorSession, true)}
              onCommit={() => finishTextSession(draftEditorSession)}
            />
          </foreignObject>
        )
      })()}

      {gesture?.kind === 'stroke' && (() => {
        const path = strokePath(
          gesture.points,
          style,
          aspect,
          gesture.tool === 'highlighter'
        )
        return path.length === 0
          ? null
          : (
              <path
                className={gesture.tool === 'highlighter'
                  ? 'ink-layer__preview is-highlighter'
                  : 'ink-layer__preview'}
                d={path}
                fill={drawingColorVariable(style.color)}
                opacity={style.opacity}
              />
            )
      })()}
      {gesture?.kind === 'shape' && (() => {
        const box = normalizedBox(gesture.start, gesture.end)
        const previewColor = drawingColorVariable(style.color)
        if (gesture.tool === 'rect') {
          return isRenderableBox(box)
            ? <rect className="ink-layer__preview" {...box} fill="none" stroke={previewColor} strokeWidth={style.width} opacity={style.opacity} />
            : null
        }
        if (gesture.tool === 'ellipse') {
          return isRenderableBox(box)
            ? <ellipse className="ink-layer__preview" cx={box.x + box.width / 2} cy={box.y + box.height / 2} rx={box.width / 2} ry={box.height / 2} fill="none" stroke={previewColor} strokeWidth={style.width} opacity={style.opacity} />
            : null
        }
        if (!isRenderableSegment(gesture.start, gesture.end, aspect)) return null
        return (
          <g className="ink-layer__preview" fill="none" stroke={previewColor} strokeWidth={style.width} opacity={style.opacity} strokeLinecap="round" strokeLinejoin="round">
            <line x1={gesture.start.x} y1={gesture.start.y} x2={gesture.end.x} y2={gesture.end.y} />
            {gesture.tool === 'arrow' && <polyline points={arrowHeadPoints(gesture.start, gesture.end, style.width, aspect)} />}
          </g>
        )
      })()}
    </svg>
  )
}
