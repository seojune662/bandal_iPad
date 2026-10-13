/**
 * Floating popovers for the PDF viewer, positioned in scroller-content
 * coordinates (so they travel with the page while scrolling):
 *
 * - SelectionPopover: the 4-color mini toolbar shown over fresh text
 *   selections.
 * - HighlightPopover: comment / recolor / delete editor for an existing
 *   highlight.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import { HIGHLIGHT_COLORS } from './useAnnotations'
import { createMemoDraft, normalizeMemo, type MemoDraft } from './lib/memoDraft'
import { Icon } from '../../app/icons'
import { TabKindIcon } from '../workspace/workspaceIcons'
import type {
  Annotation,
  HighlightColor
} from '../../../../shared/types/annotation'
import type { DrawingClipSource } from '../../../../shared/types/drawing'
import type { PersonalBoard } from '../../../../shared/types/whiteboard'
import { writeBandalClipDragData } from './clipTransfer'

const COLOR_LABEL: Record<HighlightColor, string> = {
  yellow: '노랑 형광펜',
  green: '초록 형광펜',
  pink: '분홍 형광펜',
  blue: '파랑 형광펜'
}

export interface ContentPoint {
  left: number
  top: number
}

/**
 * Closes on Escape and on pointer-down outside the popover.
 *
 * The pointer-down listener runs in the **capture** phase, which fires before
 * the browser moves focus — so anything the popover needs to persist must be
 * committed by `onDismiss` itself, never by a `blur` handler on a child that is
 * about to be unmounted (see ./lib/memoDraft.ts).
 *
 * `onEscape` defaults to `onDismiss`; pass it separately when Escape should
 * mean "cancel" rather than "close and keep".
 */
function useDismiss(
  onDismiss: () => void,
  onEscape?: () => void
): React.RefObject<HTMLDivElement> {
  const ref = useRef<HTMLDivElement>(null)
  // Latest-callback refs so the listeners attach once instead of re-binding on
  // every keystroke.
  const dismissRef = useRef(onDismiss)
  dismissRef.current = onDismiss
  const escapeRef = useRef(onEscape ?? onDismiss)
  escapeRef.current = onEscape ?? onDismiss

  useEffect(() => {
    const handlePointerDown = (event: PointerEvent): void => {
      const target = event.target
      if (
        ref.current !== null &&
        target instanceof Node &&
        !ref.current.contains(target)
      ) {
        dismissRef.current()
      }
    }
    const handleKeyDown = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') escapeRef.current()
    }
    document.addEventListener('pointerdown', handlePointerDown, true)
    document.addEventListener('keydown', handleKeyDown)
    return () => {
      document.removeEventListener('pointerdown', handlePointerDown, true)
      document.removeEventListener('keydown', handleKeyDown)
    }
  }, [])
  return ref
}

// -- selection toolbar ------------------------------------------------------

interface SelectionPopoverProps {
  position: ContentPoint
  clipSource: DrawingClipSource
  onPick: (color: HighlightColor) => void
  onDismiss: () => void
}

export function SelectionPopover({
  position,
  clipSource,
  onPick,
  onDismiss
}: SelectionPopoverProps): JSX.Element {
  const ref = useDismiss(onDismiss)
  return (
    <div
      ref={ref}
      className="pdf-popover pdf-popover--selection"
      role="toolbar"
      aria-label="형광펜 색상 선택"
      style={{ left: position.left, top: position.top }}
    >
      {HIGHLIGHT_COLORS.map((color) => (
        <button
          key={color}
          type="button"
          className="pdf-popover__swatch"
          data-color={color}
          aria-label={COLOR_LABEL[color]}
          title={COLOR_LABEL[color]}
          // Keep the text selection alive while clicking.
          onMouseDown={(event) => event.preventDefault()}
          onClick={() => onPick(color)}
        />
      ))}
      <button
        type="button"
        className="pdf-popover__clip-drag"
        draggable
        title="선택 영역을 화이트보드로 드래그"
        aria-label="선택 영역을 화이트보드로 보내기"
        onDragStart={(event) => writeBandalClipDragData(event.dataTransfer, clipSource)}
        onDragEnd={onDismiss}
      >
        <TabKindIcon kind="whiteboard" />
        화이트보드로 보내기
      </button>
    </div>
  )
}

