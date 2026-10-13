import type {
  MouseEvent as ReactMouseEvent,
  PointerEvent as ReactPointerEvent
} from 'react'
import {
  DRAWING_COLORS,
  TEXT_ALIGNS,
  type DrawingColor,
  type TextAlign
} from '../../../../shared/types/drawing'
import {
  TEXT_DEFAULT_FONT_PT,
  TEXT_FONT_PT_LIMITS,
  clampFontPt,
  steppedFontPt
} from '../../../../shared/textBoxMetrics'
import {
  TEXT_FORMAT_ROW_ATTR,
  useTextFormatStore,
  type TextStylePatch
} from './textFormatStore'
import './textFormatRow.css'

const COLOR_LABELS: Record<DrawingColor, string> = {
  ink: '기본',
  red: '빨강',
  orange: '주황',
  yellow: '노랑',
  green: '초록',
  blue: '파랑',
  violet: '보라'
}

const TEXT_FORMAT_ROW_ATTRIBUTE = { [TEXT_FORMAT_ROW_ATTR]: '' }

function preserveEditingMouse(event: ReactMouseEvent): void {
  event.preventDefault()
}

function preserveEditingPointer(event: ReactPointerEvent): void {
  event.preventDefault()
}

const PRESERVE_EDITING_HANDLERS = {
  onMouseDown: preserveEditingMouse,
  onPointerDown: preserveEditingPointer
}

type BooleanTextStyle = 'bold' | 'italic' | 'underline' | 'strike'

function applyAtEvent(patch: TextStylePatch): void {
  useTextFormatStore.getState().target?.apply(patch)
}

function applyInlineAtEvent(patch: TextStylePatch): void {
  const target = useTextFormatStore.getState().target
  if (target === null) return
  ;(target.applyInline ?? target.apply)(patch)
}

function clearFillAtEvent(): void {
  // `undefined` deletes the key — see `TextStylePatch`.
  applyAtEvent({ fill: undefined })
}

function toggleAtEvent(key: BooleanTextStyle): void {
  const currentTarget = useTextFormatStore.getState().target
  if (currentTarget === null) return
  ;(currentTarget.applyInline ?? currentTarget.apply)({
    [key]: currentTarget.style[key] !== true
  })
}

function stepAtEvent(direction: 1 | -1): void {
  const currentTarget = useTextFormatStore.getState().target
  if (currentTarget === null) return
  const current = currentTarget.style.fontSizePt ??
    (currentTarget.style.fontScale ?? 1) * TEXT_DEFAULT_FONT_PT
  ;(currentTarget.applyInline ?? currentTarget.apply)({
    fontScale: undefined,
    fontSizePt: steppedFontPt(current, direction)
  })
}

function setPointAtEvent(value: number): void {
  if (!Number.isFinite(value)) return
  applyInlineAtEvent({ fontScale: undefined, fontSizePt: clampFontPt(value) })
}

function AlignIcon({ align }: { align: TextAlign }): JSX.Element {
  const starts = align === 'left'
    ? [3, 3, 3]
    : align === 'center'
      ? [3, 6, 4.5]
      : [3, 9, 6]
  const ends = align === 'left'
    ? [21, 15, 18]
    : align === 'center'
      ? [21, 18, 19.5]
      : [21, 21, 21]

  return (
    <svg
      className="ink-format-row__align-icon"
      viewBox="0 0 24 24"
      width="1em"
      height="1em"
      aria-hidden="true"
    >
      {[7, 12, 17].map((y, index) => (
        <path
          key={y}
          d={`M ${starts[index]} ${y} H ${ends[index]}`}
          fill="none"
          stroke="currentColor"
          strokeLinecap="round"
        />
      ))}
    </svg>
  )
}

export interface TextFormatRowProps {
  visible?: boolean
}

