import { useEffect, useId, useState, type MouseEventHandler, type ReactNode } from 'react'
import { BrowserIcon } from '../../upstream/src/renderer/src/features/browser/browserIcons'
import { useBrowserGuests, type BrowserNavState } from '../../upstream/src/renderer/src/features/browser/browserGuestsStore'
import { showToast } from '../../upstream/src/renderer/src/app/toast'
import { invoke } from '../../upstream/src/renderer/src/lib/ipc'
import { usePrintStore } from '../../upstream/src/renderer/src/features/print/printStore'
import { browserRequest } from './BrowserSiteControls'

export function BrowserMenuSection({ title, children }: { title: string; children: ReactNode }): JSX.Element {
  const id = useId()
  return <section className="ipad-browser-menu-section" aria-labelledby={id}>
    <h3 id={id}>{title}</h3>{children}
  </section>
}

export function BrowserShareButton({ tabId, className = '' }: { tabId: string; className?: string }): JSX.Element {
  return <button type="button" className={`browser-nav-button ${className}`} aria-label="페이지 공유" onClick={() => {
    void browserRequest('browser:sharePage', { tabId }).catch(() => showToast('공유 창을 열지 못했어요. 다른 창을 닫고 다시 시도해 주세요.', 'danger'))
  }}><svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.75" aria-hidden="true"><path d="M12 15V3m-4 4 4-4 4 4M7 10H4v11h16V10h-3" /></svg></button>
}

export function BrowserDownloadsButton({ count, expanded, onClick, className = '' }: {
  count: number; expanded: boolean; onClick: MouseEventHandler<HTMLButtonElement>; className?: string
}): JSX.Element {
  return <button type="button" className={`browser-nav-button ipad-browser-download-button ${className}`}
    aria-label="다운로드" aria-expanded={expanded} aria-haspopup="dialog" onClick={onClick}>
    <BrowserIcon name="download" />{count > 0 && <span className="ipad-browser-download-count" aria-label={`${count}개 다운로드 진행 중`}>{count}</span>}
  </button>
}

export function BrowserSaveControls({ tabId, title, url }: { tabId: string; title: string; url: string }): JSX.Element {
  const externalAllowed = /^https?:\/\//i.test(url)
  return <>
    <button type="button" className="browser-nav-button" aria-label="페이지 인쇄 또는 PDF 저장" onClick={() => usePrintStore.getState().open({ kind: 'browser', tabId }, title)}>
      <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.75" aria-hidden="true"><path d="M7 8V3h10v5M7 17H3V9h18v8h-4M7 14h10v7H7Z" /></svg>
    </button>
    <button type="button" className="browser-nav-button" aria-label="기본 브라우저에서 열기" disabled={!externalAllowed} onClick={() => {
      void invoke('shell:openExternal', { url }).catch(() => showToast('기본 브라우저에서 열지 못했어요.', 'danger'))
    }}><svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.75" aria-hidden="true"><path d="M14 3h7v7m0-7L10 14M10 4H4v16h16v-6" /></svg></button>
  </>
}

type HistoryEntry = { url: string; title: string; host: string }
export function BrowserHistoryControls({ profileId, isPrivate, onNavigate }: {
  profileId: string; isPrivate: boolean; onNavigate: (url: string) => void
}): JSX.Element {
  const [open, setOpen] = useState(false)
  const [result, setResult] = useState<{ profileId: string; entries: HistoryEntry[] } | null>(null)
  const [failed, setFailed] = useState(false)
  const id = useId()
  useEffect(() => {
    if (!open || isPrivate) return
    let active = true
    setResult(null); setFailed(false)
    void invoke('browser:searchHistory', { profileId, query: '', limit: 12 }).then(({ entries }) => {
      if (active) setResult({ profileId, entries })
    }).catch(() => { if (active) setFailed(true) })
    return () => { active = false }
  }, [open, profileId, isPrivate])
  const entries = result?.profileId === profileId ? result.entries : undefined
  return <>
    <button type="button" className="browser-nav-button" aria-label="방문 기록" data-keep-browser-menu
      aria-expanded={open} aria-controls={open ? id : undefined} onClick={() => setOpen(value => !value)}>
      <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.75" aria-hidden="true"><path d="M3 11a9 9 0 1 1 2 7M3 4v7h7M12 7v5l3 2" /></svg>
    </button>
    {open && <div id={id} className="ipad-browser-history" aria-label="최근 방문 기록">
      {isPrivate ? <p>비공개 탭에서는 방문 기록을 표시하거나 저장하지 않아요.</p>
        : failed ? <p role="status">방문 기록을 불러오지 못했어요. 닫았다가 다시 열어 주세요.</p>
        : !entries ? <p role="status">방문 기록을 불러오는 중…</p>
        : entries.length === 0 ? <p>이 프로필의 방문 기록이 없어요.</p>
        : entries.map(entry => <button type="button" key={entry.url} onClick={() => onNavigate(entry.url)}><strong>{entry.title || entry.host}</strong><span>{entry.host || entry.url}</span></button>)}
    </div>}
  </>
}

export function BrowserConnectionStatus({ url, isPrivate }: { url: string; isPrivate: boolean }): JSX.Element {
  const secure = url.startsWith('https://'), insecure = url.startsWith('http://')
  const label = secure ? '암호화된 연결' : insecure ? '안전하지 않은 연결 (HTTP)' : '웹 주소'
  return <>
    <span className={`browser-address__security${insecure ? ' browser-address__security--insecure' : ''}`}
      title={label} aria-label={label} data-connection={secure ? 'secure' : insecure ? 'insecure' : 'none'}>
      <BrowserIcon name={secure ? 'lock' : insecure ? 'insecure' : 'globe'} />
    </span>
    {isPrivate && <span className="ipad-browser-private-mark" title="비공개 브라우징" aria-label="비공개 브라우징"><BrowserIcon name="private" /><span>비공개</span></span>}
  </>
}

/** Native WebKit progress, kept in the tab store by the iPad page-event adapter. */
export function BrowserLoadingProgress({ tabId, loading, visible }: { tabId: string; loading: boolean; visible: boolean }): JSX.Element {
  const nav = useBrowserGuests(state => state.nav[tabId]) as (BrowserNavState & { estimatedProgress?: number }) | undefined
  const estimate = nav?.estimatedProgress
  const progress = typeof estimate === 'number' && Number.isFinite(estimate) ? Math.max(0, Math.min(1, estimate)) : 0
  return <div className="browser-progress ipad-browser-progress" data-active={loading && visible ? 'true' : undefined}
    role="progressbar" aria-label="페이지 로딩" aria-valuemin={0} aria-valuemax={100}
    aria-valuenow={Math.round(progress * 100)} aria-hidden={!loading || !visible}>
    <div className="browser-progress__bar" style={{ width: `${progress * 100}%` }} />
  </div>
}