// -- whiteboard destination ------------------------------------------------

interface WhiteboardPickerPopoverProps {
  boards: PersonalBoard[]
  position: ContentPoint
  onPick: (board: PersonalBoard) => void
  onCreate: () => void
  onDismiss: () => void
}

export function WhiteboardPickerPopover({
  boards,
  position,
  onPick,
  onCreate,
  onDismiss
}: WhiteboardPickerPopoverProps): JSX.Element {
  const ref = useDismiss(onDismiss)
  return (
    <div
      ref={ref}
      className="pdf-popover pdf-popover--edit"
      role="menu"
      aria-label="보낼 화이트보드 선택"
      style={{ left: position.left, top: position.top }}
    >
      {boards.map((board) => (
        <button
          key={board.id}
          type="button"
          className="pdf-popover__ask-ai"
          role="menuitem"
          onClick={() => onPick(board)}
        >
          {board.title}
        </button>
      ))}
      <button
        type="button"
        className="pdf-popover__ask-ai"
        role="menuitem"
        onClick={onCreate}
      >
        <TabKindIcon kind="whiteboard" />
        새 화이트보드
      </button>
    </div>
  )
}

// -- highlight editor -------------------------------------------------------

interface HighlightPopoverProps {
  annotation: Annotation
  position: ContentPoint
  isStale: boolean
  onChangeColor: (color: HighlightColor) => void
  onSaveComment: (comment: string | null) => void
  onDelete: () => void
  onDismiss: () => void
  /**
   * [M5] Prefill the course chat with this highlight (editable, not sent).
   * Receives the current comment draft so unsaved memo edits are included.
   */
  onAskAi: (draftComment: string | null) => void
  /** Appends this highlight and the current memo draft to a study note. */
  onSendToNote: (draftComment: string | null) => void
}

