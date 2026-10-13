import { ContextChips } from './ContextChips'
import { AccessPolicyMenu } from './AccessPolicyMenu'
import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useRef,
  useState,
  type ClipboardEvent,
  type ReactNode,
  type KeyboardEvent
} from 'react'
import type { ChatAttachment } from '../../../../shared/types/chat'
import type {
  MaterialNode,
  MaterialSearchHit
} from '../../../../shared/types/materials'
import { invoke } from '../../lib/ipc'
import type { ChatQuote } from './chatPromptBus'
import type { LimitInfo } from './chatModel'
import './composer.css'
import { AddMenu } from './AddMenu'
import { consumeComposerDraft, draftContext, updateComposerDraft, useComposerDraft } from './composerDraftStore'
import { CREATION_LABELS, type ChatContext } from '../../../../shared/types/chatCapabilities'
import type { AgentProvider } from '../../../../shared/types/agent-events'

const MAX_TEXTAREA_HEIGHT_PX = 200
const MAX_IMAGE_BYTES = 5 * 1024 * 1024
const MAX_IMAGE_COUNT = 5
const MENTION_DEBOUNCE_MS = 160
const MAX_MENTION_RESULTS = 20

/** `@`만 쳤을 때 보여줄 전체 목록 — materials:tree 를 hit 형태로 평탄화. */
export function mentionHitsFromTree(
  nodes: readonly MaterialNode[]
): MaterialSearchHit[] {
  const hits: MaterialSearchHit[] = []
  const walk = (entries: readonly MaterialNode[]): void => {
    for (const node of entries) {
      if (node.kind === 'dir') {
        walk(node.children ?? [])
      } else {
        hits.push({
          relPath: node.relPath,
          name: node.name,
          kind: node.kind,
          score: 0
        })
      }
    }
  }
  walk(nodes)
  return hits.sort((a, b) => a.relPath.localeCompare(b.relPath, 'ko'))
}

interface MentionRange {
  start: number
  end: number
  query: string
}

export interface ComposerHandle {
  focus: () => void
  /** Keeps urgent UI from stealing focus while the student is writing. */
  isActivelyTyping: () => boolean
}

const RECENT_TYPING_WINDOW_MS = 1_500

export interface ComposerProps {
  sourcePanelId?: string | undefined
  conversationId?: string
  provider?: AgentProvider
  modelControl?: ReactNode
  screenAvailable?: boolean
  courseId: string
  value: string
  /** composer 위에 뜨는 인용 칩들 — 전송 시 부모가 본문과 합성한다. */
  quotes?: readonly ChatQuote[]
  onRemoveQuote?: (index: number) => void
  onChange: (value: string) => void
  onSend: (attachments: ChatAttachment[], context?: ChatContext) => void | Promise<void>
  onCancel: () => void
  isStreaming: boolean
  isWaitingPermission: boolean
  limit: LimitInfo | null
  disabled: boolean
}

function formatResetTime(resetsAt: string | undefined): string | null {
  if (resetsAt === undefined) {
    return null
  }
  const date = new Date(resetsAt)
  if (Number.isNaN(date.getTime())) {
    return null
  }
  return date.toLocaleTimeString('ko-KR', {
    hour: 'numeric',
    minute: '2-digit'
  })
}

function mentionAt(text: string, caret: number): MentionRange | null {
  const prefix = text.slice(0, caret)
  const match = /(?:^|\s)@([^\s@]*)$/.exec(prefix)
  if (match === null) {
    return null
  }
  const atOffset = match[0].lastIndexOf('@')
  const start = match.index + atOffset
  return { start, end: caret, query: match[1] ?? '' }
}

function readImage(file: File): Promise<ChatAttachment> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onerror = () => reject(reader.error ?? new Error('read failed'))
    reader.onload = () => {
      if (typeof reader.result !== 'string') {
        reject(new Error('read failed'))
        return
      }
      const comma = reader.result.indexOf(',')
      if (comma < 0) {
        reject(new Error('invalid data URL'))
        return
      }
      resolve({ mediaType: file.type, dataBase64: reader.result.slice(comma + 1) })
    }
    reader.readAsDataURL(file)
  })
}

