/**
 * [M5] Annotation → AI tutor glue: "AI에게 물어보기" opens a fresh chat tab
 * and prefills the composer with a quoted, editable Korean prompt. Nothing is
 * auto-sent — the student reviews and edits first.
 */

import type { Annotation } from '../../../../shared/types/annotation'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { requestChatPrompt } from '../chat/chatPromptBus'
import { descriptorFor } from '../workspace/tabIdentity'

const MAX_QUOTE_CHARS = 600

/** Editable Korean prompt carrying the highlight quote + page + comment. */
export function buildAnnotationPrompt(annotation: Annotation): string {
  const quote =
    annotation.anchor.quote.length > MAX_QUOTE_CHARS
      ? `${annotation.anchor.quote.slice(0, MAX_QUOTE_CHARS)}…`
      : annotation.anchor.quote
  const lines = [`p.${annotation.page}에서 하이라이트한 부분이야: "${quote}"`]
  if (annotation.comment !== null && annotation.comment.trim().length > 0) {
    lines.push(`내 메모: ${annotation.comment.trim()}`)
  }
  lines.push('이 부분 설명해줘')
  return lines.join('\n')
}

export function askAiAboutAnnotation(
  courseId: string,
  annotation: Annotation
): void {
  const conversationId = crypto.randomUUID()
  requestChatPrompt(conversationId, buildAnnotationPrompt(annotation))
  useWorkspaceStore
    .getState()
    .openTab(descriptorFor('chat', { courseId, conversationId }))
}