export function HighlightPopover({
  annotation,
  position,
  isStale,
  onChangeColor,
  onSaveComment,
  onDelete,
  onDismiss,
  onAskAi,
  onSendToNote
}: HighlightPopoverProps): JSX.Element {
  // The draft lives outside React state so that every exit path can persist the
  // latest value — including the capture-phase outside click, which unmounts
  // the textarea without ever firing `blur`.
  const saveRef = useRef(onSaveComment)
  saveRef.current = onSaveComment
  const memoRef = useRef<MemoDraft>()
  if (memoRef.current === undefined) {
    memoRef.current = createMemoDraft(annotation.comment, (comment) =>
      saveRef.current(comment)
    )
  }
  const memo = memoRef.current

  const [draft, setDraft] = useState(() => memo.value())
  // Escape with unsaved edits arms a confirm step instead of discarding
  // silently (STYLEGUIDE §8: destructive actions are two-step).
  const [isDiscardArmed, setIsDiscardArmed] = useState(false)
  const discardArmedRef = useRef(false)
  const isDirty = memo.isDirty()

  const armDiscard = useCallback((next: boolean): void => {
    discardArmedRef.current = next
    setIsDiscardArmed(next)
  }, [])

  // Adopt the persisted value when it changes underneath us (our own save
  // round-tripping, or the highlight edited from another surface). Never
  // clobbers live typing — see MemoDraft.syncSaved.
  const savedComment = annotation.comment
  useEffect(() => {
    memo.syncSaved(savedComment)
    setDraft(memo.value())
  }, [memo, savedComment])

  const commitAndDismiss = useCallback((): void => {
    memo.commit()
    onDismiss()
  }, [memo, onDismiss])

  const discardAndDismiss = useCallback((): void => {
    memo.abandon()
    onDismiss()
  }, [memo, onDismiss])

  const handleEscape = useCallback((): void => {
    if (!memo.isDirty()) {
      onDismiss()
      return
    }
    if (!discardArmedRef.current) {
      armDiscard(true)
      return
    }
    discardAndDismiss()
  }, [armDiscard, discardAndDismiss, memo, onDismiss])

  const ref = useDismiss(commitAndDismiss, handleEscape)

  // Belt and braces: the dismiss paths above already commit, but if this
  // popover is unmounted some other way the memo still lands. commit() is
  // idempotent and a no-op after abandon(), so the extra call is free.
  useEffect(() => {
    return () => {
      memo.commit()
    }
  }, [memo])

  const updateDraft = useCallback(
    (next: string): void => {
      memo.setValue(next)
      setDraft(next)
      if (discardArmedRef.current) armDiscard(false)
    },
    [armDiscard, memo]
  )

  return (
    <div
      ref={ref}
      className="pdf-popover pdf-popover--edit"
      role="dialog"
      aria-label="하이라이트 편집"
      style={{ left: position.left, top: position.top }}
    >
      <header className="pdf-popover__head">
        <div className="pdf-popover__swatches">
          {HIGHLIGHT_COLORS.map((color) => (
            <button
              key={color}
              type="button"
              className="pdf-popover__swatch"
              data-color={color}
              data-selected={color === annotation.color}
              aria-label={COLOR_LABEL[color]}
              aria-pressed={color === annotation.color}
              onClick={() => onChangeColor(color)}
            />
          ))}
        </div>
        <button
          type="button"
          className="pdf-popover__icon-button pdf-popover__delete"
          aria-label="하이라이트 삭제"
          title="삭제"
          onClick={() => {
            // The highlight is going away — do not resurrect its memo from the
            // unmount cleanup.
            memo.abandon()
            onDelete()
          }}
        >
          <Icon name="trash" />
        </button>
      </header>

      <blockquote className="pdf-popover__quote">
        {annotation.anchor.quote}
      </blockquote>
      {isStale && (
        <p
          className="pdf-popover__stale"
          title="문서가 바뀌어 이 인용을 원래 위치에서 찾지 못했어요."
        >
          위치가 정확하지 않을 수 있어요
        </p>
      )}

      <textarea
        className="pdf-popover__comment"
        placeholder="메모 남기기…"
        rows={3}
        value={draft}
        onChange={(event) => updateDraft(event.target.value)}
        onBlur={() => memo.commit()}
        onKeyDown={(event) => {
          if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
            event.preventDefault()
            commitAndDismiss()
          }
        }}
      />
      <div style={{ display: 'flex', gap: 'var(--space-2)' }}>
        <button
          type="button"
          className="pdf-popover__ask-ai"
          onClick={() => {
            memo.commit()
            onAskAi(normalizeMemo(memo.value()))
          }}
        >
          <TabKindIcon kind="chat" />
          AI에게 물어보기
        </button>
        <button
          type="button"
          className="pdf-popover__ask-ai"
          onClick={() => {
            memo.commit()
            onSendToNote(normalizeMemo(memo.value()))
          }}
        >
          <TabKindIcon kind="note" />
          필기로 보내기
        </button>
      </div>

      {isDiscardArmed && (
        <div className="pdf-popover__discard" role="alert">
          <span>메모를 저장하지 않고 닫을까요?</span>
          <div className="pdf-popover__discard-actions">
            <button
              type="button"
              className="pdf-popover__discard-drop"
              onClick={discardAndDismiss}
            >
              저장 안 함
            </button>
            <button
              type="button"
              className="pdf-popover__discard-keep"
              onClick={commitAndDismiss}
            >
              저장하고 닫기
            </button>
          </div>
        </div>
      )}

      <footer className="pdf-popover__foot">
        <span className="pdf-popover__hint">⌘↩ 저장 후 닫기</span>
        <button
          type="button"
          className="pdf-popover__save"
          disabled={!isDirty}
          onClick={commitAndDismiss}
        >
          저장
        </button>
      </footer>
    </div>
  )
}
