import { gmailMessage, gmailSummary, replyMime } from '../upstream/src/main/features/mail/gmailModel'
import type { MailMessage } from '../upstream/src/shared/types/mail'

/** Original Gmail message/reply encoding; OAuth and credentials remain native. */
export function installMail(handle: (channel: string, action: (request: any) => any) => void) {
  const platform = (channel: string, request = {}) => (globalThis as any).__bandalPlatform.invoke(channel, request)
  const bodies = new Map<string, MailMessage>()
  let epoch = 0
  const validId = (value: unknown): string => {
    if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{1,200}$/.test(value)) throw new Error('메일 식별자가 올바르지 않아요.')
    return value
  }
  const current = (generation: number) => { if (epoch !== generation) throw new Error('메일 연결이 변경되었어요.') }
  const api = (path: string, method = 'GET', body?: unknown) => platform('native:mailAPI', {path, method, body})
  const read = async (id: string): Promise<MailMessage> => {
    const generation = epoch
    const result = gmailMessage(await api(`/messages/${validId(id)}?format=full`))
    current(generation)
    if (bodies.size >= 30) bodies.delete(bodies.keys().next().value!)
    bodies.set(id, result); return result
  }
  handle('mail:state', () => platform('native:mailState'))
  handle('mail:connect', async () => { epoch++; bodies.clear(); return platform('native:mailConnect') })
  handle('mail:cancelConnect', () => { epoch++; return platform('native:mailCancel') })
  handle('mail:disconnect', async () => { epoch++; await platform('native:mailDisconnect'); bodies.clear(); return {ok: true} })
  handle('mail:read', req => read(req.id))
  handle('mail:list', async req => {
    const generation = epoch
    const params = new URLSearchParams({maxResults: '20', labelIds: req.filter === 'starred' ? 'STARRED' : 'INBOX'})
    if (req.pageToken) params.set('pageToken', String(req.pageToken).slice(0, 1024))
    const query = [req.filter === 'unread' ? 'is:unread' : '', String(req.query ?? '').slice(0, 300)].filter(Boolean).join(' ')
    if (query) params.set('q', query)
    const page = await api(`/messages?${params}`)
    const messages = []
    for (let i = 0; i < (page.messages?.length ?? 0); i += 5) {
      current(generation)
      const fetched = await Promise.all(page.messages.slice(i, i + 5).map(({id}: {id: string}) => api(`/messages/${validId(id)}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject`)))
      messages.push(...fetched.map(gmailSummary))
    }
    current(generation); return {messages, nextPageToken: page.nextPageToken ?? null}
  })
  handle('mail:modify', async req => {
    const labels: Record<string, unknown> = {archive: {removeLabelIds: ['INBOX']}, read: {removeLabelIds: ['UNREAD']}, unread: {addLabelIds: ['UNREAD']}, star: {addLabelIds: ['STARRED']}, unstar: {removeLabelIds: ['STARRED']}}
    if (!labels[req.action]) throw new Error('지원하지 않는 메일 작업이에요.')
    await api(`/messages/${validId(req.id)}/modify`, 'POST', labels[req.action]); bodies.delete(req.id); return {ok: true}
  })
  handle('mail:reply', async req => {
    const generation = epoch
    const original = bodies.get(validId(req.messageId)) ?? await read(req.messageId)
    const state = await platform('native:mailState')
    current(generation)
    await api('/messages/send', 'POST', {threadId: original.threadId, raw: replyMime(original, state.email ?? '', req.text)})
    return {ok: true}
  })
}
