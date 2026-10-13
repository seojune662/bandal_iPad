export interface MailAccountState {
  status: 'unconfigured' | 'disconnected' | 'connecting' | 'connected' | 'reauth-required'
  email: string | null
  experimental: boolean
}

export interface MailSummary {
  id: string
  threadId: string
  from: string
  to: string
  subject: string
  snippet: string
  date: string
  unread: boolean
  starred: boolean
}

export interface MailMessage extends MailSummary {
  text: string
  html: string
  messageId: string
  references: string
  replyTo: string
  attachments: { id: string; name: string; size: number }[]
}

export interface MailList {
  messages: MailSummary[]
  nextPageToken: string | null
}

export interface MailModify {
  id: string
  action: 'archive' | 'read' | 'unread' | 'star' | 'unstar'
}

export interface MailReply {
  messageId: string
  text: string
}

export interface MailIpcContract {
  'mail:state': { req: Record<string, never>; res: MailAccountState }
  'mail:connect': { req: Record<string, never>; res: MailAccountState }
  'mail:cancelConnect': { req: Record<string, never>; res: { ok: true } }
  'mail:disconnect': { req: Record<string, never>; res: { ok: true } }
  'mail:list': { req: { pageToken?: string; filter?: 'inbox' | 'starred' | 'unread'; query?: string }; res: MailList }
  'mail:read': { req: { id: string }; res: MailMessage }
  'mail:modify': { req: MailModify; res: { ok: true } }
  'mail:reply': { req: MailReply; res: { ok: true } }
}
