import type { MailMessage, MailSummary } from '../../../shared/types/mail'

interface GmailPart {
  mimeType?: string
  filename?: string
  headers?: { name: string; value: string }[]
  body?: { data?: string; attachmentId?: string; size?: number }
  parts?: GmailPart[]
}
export interface GmailMessage {
  id: string
  threadId: string
  labelIds?: string[]
  snippet?: string
  internalDate?: string
  payload?: GmailPart
}

export function gmailHeader(message: GmailMessage, name: string): string {
  return message.payload?.headers?.find((header) => header.name.toLowerCase() === name.toLowerCase())?.value ?? ''
}

export function gmailSummary(message: GmailMessage): MailSummary {
  return {
    id: message.id, threadId: message.threadId,
    from: gmailHeader(message, 'From'), to: gmailHeader(message, 'To'),
    subject: gmailHeader(message, 'Subject') || '(제목 없음)',
    snippet: message.snippet ?? '',
    date: new Date(Number(message.internalDate) || 0).toISOString(),
    unread: message.labelIds?.includes('UNREAD') ?? false,
    starred: message.labelIds?.includes('STARRED') ?? false
  }
}

export function gmailMessage(message: GmailMessage): MailMessage {
  const text: string[] = [], html: string[] = []
  const attachments: MailMessage['attachments'] = []
  const visit = (part: GmailPart, depth: number): void => {
    if (depth > 20) return
    if (part.filename) {
      if (part.body?.attachmentId) attachments.push({ id: part.body.attachmentId, name: part.filename, size: part.body.size ?? 0 })
      return
    }
    if (part.body?.data) {
      const decoded = Buffer.from(part.body.data, 'base64url').toString('utf8')
      if (part.mimeType === 'text/plain') text.push(decoded)
      if (part.mimeType === 'text/html') html.push(decoded)
    }
    part.parts?.forEach((child) => visit(child, depth + 1))
  }
  if (message.payload) visit(message.payload, 0)
  return { ...gmailSummary(message), text: text.join('\n'), html: html.join('\n'),
    messageId: gmailHeader(message, 'Message-ID'), references: gmailHeader(message, 'References'),
    replyTo: gmailHeader(message, 'Reply-To') || gmailHeader(message, 'From'), attachments }
}

function safeHeader(value: string): string {
  return value.replace(/[\r\n\0]/g, ' ').trim()
}

/** RFC 2822 headers plus UTF-8/base64 body; user input cannot inject headers. */
export function replyMime(original: MailMessage, from: string, text: string): string {
  if (!text.trim() || text.length > 100_000) throw new Error('답장은 1~100,000자로 입력해 주세요.')
  const subject = /^re:/i.test(original.subject) ? original.subject : `Re: ${original.subject}`
  const headers = [
    `From: ${safeHeader(from)}`, `To: ${safeHeader(original.replyTo)}`,
    `Subject: =?UTF-8?B?${Buffer.from(safeHeader(subject)).toString('base64')}?=`,
    'MIME-Version: 1.0', 'Content-Type: text/plain; charset=UTF-8', 'Content-Transfer-Encoding: base64'
  ]
  if (original.messageId) {
    headers.push(`In-Reply-To: ${safeHeader(original.messageId)}`,
      `References: ${safeHeader(`${original.references} ${original.messageId}`)}`)
  }
  const body = Buffer.from(text.replace(/\r?\n/g, '\r\n')).toString('base64').match(/.{1,76}/g)?.join('\r\n') ?? ''
  return Buffer.from(`${headers.join('\r\n')}\r\n\r\n${body}\r\n`).toString('base64url')
}
