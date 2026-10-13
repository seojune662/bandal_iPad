/**
 * Ordered message stream: user bubbles on the right, assistant turns as
 * readable answers with a single progress indicator and a copy action.
 * Internal reasoning, commands and resolved permissions stay out of the transcript.
 */

import { Fragment, memo, useEffect, useState, type ReactNode } from 'react'
import { invoke } from '../../lib/ipc'
import { BandalMark } from '../../components/BandalMark'
import { CREATION_LABELS } from '../../../../shared/types/chatCapabilities'
import type {
  PermissionResponse
} from '../../../../shared/types/agent-events'
import type { BlockView, MessageView, NoticeBlockView } from './chatModel'
import { providerLabel } from './AgentSetupCards'
import { PermissionDialog } from './blocks/PermissionDialog'
import { TextBlock } from './blocks/TextBlock'

interface BlockRendererProps {
  block: BlockView
  pendingPermissionId: string | null
  dockedPermissionId: string | null
  onRespondPermission: (requestId: string, response: PermissionResponse) => void
}

function activePermissionForBlock(
  block: BlockView,
  pendingPermissionId: string | null
): string | null {
  return block.kind === 'permission' && block.id === pendingPermissionId
    ? block.id
    : null
}

const BlockRenderer = memo(function BlockRenderer({
  block,
  pendingPermissionId,
  dockedPermissionId,
  onRespondPermission
}: BlockRendererProps): JSX.Element | null {
  switch (block.kind) {
    case 'notice':
      // Notice-only messages are rendered by SystemNotice; a stray notice
      // block inside a normal turn has no bubble form.
      return null
    case 'artifact':
      return <div className="chat-artifact"><span>{block.artifact.name}</span><button type="button" onClick={() => void invoke('chat:openArtifact', { courseId: block.artifact.courseId, relPath: block.artifact.relPath }).catch(() => undefined)}>열기</button><button type="button" onClick={() => { void invoke('materials:reveal', { courseId: block.artifact.courseId, relPath: block.artifact.relPath }).catch(() => undefined) }}>파일 위치</button></div>
    case 'text':
      return <TextBlock block={block} />
    case 'thinking':
    case 'tool':
      return null
    case 'permission':
      if (block.id === dockedPermissionId || block.behavior !== undefined) {
        return null
      }
      return (
        <PermissionDialog
          block={block}
          isActive={pendingPermissionId === block.id}
          onRespond={onRespondPermission}
        />
      )
  }
}, (previous, next) =>
  previous.block === next.block &&
  previous.onRespondPermission === next.onRespondPermission &&
  previous.dockedPermissionId === next.dockedPermissionId &&
  activePermissionForBlock(previous.block, previous.pendingPermissionId) ===
    activePermissionForBlock(next.block, next.pendingPermissionId)
)

/** Equality for immutable message view-models: id plus their content version. */
export function areMessageViewsEqual(
  previous: MessageView,
  next: MessageView
): boolean {
  if (previous === next) return true
  if (
    previous.id !== next.id ||
    previous.role !== next.role ||
    previous.streaming !== next.streaming ||
    previous.interrupted !== next.interrupted ||
    previous.blocks.length !== next.blocks.length
  ) {
    return false
  }
  for (let index = 0; index < previous.blocks.length; index += 1) {
    if (previous.blocks[index] !== next.blocks[index]) return false
  }
  return (
    previous.stats?.durationMs === next.stats?.durationMs &&
    previous.stats?.costUsd === next.stats?.costUsd &&
    previous.stats?.usage === next.stats?.usage
  )
}

function isNoticeMessage(message: MessageView): boolean {
  return (
    message.blocks.length > 0 &&
    message.blocks.every((block) => block.kind === 'notice')
  )
}

function SystemNotice({ message }: { message: MessageView }): JSX.Element {
  return (
    <div className="chat-system-notice" role="status">
      {message.blocks.map((block) => {
        const { notice } = block as NoticeBlockView
        return (
          <span key={block.id}>
            {providerLabel(notice.to)}로 이어갑니다 · 이전 대화{' '}
            {notice.carried.messages}개 메시지 전달
            {notice.carried.truncated ? ' (일부 생략)' : ''}
          </span>
        )
      })}
    </div>
  )
}

const UserMessage = memo(function UserMessage({
  message
}: {
  message: MessageView
}): JSX.Element {
  const text = message.blocks
    .map((block) => (block.kind === 'text' ? block.text : ''))
    .join('')
  const contexts = message.blocks.flatMap((block) => block.kind === 'text' && block.context ? [block.context] : [])
  const images = message.blocks.flatMap((block) =>
    block.kind === 'text' ? (block.images ?? []) : []
  )
  return (
    <article className="chat-msg chat-msg--user">
      <div className="chat-bubble">
        {images.length > 0 && (
          <div className="chat-bubble__images">
            {images.map((image, index) => (
              <img
                key={`${image.mediaType}:${index}`}
                className="chat-bubble__image"
                src={`data:${image.mediaType};base64,${image.dataBase64}`}
                alt={`첨부 이미지 ${index + 1}`}
              />
            ))}
          </div>
        )}
        {contexts.map((context, index) => <div className="chat-context-chips" key={index}>
          {context.files?.map((file) => <span className="chat-context-chip" key={file.relPath}>{file.name}</span>)}
          {context.creation && <span className="chat-context-chip">{CREATION_LABELS[context.creation]} 만들기</span>}
          {context.skillNames?.map((name) => <span className="chat-context-chip" key={name}>{name}</span>)}
          {context.browser && <span className="chat-context-chip">브라우저 페이지</span>}
          {context.screen && <span className="chat-context-chip">화면</span>}
        </div>)}
        {text !== '' && <span>{text}</span>}
      </div>
    </article>
  )
}, (previous, next) => areMessageViewsEqual(previous.message, next.message))

