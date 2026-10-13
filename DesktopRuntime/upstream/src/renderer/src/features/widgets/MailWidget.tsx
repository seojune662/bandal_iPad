import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { MailAccountState, MailList, MailMessage, MailModify, MailSummary } from '../../../../shared/types/mail'
import { Icon } from '../../app/icons'
import { createBrowserTab } from '../../app/tabCommands'
import { invoke } from '../../lib/ipc'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import { useFocusTrap } from '../../components/useFocusTrap'
import './mailWidget.css'

/** Never mount provider HTML or remote images. Decode entities only as textarea text. */
export function mailText(text: string, html = ''): string {
  if (text) return text
  const plain = html.replace(/<(script|style|head|iframe|object)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, '')
    .replace(/<br\s*\/?\s*>|<\/(p|div|tr|li|h[1-6])\s*>/gi, '\n').replace(/<[^>]*>/g, '')
  const decoder = document.createElement('textarea')
  decoder.innerHTML = plain.replaceAll('<', '&lt;')
  return decoder.value.trim()
}
function sender(from: string): string { return from.replace(/<[^>]*>/g, '').replace(/^"|"$/g, '').trim() || from }
function time(date: string): string {
  const value = new Date(date)
  return value.toDateString() === new Date().toDateString()
    ? value.toLocaleTimeString('ko-KR', { hour: 'numeric', minute: '2-digit' })
    : value.toLocaleDateString('ko-KR', { month: 'numeric', day: 'numeric' })
}

