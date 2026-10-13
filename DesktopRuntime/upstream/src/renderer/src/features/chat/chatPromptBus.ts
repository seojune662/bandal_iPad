/**
 * Cross-feature hook for pushing a prompt into a conversation's chat composer
 * — e.g. M5's annotation → "이 부분 설명해줘" flow. Callers use
 * `requestChatPrompt(conversationId, prompt)`; the mounted chat surface for
 * that conversation consumes it, prefills the composer and focuses it.
 *
 * payload 는 문자열(text 프리필) 또는 구조화 객체 — quote 는 composer 위
 * 인용 칩으로 뜨고, 전송 시점에 본문과 합성된다(Claude 앱의 PASTED 칩 관례).
 *
 * Keyed by CONVERSATION id. Surfaces without a conversation of their own
 * (the assistant popup) key by courseId as a fallback.
 */

import { create } from 'zustand'

export interface ChatQuote {
  text: string
  /** "탭 제목 N쪽" 같은 출처 라벨. */
  source: string
}

export interface ChatPromptPayload {
  text?: string
  quote?: ChatQuote
}

export interface PendingChatPrompt {
  conversationId: string
  payload: ChatPromptPayload
  /** Monotonic nonce so identical prompts still retrigger. */
  nonce: number
}

interface ChatPromptState {
  pending: PendingChatPrompt | null
  request: (
    conversationId: string,
    prompt: string | ChatPromptPayload
  ) => void
  consume: (conversationId: string) => ChatPromptPayload | null
}

let promptNonce = 0

function normalizePayload(
  prompt: string | ChatPromptPayload
): ChatPromptPayload {
  return typeof prompt === 'string' ? { text: prompt } : prompt
}

/** 인용을 마크다운 blockquote 로 — 전송 합성과 프리필 양쪽이 쓴다. */
export function formatQuoteBlock(quote: ChatQuote): string {
  const source = quote.source.replace(/\s+/g, ' ').trim()
  const lines = quote.text
    .split(/\r?\n/)
    .map((line) => `> ${line}`)
    .join('\n')
  return `${lines}\n>\n> (${source}에서)`
}

export const useChatPromptStore = create<ChatPromptState>()((set, get) => ({
  pending: null,
  request: (conversationId, prompt) => {
    promptNonce += 1
    set({
      pending: {
        conversationId,
        payload: normalizePayload(prompt),
        nonce: promptNonce
      }
    })
  },
  consume: (conversationId) => {
    const pending = get().pending
    if (pending === null || pending.conversationId !== conversationId) {
      return null
    }
    set({ pending: null })
    return pending.payload
  }
}))

/** Imperative entry point for other features (annotations, board, …). */
export function requestChatPrompt(
  conversationId: string,
  prompt: string | ChatPromptPayload
): void {
  useChatPromptStore.getState().request(conversationId, prompt)
}