export function TextFormatRow({
  visible = false
}: TextFormatRowProps): JSX.Element | null {
  const target = useTextFormatStore((state) => state.target)
  if (target === null && !visible) return null

  const style = target?.style
  const disabled = target === null
  const pointSize = Math.round(
    style?.fontSizePt ?? (style?.fontScale ?? 1) * TEXT_DEFAULT_FONT_PT
  )
  const alignment = style?.align ?? 'left'

  return (
    <div
      className="ink-format-row"
      role="toolbar"
      aria-label="텍스트 서식"
      {...TEXT_FORMAT_ROW_ATTRIBUTE}
    >
      <div
        className="ink-format-row__group"
        role="group"
        aria-label="글자 크기"
      >
        <button
          type="button"
          className="ink-format-row__button"
          aria-label="글자 작게"
          title="글자 작게"
          disabled={disabled || pointSize <= TEXT_FONT_PT_LIMITS.min}
          {...PRESERVE_EDITING_HANDLERS}
          onClick={() => stepAtEvent(-1)}
        >
          −
        </button>
        <label className="ink-format-row__point">
          <span className="sr-only">글자 크기(포인트)</span>
          <input
            type="number"
            min={TEXT_FONT_PT_LIMITS.min}
            max={TEXT_FONT_PT_LIMITS.max}
            value={pointSize}
            disabled={disabled}
            aria-label="글자 크기(포인트)"
            onPointerDown={(event) => event.stopPropagation()}
            onMouseDown={(event) => event.stopPropagation()}
            onChange={(event) => setPointAtEvent(event.currentTarget.valueAsNumber)}
            onBlur={(event) => setPointAtEvent(event.currentTarget.valueAsNumber)}
          />
          <span aria-hidden="true">P</span>
        </label>
        <button
          type="button"
          className="ink-format-row__button"
          aria-label="글자 크게"
          title="글자 크게"
          disabled={disabled || pointSize >= TEXT_FONT_PT_LIMITS.max}
          {...PRESERVE_EDITING_HANDLERS}
          onClick={() => stepAtEvent(1)}
        >
          +
        </button>
      </div>

      <div
        className="ink-format-row__group"
        role="group"
        aria-label="글자 꾸미기"
      >
        <button
          type="button"
          className="ink-format-row__button ink-format-row__button--bold"
          aria-label="굵게"
          title="굵게"
          aria-pressed={style?.bold === true}
          disabled={disabled}
          {...PRESERVE_EDITING_HANDLERS}
          onClick={() => toggleAtEvent('bold')}
        >
          B
        </button>
        <button
          type="button"
          className="ink-format-row__button ink-format-row__button--italic"
          aria-label="기울임"
          title="기울임"
          aria-pressed={style?.italic === true}
          disabled={disabled}
          {...PRESERVE_EDITING_HANDLERS}
          onClick={() => toggleAtEvent('italic')}
        >
          I
        </button>
        <button
          type="button"
          className="ink-format-row__button ink-format-row__button--underline"
          aria-label="밑줄"
          title="밑줄"
          aria-pressed={style?.underline === true}
          disabled={disabled}
          {...PRESERVE_EDITING_HANDLERS}
          onClick={() => toggleAtEvent('underline')}
        >
          U
        </button>
        <button
          type="button"
          className="ink-format-row__button ink-format-row__button--strike"
          aria-label="취소선"
          title="취소선"
          aria-pressed={style?.strike === true}
          disabled={disabled}
          {...PRESERVE_EDITING_HANDLERS}
          onClick={() => toggleAtEvent('strike')}
        >
          S
        </button>
      </div>

      <div
        className="ink-format-row__group ink-format-row__align"
        role="group"
        aria-label="글자 정렬"
      >
        {TEXT_ALIGNS.map((align) => {
          const label = align === 'left'
            ? '왼쪽 정렬'
            : align === 'center'
              ? '가운데 정렬'
              : '오른쪽 정렬'
          return (
            <button
              key={align}
              type="button"
              className="ink-format-row__button"
              aria-label={label}
              title={label}
              aria-pressed={target !== null && alignment === align}
              disabled={disabled}
              {...PRESERVE_EDITING_HANDLERS}
              onClick={() => applyAtEvent({ align })}
            >
              <AlignIcon align={align} />
            </button>
          )
        })}
      </div>

      <div
        className="ink-format-row__group"
        role="group"
        aria-label="글자색"
      >
        {DRAWING_COLORS.map((color) => (
          <button
            key={color}
            type="button"
            className="ink-format-row__swatch"
            data-color={color}
            aria-label={COLOR_LABELS[color]}
            title={COLOR_LABELS[color]}
            aria-pressed={style?.color === color}
            disabled={disabled}
            {...PRESERVE_EDITING_HANDLERS}
            onClick={() => applyInlineAtEvent({ color })}
          />
        ))}
      </div>

      <div
        className="ink-format-row__group"
        role="group"
        aria-label="글자 배경"
      >
        <button
          type="button"
          className="ink-format-row__fill"
          data-color="none"
          aria-label="배경 없음"
          title="배경 없음"
          aria-pressed={target !== null && style?.fill === undefined}
          disabled={disabled}
          {...PRESERVE_EDITING_HANDLERS}
          onClick={clearFillAtEvent}
        >
          <span aria-hidden="true">×</span>
        </button>
        {DRAWING_COLORS.map((color) => (
          <button
            key={color}
            type="button"
            className="ink-format-row__fill"
            data-color={color}
            aria-label={`배경 ${COLOR_LABELS[color]}`}
            title={`배경 ${COLOR_LABELS[color]}`}
            aria-pressed={style?.fill === color}
            disabled={disabled}
            {...PRESERVE_EDITING_HANDLERS}
            onClick={() => applyAtEvent({ fill: color })}
          />
        ))}
      </div>

      <label className="ink-format-row__opacity">
        <span aria-hidden="true">◐</span>
        <input
          type="range"
          min={0.1}
          max={1}
          step={0.05}
          value={style?.opacity ?? 1}
          aria-label="글자 불투명도"
          disabled={disabled}
          onChange={(event) => {
            applyAtEvent({ opacity: Number(event.currentTarget.value) })
          }}
        />
      </label>
    </div>
  )
}