export const Composer = forwardRef<ComposerHandle, ComposerProps>(
  function Composer(
    {
      sourcePanelId,
      courseId,
      conversationId = courseId,
      provider = 'claude-code',
      modelControl,
      screenAvailable = false,
      value,
      quotes = [],
      onRemoveQuote,
      onChange,
      onSend,
      onCancel,
      isStreaming,
      isWaitingPermission,
      limit,
      disabled
    },
    ref
  ): JSX.Element {
    const textareaRef = useRef<HTMLTextAreaElement>(null)
    const mentionSequenceRef = useRef(0)
    const dismissedMentionRef = useRef<{ text: string; caret: number } | null>(null)
    const isComposingRef = useRef(false)
    const lastInputAtRef = useRef(Number.NEGATIVE_INFINITY)
    const draftState = useComposerDraft(conversationId)
    const attachments = draftState.images
    const setAttachments = useCallback((update: ChatAttachment[] | ((images: ChatAttachment[]) => ChatAttachment[])): void => {
      updateComposerDraft(conversationId, (current) => ({ images: typeof update === 'function' ? update(current.images) : update }))
    }, [conversationId])
    const submittingRef = useRef(false)
    const [submitting, setSubmitting] = useState(false)
    const hasContext = draftState.files.length > 0 || draftState.skills.length > 0 || draftState.browser || draftState.screen
    const [attachmentError, setAttachmentError] = useState<string | null>(null)
    const [mention, setMention] = useState<MentionRange | null>(null)
    const [mentionHits, setMentionHits] = useState<MaterialSearchHit[]>([])
    const [mentionIndex, setMentionIndex] = useState(0)
    const [isSearching, setIsSearching] = useState(false)

    useImperativeHandle(ref, () => ({
      focus: () => textareaRef.current?.focus(),
      isActivelyTyping: () =>
        isComposingRef.current ||
        Date.now() - lastInputAtRef.current <= RECENT_TYPING_WINDOW_MS
    }))

    const resize = useCallback(() => {
      const textarea = textareaRef.current
      if (textarea === null) {
        return
      }
      textarea.style.height = 'auto'
      textarea.style.height = `${Math.min(
        textarea.scrollHeight,
        MAX_TEXTAREA_HEIGHT_PX
      )}px`
    }, [])

    useLayoutEffect(resize, [resize, value])

    const updateMention = useCallback((text: string, caret: number) => {
      const dismissed = dismissedMentionRef.current
      if (dismissed?.text === text && dismissed.caret === caret) return
      dismissedMentionRef.current = null
      setMention(mentionAt(text, caret))
      setMentionIndex(0)
    }, [])

    useEffect(() => {
      const sequence = ++mentionSequenceRef.current
      if (mention === null) {
        setMentionHits([])
        setIsSearching(false)
        return
      }
      const query = mention.query.trim()
      if (query === '') {
        // `@`만 쳐도 과목 전체 파일이 바로 뜬다 — 노트 멘션과 같은 UX.
        // materials:tree 는 main 이 캐시하므로 열릴 때마다 불러도 싸다.
        setIsSearching(true)
        void invoke('materials:tree', { courseId })
          .then((tree) => {
            if (sequence !== mentionSequenceRef.current) return
            setMentionHits(mentionHitsFromTree(tree).slice(0, MAX_MENTION_RESULTS))
            setMentionIndex(0)
          })
          .catch(() => {
            if (sequence === mentionSequenceRef.current) setMentionHits([])
          })
          .finally(() => {
            if (sequence === mentionSequenceRef.current) setIsSearching(false)
          })
        return
      }
      setIsSearching(true)
      const timeout = window.setTimeout(() => {
        void invoke('materials:search', { courseId, query })
          .then((hits) => {
            if (sequence !== mentionSequenceRef.current) {
              return
            }
            setMentionHits(hits.slice(0, MAX_MENTION_RESULTS))
            setMentionIndex(0)
          })
          .catch(() => {
            if (sequence === mentionSequenceRef.current) {
              setMentionHits([])
            }
          })
          .finally(() => {
            if (sequence === mentionSequenceRef.current) {
              setIsSearching(false)
            }
          })
      }, MENTION_DEBOUNCE_MS)
      return () => window.clearTimeout(timeout)
    }, [courseId, mention])

    const selectMention = useCallback(
      (hit: MaterialSearchHit) => {
        if (mention === null) {
          return
        }
        const inserted = `@${hit.relPath} `
        const next =
          value.slice(0, mention.start) + inserted + value.slice(mention.end)
        const caret = mention.start + inserted.length
        onChange(next)
        setMention(null)
        setMentionHits([])
        window.requestAnimationFrame(() => {
          textareaRef.current?.focus()
          textareaRef.current?.setSelectionRange(caret, caret)
          resize()
        })
      },
      [mention, onChange, resize, value]
    )

    const submit = useCallback(async () => {
      if (
        isStreaming || submittingRef.current ||
        disabled ||
        (value.trim() === '' && attachments.length === 0 && quotes.length === 0 && !hasContext)
      ) {
        return
      }
      submittingRef.current = true; setSubmitting(true); setAttachmentError(null)
      try {
        const pendingFiles = draftState.files.filter((file) => file.path)
        const imported = pendingFiles.length ? await invoke('chat:importAttachments', { courseId, paths: pendingFiles.map((file) => file.path!) }) : []
        let index = 0
        const files = draftState.files.map((file) => file.path ? imported[index++]! : file)
        const importedByPath = new Map(pendingFiles.map((file, index) => [file.path, imported[index]!]))
        updateComposerDraft(conversationId, current => ({ files: current.files.map(file => file.path ? importedByPath.get(file.path) ?? file : file) }))
        await onSend(attachments, draftContext({ ...draftState, files }))
        consumeComposerDraft(conversationId, { ...draftState, text: value, quotes: [...quotes], files })
        setMention(null)
        window.requestAnimationFrame(resize)
      } catch (error) { setAttachmentError(error instanceof Error ? error.message : '전송하지 못했어요. 다시 시도해 주세요.') }
      finally { submittingRef.current = false; setSubmitting(false) }
    }, [attachments, disabled, isStreaming, onSend, quotes.length, resize, value, hasContext, draftState, courseId, conversationId])

    const handleKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>): void => {
      if (event.nativeEvent.isComposing) {
        return
      }
      if (mention !== null) {
        const clamped = Math.min(
          mentionIndex,
          Math.max(mentionHits.length - 1, 0)
        )
        if (event.key === 'Escape') {
          event.preventDefault()
          event.stopPropagation()
          dismissedMentionRef.current = { text: value, caret: event.currentTarget.selectionStart ?? value.length }
          setMention(null)
          setMentionHits([])
          return
        }
        if (event.key === 'ArrowDown') {
          event.preventDefault()
          setMentionIndex((index) =>
            Math.min(index + 1, Math.max(mentionHits.length - 1, 0))
          )
          return
        }
        if (event.key === 'ArrowUp') {
          event.preventDefault()
          setMentionIndex((index) => Math.max(index - 1, 0))
          return
        }
        if (event.key === 'Enter') {
          event.preventDefault()
          const selected = mentionHits[clamped]
          if (selected !== undefined) {
            selectMention(selected)
          }
          return
        }
        if (event.key === 'Tab' && mentionHits[clamped] !== undefined) {
          event.preventDefault()
          selectMention(mentionHits[clamped]!)
          return
        }
      }
      if (event.key === 'Enter' && !event.shiftKey) {
        event.preventDefault()
        submit()
      }
    }

    const handlePaste = (event: ClipboardEvent<HTMLTextAreaElement>): void => {
      if (submitting) return
      const pastedFiles = Array.from(event.clipboardData.files)
      const files = pastedFiles.filter((file) => !file.type.startsWith('image/')).flatMap((file) => {
        const path = window.bandal.pathForFile(file)
        return path ? [{ name: file.name, path }] : []
      })
      if (files.length) {
        event.preventDefault()
        updateComposerDraft(conversationId, (current) => ({ files: [...current.files, ...files].slice(0, 20) }))
      }
      const images = pastedFiles.filter((file) =>
        file.type.startsWith('image/')
      )
      if (images.length === 0) {
        return
      }
      event.preventDefault()
      const remaining = MAX_IMAGE_COUNT - attachments.length
      const sized = images.filter((file) => file.size <= MAX_IMAGE_BYTES)
      const accepted = sized.slice(0, Math.max(remaining, 0))

      if (images.some((file) => file.size > MAX_IMAGE_BYTES)) {
        setAttachmentError('이미지는 한 장당 5MB까지 첨부할 수 있어요.')
      } else if (images.length > remaining) {
        setAttachmentError('이미지는 한 메시지에 최대 5장까지 첨부할 수 있어요.')
      } else {
        setAttachmentError(null)
      }

      if (accepted.length === 0) {
        return
      }
      void Promise.allSettled(accepted.map(readImage)).then((results) => {
        const read = results.flatMap((result) =>
          result.status === 'fulfilled' ? [result.value] : []
        )
        setAttachments((current) =>
          [...current, ...read].slice(0, MAX_IMAGE_COUNT)
        )
        if (read.length !== accepted.length) {
          setAttachmentError('일부 이미지를 읽지 못했어요. 다시 붙여넣어 주세요.')
        }
      })
    }

    const removeAttachment = (index: number): void => {
      setAttachments((current) => current.filter((_, itemIndex) => itemIndex !== index))
      setAttachmentError(null)
    }

    const canSend =
      !isStreaming &&
      !disabled && !submitting &&
      (value.trim() !== '' || attachments.length > 0 || quotes.length > 0 || hasContext)
    const resetTime = formatResetTime(limit?.resetsAt)
    const clampedMentionIndex = Math.min(
      mentionIndex,
      Math.max(mentionHits.length - 1, 0)
    )

    return (
      <div className="chat-composer-zone" onDragOver={(event) => { if (event.dataTransfer.types.includes('Files')) event.preventDefault() }} onDrop={(event) => {
        if (!event.dataTransfer.files.length || submitting) return
        event.preventDefault()
        const files = Array.from(event.dataTransfer.files).flatMap((file) => {
          const path = window.bandal.pathForFile(file)
          return path ? [{ name: file.name, path }] : []
        })
        updateComposerDraft(conversationId, (current) => ({ files: [...current.files, ...files].slice(0, 20) }))
      }}>
        <ContextChips sourcePanelId={sourcePanelId} courseId={courseId} conversationId={conversationId} />
        {hasContext && <div className="chat-context-chips" aria-label="첨부한 맥락">
          {draftState.files.map((file, index) => <span className="chat-context-chip" key={file.relPath ?? file.path}>{file.name}<button type="button" aria-label={`${file.name} 제거`} disabled={submitting} onClick={() => updateComposerDraft(conversationId, (current) => ({ files: current.files.filter((_, i) => i !== index) }))}>×</button></span>)}
          {draftState.skills.map((skill) => <span className="chat-context-chip" key={skill.id}>{draftState.creation ? `${CREATION_LABELS[draftState.creation]} 만들기 · ` : ''}{skill.name}<button type="button" aria-label={`${skill.name} 제거`} disabled={submitting} onClick={() => updateComposerDraft(conversationId, (current) => ({ skills: current.skills.filter((item) => item.id !== skill.id), creation: null }))}>×</button></span>)}
          {(['browser', 'screen'] as const).map((kind) => draftState[kind] && <span className="chat-context-chip" key={kind}>{kind === 'browser' ? '현재 브라우저 페이지' : '현재 화면'}<button type="button" aria-label={`${kind === 'browser' ? '브라우저 페이지' : '화면'} 제거`} onClick={() => updateComposerDraft(conversationId, { [kind]: false })}>×</button></span>)}
        </div>}
        {limit !== null && (
          <div className="chat-limit" role="status">
            <span className="chat-limit__title">사용 한도에 도달했어요.</span>
            <span>
              {resetTime !== null
                ? `${resetTime}에 다시 이용할 수 있어요.`
                : limit.message}
            </span>
          </div>
        )}
        {quotes.length > 0 && (
          <div className="chat-quote-chips" aria-label="인용 첨부">
            {quotes.map((quote, index) => (
              <div key={`${quote.source}:${index}`} className="chat-quote-chip">
                <span className="chat-quote-chip__label">
                  인용 · {quote.source}
                </span>
                <span className="chat-quote-chip__preview">{quote.text}</span>
                <button
                  type="button"
                  className="chat-quote-chip__remove"
                  aria-label={`인용 ${index + 1} 제거`}
                  onClick={() => onRemoveQuote?.(index)}
                >
                  ×
                </button>
              </div>
            ))}
          </div>
        )}
        {attachments.length > 0 && (
          <div className="chat-attachments" aria-label="첨부 이미지">
            {attachments.map((attachment, index) => (
              <div
                key={`${attachment.mediaType}:${index}`}
                className="chat-attachment"
              >
                <img
                  src={`data:${attachment.mediaType};base64,${attachment.dataBase64}`}
                  alt={`첨부 이미지 ${index + 1}`}
                />
                <button
                  type="button"
                  onClick={() => removeAttachment(index)}
                  aria-label={`첨부 이미지 ${index + 1} 제거`}
                >
                  ×
                </button>
              </div>
            ))}
          </div>
        )}
        {attachmentError !== null && (
          <p className="chat-attachment-error" role="alert">
            {attachmentError}
          </p>
        )}
        <div className="chat-composer" data-streaming={isStreaming || undefined}>
          {mention !== null && (
            <div className="chat-mention" role="listbox" aria-label="과목 파일">
              {isSearching && mentionHits.length === 0 ? (
                <p className="chat-mention__status">찾는 중…</p>
              ) : mentionHits.length === 0 ? (
                <p className="chat-mention__status">
                  {mention.query.trim() === ''
                    ? '이 과목에 아직 파일이 없어요.'
                    : '일치하는 파일이 없어요.'}
                </p>
              ) : (
                mentionHits.map((hit, index) => (
                  <button
                    key={hit.relPath}
                    id={`chat-mention-${index}`}
                    type="button"
                    role="option"
                    aria-selected={index === clampedMentionIndex}
                    data-highlighted={index === clampedMentionIndex || undefined}
                    onMouseDown={(event) => event.preventDefault()}
                    onMouseEnter={() => setMentionIndex(index)}
                    onClick={() => selectMention(hit)}
                  >
                    <span>{hit.name}</span>
                    <small>{hit.relPath}</small>
                  </button>
                ))
              )}
            </div>
          )}
          <AddMenu courseId={courseId} conversationId={conversationId} provider={provider} disabled={submitting} screenAvailable={screenAvailable} />
          <textarea
            ref={textareaRef}
            className="chat-composer__input"
            rows={1}
            placeholder={draftState.creation ? `어떤 ${CREATION_LABELS[draftState.creation]}을 만들까요?` : "무엇이든 물어보세요"}
            value={value}
            disabled={disabled || submitting}
            onChange={(event) => {
              lastInputAtRef.current = Date.now()
              onChange(event.target.value)
              updateMention(
                event.target.value,
                event.target.selectionStart ?? event.target.value.length
              )
              resize()
            }}
            onCompositionStart={() => {
              isComposingRef.current = true
              lastInputAtRef.current = Date.now()
            }}
            onCompositionEnd={() => {
              isComposingRef.current = false
              lastInputAtRef.current = Date.now()
            }}
            onSelect={(event) => {
              updateMention(
                value,
                event.currentTarget.selectionStart ?? value.length
              )
            }}
            onPaste={handlePaste}
            onKeyDown={handleKeyDown}
            aria-label="메시지 입력"
            aria-expanded={mention !== null}
            aria-activedescendant={
              mention !== null && mentionHits.length > 0
                ? `chat-mention-${clampedMentionIndex}`
                : undefined
            }
          />
          <div className="chat-composer-controls">
          {isStreaming ? (
            <button
              type="button"
              className="chat-composer__action chat-composer__action--stop"
              onClick={onCancel}
              aria-label="응답 중단"
              title="응답 중단"
            >
              <svg viewBox="0 0 16 16" aria-hidden="true">
                <rect x="4" y="4" width="8" height="8" rx="1.5" fill="currentColor" />
              </svg>
            </button>
          ) : (
            <button
              type="button"
              className="chat-composer__action chat-composer__action--send"
              onClick={submit}
              disabled={!canSend}
              aria-label="메시지 보내기"
              title="보내기 (Enter)"
            >
              <svg viewBox="0 0 16 16" fill="none" aria-hidden="true">
                <path
                  d="M8 12.5v-9M4.5 7 8 3.5 11.5 7"
                  stroke="currentColor"
                  strokeWidth="1.8"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            </button>
          )}
          </div>
        </div>
        <div className="chat-composer-toolbar"><AccessPolicyMenu courseId={courseId} conversationId={conversationId} disabled={isStreaming || submitting} />{modelControl}</div>
        <div className="chat-composer__hint" aria-live="polite">
          {isWaitingPermission ? (
            <span className="chat-composer__hint-waiting">
              계속하려면 위 항목을 확인해 주세요.
            </span>
          ) : (
            submitting ? <span>메시지를 보내는 중…</span> : null
          )}
        </div>
      </div>
    )
  }
)