interface AssistantMessageProps {
  message: MessageView
  pendingPermissionId: string | null
  dockedPermissionId: string | null
  onRespondPermission: (requestId: string, response: PermissionResponse) => void
}

function activePermissionForMessage(
  message: MessageView,
  pendingPermissionId: string | null
): string | null {
  if (pendingPermissionId === null) return null
  return message.blocks.some(
    (block) => block.kind === 'permission' && block.id === pendingPermissionId
  )
    ? pendingPermissionId
    : null
}

/** One calm progress indicator replaces internal command and reasoning logs. */
export function responseStatus(message?: MessageView): string {
  const blocks = message?.blocks ?? []
  const last = blocks[blocks.length - 1]
  if (last?.kind === 'text' && last.streaming && last.text.trim()) return '답변 작성 중'
  if (blocks.some(block => block.kind === 'tool' && block.status === 'running')) return '자료를 살펴보는 중'
  return '생각 중'
}

function ResponseStatus({ message }: { message?: MessageView }): JSX.Element {
  return <div className="chat-response-status" role="status" aria-live="polite">
    <span className="chat-response-status__dot" aria-hidden="true" />
    <span>{responseStatus(message)}</span>
  </div>
}

function CopyAnswer({ text }: { text: string }): JSX.Element {
  const [status, setStatus] = useState<'idle' | 'copied' | 'error'>('idle')
  useEffect(() => {
    if (status === 'idle') return
    const timer = window.setTimeout(() => setStatus('idle'), 2400)
    return () => window.clearTimeout(timer)
  }, [status])
  const label = status === 'copied' ? '복사됨' : status === 'error' ? '다시 복사' : '답변 복사'
  return <div className="chat-answer-actions">
    <button type="button" className="chat-answer-copy" aria-label={label} title={label}
      onClick={() => { void navigator.clipboard.writeText(text).then(() => setStatus('copied'), () => setStatus('error')) }}>
      <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
        {status === 'copied' ? <path d="m4 10 4 4 8-9" /> : <><rect x="7" y="7" width="10" height="10" rx="2" /><path d="M13 4V3H3v10h1" /></>}
      </svg>
      {status !== 'idle' && <span role="status">{label}</span>}
    </button>
  </div>
}

const AssistantMessage = memo(function AssistantMessage({
  message,
  pendingPermissionId,
  dockedPermissionId,
  onRespondPermission
}: AssistantMessageProps): JSX.Element | null {
  const answer = message.blocks.filter(block => block.kind === 'text').map(block => block.text).join('\n\n')
  const hasContent = answer.trim() !== '' || message.blocks.some(block => block.kind === 'artifact' || (block.kind === 'permission' && block.behavior === undefined && block.id !== dockedPermissionId))
  if (!hasContent && !message.streaming && !message.interrupted) return null
  return (
    <article
      className="chat-msg chat-msg--assistant"
      data-interrupted={message.interrupted || undefined}
      data-streaming={message.streaming || undefined}
    >
      <BandalMark size={22} className="chat-avatar" />
      <div className="chat-msg__content">
        {message.blocks.map((block) => (
          <BlockRenderer
            key={`${block.kind}:${block.id}`}
            block={block}
            pendingPermissionId={pendingPermissionId}
            dockedPermissionId={dockedPermissionId}
            onRespondPermission={onRespondPermission}
          />
        ))}
        {message.streaming && <ResponseStatus message={message} />}
        {message.interrupted && (
          <span className="chat-msg__chip">중단됨</span>
        )}
        {!message.streaming && answer.trim() !== '' && <CopyAnswer text={answer} />}
      </div>
    </article>
  )
}, (previous, next) =>
  areMessageViewsEqual(previous.message, next.message) &&
  previous.onRespondPermission === next.onRespondPermission &&
  previous.dockedPermissionId === next.dockedPermissionId &&
  activePermissionForMessage(
    previous.message,
    previous.pendingPermissionId
  ) === activePermissionForMessage(next.message, next.pendingPermissionId)
)

export interface MessageListProps {
  streaming?: boolean
  renderActivity?: (turnSeq: number | undefined, isLast: boolean) => ReactNode
  messages: MessageView[]
  pendingPermissionId: string | null
  dockedPermissionId?: string | null
  onRespondPermission: (requestId: string, response: PermissionResponse) => void
}

export function MessageList({
  messages,
  pendingPermissionId,
  dockedPermissionId = null,
  onRespondPermission,
  renderActivity,
  streaming = false
}: MessageListProps): JSX.Element {
  const lastAssistantIndex = new Map<number | undefined, number>()
  messages.forEach((message, index) => {
    if (message.role === 'assistant') lastAssistantIndex.set(message.turnSeq, index)
  })
  return (
    <div className="chat-thread" role="log" aria-label="AI 튜터 대화">
      {messages.map((message, index) =>
        isNoticeMessage(message) ? (
          <SystemNotice key={message.id} message={message} />
        ) : message.role === 'user' ? (
          <UserMessage key={message.id} message={message} />
        ) : (
          <Fragment key={message.id}><AssistantMessage
            message={message}
            pendingPermissionId={pendingPermissionId}
            dockedPermissionId={dockedPermissionId}
            onRespondPermission={onRespondPermission}
          />{lastAssistantIndex.get(message.turnSeq) === index && renderActivity?.(message.turnSeq, index === messages.length - 1)}</Fragment>
        )
      )}
      {streaming && !messages.some(message => message.role === 'assistant' && message.streaming) && <article className="chat-msg chat-msg--assistant"><BandalMark size={22} className="chat-avatar" /><div className="chat-msg__content"><ResponseStatus /></div></article>}
    </div>
  )
}