export function NativeMailWidget({ fallback, active = true }: { fallback: { url: string; label: string } | null; active?: boolean }): JSX.Element {
  const [account, setAccount] = useState<MailAccountState | null>(null)
  const [page, setPage] = useState<MailList>({ messages: [], nextPageToken: null })
  const [selected, setSelected] = useState<MailMessage | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [filter, setFilter] = useState<'inbox' | 'unread' | 'starred'>('inbox')
  const [query, setQuery] = useState('')
  const [search, setSearch] = useState('')
  const [loading, setLoading] = useState(false)
  const [reading, setReading] = useState(false)
  const [connecting, setConnecting] = useState(false)
  const [mutating, setMutating] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [expanded, setExpanded] = useState(false)
  useLayoutEffect(() => { if (!active) setExpanded(false) }, [active])
  const [reply, setReply] = useState('')
  const readVersion = useRef(0), listVersion = useRef(0)
  const previousEmail = useRef<string | null>(null)
  useEffect(() => {
    const email = account?.email ?? null
    if (email === previousEmail.current) return
    previousEmail.current = email
    ++readVersion.current; ++listVersion.current
    setPage({ messages: [], nextPageToken: null }); setSelected(null); setSelectedId(null)
    setReply(''); setNotice(null); setSearch(''); setQuery('')
  }, [account?.email])
  const containerRef = useRef<HTMLDivElement>(null)
  useFocusTrap(containerRef, { active: expanded && active, onEscape: () => setExpanded(false) })
  useEffect(() => expanded && active ? acquirePointerPassthrough() : undefined, [expanded, active])
  const failure = useCallback((cause: unknown): void => {
    setError(cause instanceof Error ? cause.message : '메일을 불러오지 못했어요.')
    void invoke('mail:state', {}).then(setAccount).catch(() => {})
  }, [])
  useEffect(() => {
    let alive = true
    void invoke('mail:state', {}).then((next) => { if (alive) setAccount(next) }).catch(failure)
    return () => { alive = false; ++readVersion.current; ++listVersion.current }
  }, [failure])
  const load = useCallback(async (append = false): Promise<void> => {
    const version = ++listVersion.current
    setLoading(true); setError(null)
    try {
      const result = await invoke('mail:list', { filter, query: search, ...(append && page.nextPageToken ? { pageToken: page.nextPageToken } : {}) })
      if (version !== listVersion.current) return
      setPage((old) => ({ ...result, messages: append ? [...old.messages, ...result.messages.filter((msg) => !old.messages.some((entry) => entry.id === msg.id))] : result.messages }))
    } catch (cause) { if (version === listVersion.current) failure(cause) }
    finally { if (version === listVersion.current) setLoading(false) }
  }, [failure, filter, page.nextPageToken, search])
  const loadRef = useRef(load); loadRef.current = load
  useEffect(() => {
    if (account?.status !== 'connected') return
    void loadRef.current()
    const refresh = (): void => { if (!document.hidden && document.hasFocus()) void loadRef.current() }
    const timer = window.setInterval(refresh, 60_000)
    window.addEventListener('focus', refresh)
    return () => { window.clearInterval(timer); window.removeEventListener('focus', refresh); ++listVersion.current }
  }, [account?.status, account?.email, filter, search])
  const back = (): void => {
    if (reply.trim() && !window.confirm('작성 중인 답장을 닫을까요?')) return
    ++readVersion.current; setSelected(null); setSelectedId(null); setReply('')
  }
  const modify = async (message: MailSummary, action: MailModify['action']): Promise<void> => {
    if (action === 'archive' && reply.trim() && !window.confirm('작성 중인 답장을 닫고 메일을 보관할까요?')) return
    setMutating(true); setError(null)
    try {
      await invoke('mail:modify', { id: message.id, action })
      setPage((old) => ({ ...old, messages: action === 'archive' ? old.messages.filter((item) => item.id !== message.id) : old.messages.map((item) => item.id === message.id ? { ...item, unread: action === 'read' ? false : action === 'unread' ? true : item.unread, starred: action === 'star' ? true : action === 'unstar' ? false : item.starred } : item) }))
      setSelected((old) => old?.id === message.id ? (action === 'archive' ? null : { ...old, unread: action === 'read' ? false : action === 'unread' ? true : old.unread, starred: action === 'star' ? true : action === 'unstar' ? false : old.starred }) : old)
      if (action === 'archive') { setSelectedId(null); setReply(''); setNotice('보관했어요.') }
    } catch (cause) { failure(cause) } finally { setMutating(false) }
  }
  const open = async (message: MailSummary): Promise<void> => {
    if (reply.trim() && !window.confirm('작성 중인 답장을 닫을까요?')) return
    const version = ++readVersion.current
    setReading(true)
    setSelectedId(message.id); setSelected(null); setReply(''); setError(null); setNotice(null)
    try {
      const detail = await invoke('mail:read', { id: message.id })
      if (version !== readVersion.current) return
      setSelected(detail)
      if (detail.unread) await modify(detail, 'read')
    } catch (cause) { if (version === readVersion.current) failure(cause) }
    finally { if (version === readVersion.current) setReading(false) }
  }
  const connect = async (): Promise<void> => {
    setConnecting(true); setError(null)
    try { setAccount(await invoke('mail:connect', {})) } catch (cause) { failure(cause) }
    finally { setConnecting(false) }
  }
  const webUrl = account?.email ? `https://mail.google.com/mail/u/?authuser=${encodeURIComponent(account.email)}` : fallback?.url ?? 'https://mail.google.com/'
  const content = <div ref={containerRef} className={`mail-mini${expanded ? ' mail-mini--expanded' : ''}`} role={expanded ? 'dialog' : undefined} aria-modal={expanded || undefined} aria-label="메일함">
    <header className="mail-mini__header">
      <div><strong>메일함</strong><small title={account?.email ?? ''}>{account?.email ?? (account?.experimental ? 'Gmail · 미리 보기' : 'Gmail')}</small></div>
      <button type="button" aria-label="메일 새로고침" title="새로고침" disabled={loading || account?.status !== 'connected'} onClick={() => void load()}><Icon name="refresh" /></button>
      <button type="button" aria-label={expanded ? '메일함 접기' : '메일함 넓히기'} title={expanded ? '접기' : '넓히기'} onClick={() => setExpanded((v) => !v)}><Icon name={expanded ? 'x' : 'layoutLeft'} /></button>
      <details className="mail-mini__menu"><summary aria-label="메일함 메뉴">•••</summary><div>
        <button type="button" onClick={() => createBrowserTab(webUrl)}>전체 메일 열기</button>
        {account?.email && <button type="button" onClick={() => {
          if (!window.confirm('이 기기에서 메일 연결을 해제할까요?')) return
          ++readVersion.current; ++listVersion.current
          void invoke('mail:disconnect', {}).then(() => { setPage({ messages: [], nextPageToken: null }); setSelected(null); setSelectedId(null); setReply(''); return invoke('mail:state', {}) }).then(setAccount).catch(failure)
        }}>연결 해제</button>}
      </div></details>
    </header>
    {error && <div className="mail-mini__error" role="alert">{error}<button type="button" aria-label="오류 닫기" onClick={() => setError(null)}>×</button></div>}
    {notice && <p className="mail-mini__notice" role="status">{notice}</p>}
    {account?.status !== 'connected' ? <div className="mail-mini__connect">
      <Icon name="archive" /><strong>{account?.status === 'reauth-required' ? '메일을 다시 연결해 주세요' : '공부하면서 메일도 가볍게'}</strong>
      <p>최근 메일을 읽고, 답장하고, 보관할 수 있어요.</p>
      {account?.status === 'unconfigured' ? <p>Google 메일 연결을 준비하고 있어요. 지금은 전체 메일함을 이용해 주세요.</p> : <button type="button" className="mail-mini__primary" disabled={connecting || account === null} onClick={() => void connect()}>{connecting ? 'Google에서 연결을 마쳐 주세요…' : 'Google 메일 연결'}</button>}
      {connecting && <button type="button" onClick={() => void invoke('mail:cancelConnect', {})}>연결 취소</button>}
      <button type="button" onClick={() => createBrowserTab(webUrl)}>{fallback?.label ?? '전체 Gmail'} 열기 ↗</button>
    </div> : <>
      {selectedId === null && <><form className="mail-mini__search" onSubmit={(event) => { event.preventDefault(); setSearch(query.trim()) }}><Icon name="search" /><input aria-label="메일 검색" placeholder="메일 검색" value={query} onChange={(event) => setQuery(event.target.value)} /><button type="submit">검색</button></form>
      <nav className="mail-mini__filters" aria-label="메일 필터">{(['inbox', 'unread', 'starred'] as const).map((id) => <button key={id} type="button" aria-pressed={filter === id} onClick={() => setFilter(id)}>{id === 'inbox' ? '받은 메일' : id === 'unread' ? '안 읽음' : '별표'}</button>)}</nav></>}
      <div className="mail-mini__body">
        {selectedId !== null ? <>
          <div className="mail-mini__message-actions"><button type="button" onClick={back}>← 목록</button>{selected && <><button type="button" disabled={mutating} onClick={() => void modify(selected, 'archive')}>보관</button><button type="button" disabled={mutating} onClick={() => void modify(selected, selected.unread ? 'read' : 'unread')}>{selected.unread ? '읽음' : '안 읽음'}</button><button type="button" aria-label={selected.starred ? '별표 해제' : '별표 추가'} disabled={mutating} onClick={() => void modify(selected, selected.starred ? 'unstar' : 'star')}>{selected.starred ? '★' : '☆'}</button></>}</div>
          {selected ? <article className="mail-mini__message"><h3>{selected.subject}</h3><p className="mail-mini__sender">{selected.from}<time>{new Date(selected.date).toLocaleString('ko-KR')}</time></p><div className="mail-mini__text">{mailText(selected.text, selected.html) || mailText(selected.snippet)}</div>
          {selected.attachments.length > 0 && <button type="button" className="mail-mini__attachment" onClick={() => createBrowserTab(`${webUrl}#all/${selected.threadId}`)}>첨부 {selected.attachments.length}개 · 전체 메일에서 보기 ↗</button>}
          <form className="mail-mini__reply" onSubmit={(event) => {
            event.preventDefault(); if (mutating || !reply.trim()) return
            setMutating(true); setError(null)
            const sentText = reply, version = readVersion.current
            void invoke('mail:reply', { messageId: selected.id, text: sentText }).then(() => {
              if (version !== readVersion.current) return
              setReply(current => current === sentText ? '' : current)
              setNotice('답장을 보냈어요.')
            }).catch(failure).finally(() => setMutating(false))
          }}><label htmlFor="mail-reply">답장</label><textarea id="mail-reply" placeholder="답장을 입력하세요" value={reply} maxLength={100_000} onChange={(e) => setReply(e.target.value)} /><button type="submit" className="mail-mini__primary" disabled={mutating || !reply.trim()}>{mutating ? '처리 중…' : '답장 보내기'}</button></form></article> : <div className="mail-mini__empty" role="status">{reading ? '메일을 불러오는 중…' : <><p>메일을 불러오지 못했어요.</p><button type="button" onClick={() => { const message = page.messages.find((item) => item.id === selectedId); if (message) void open(message); else back() }}>다시 시도</button></>}</div>}
        </> : <><ul className="mail-mini__list">{(expanded ? page.messages : page.messages.slice(0, 3)).map((message) => <li key={message.id} data-unread={message.unread || undefined}><button type="button" onClick={() => { setExpanded(true); void open(message) }}><span className="mail-mini__avatar">{sender(message.from).charAt(0).toUpperCase()}</span><span className="mail-mini__preview"><span><strong>{sender(message.from)}</strong><time>{time(message.date)}</time></span><b>{message.subject}</b><small>{mailText('', message.snippet)}</small></span>{message.unread && <i aria-label="읽지 않음" />}</button></li>)}</ul>
        {loading && <p className="mail-mini__empty" role="status">메일을 불러오는 중…</p>}
        {!loading && !error && page.messages.length === 0 && <p className="mail-mini__empty">{search ? '검색 결과가 없어요.' : '메일함이 비어 있어요.'}</p>}
        {(page.nextPageToken || (!expanded && page.messages.length > 3)) && <button type="button" className="mail-mini__more" disabled={loading} onClick={() => { if (!expanded) setExpanded(true); else void load(true) }}>메일 더 보기</button>}</>}
      </div>
    </>}
  </div>
  return expanded ? <>{createPortal(content, document.body)}<div className="mail-mini__empty">메일함을 넓게 보고 있어요.<button type="button" onClick={() => setExpanded(false)}>위젯으로 돌아오기</button></div></> : content
}
