import { useEffect, useState } from 'react'
import type { StudyMarketListing, StudyMarketOrder } from '../../../../shared/types/studyMarket'
import { useCoursesStore } from '../../stores/coursesStore'
import { invoke } from '../../lib/ipc'
import { marketRequest } from './api'
import { Field, MarketDialog, MarketError } from './primitives'
import { errorMessage, formatBytes, formatWon } from './presentation'

export function ListingDialog({ listing: initial, signedIn, canTrade, own, onLogin, onClose, onOrder }: {
  listing: StudyMarketListing; signedIn: boolean; canTrade: boolean; own: boolean
  onLogin: () => void; onClose: () => void; onOrder: (order: StudyMarketOrder) => void
}): JSX.Element {
  const [listing, setListing] = useState(initial)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [reporting, setReporting] = useState(false)
  const [reason, setReason] = useState('')
  const [reported, setReported] = useState(false)
  useEffect(() => {
    let cancelled = false
    void marketRequest('listing', { id: initial.id }).then(result => { if (!cancelled) setListing(result) }).catch(failure => { if (!cancelled) setError(errorMessage(failure)) })
    return () => { cancelled = true }
  }, [initial.id])
  const purchase = async (): Promise<void> => {
    if (!signedIn) { onLogin(); return }
    setBusy(true); setError(null)
    try { onOrder(await marketRequest('order', { listingId: listing.id })) } catch (failure) { setError(errorMessage(failure)) } finally { setBusy(false) }
  }
  const report = async (): Promise<void> => {
    setBusy(true); setError(null)
    try { await marketRequest('report', { listingId: listing.id, reason: reason.trim() }); setReported(true); setReporting(false) } catch (failure) { setError(errorMessage(failure)) } finally { setBusy(false) }
  }
  const files = listing.files.filter(file => !file.preview)
  return <MarketDialog title="자료 살펴보기" onClose={onClose} busy={busy} wide>
    <div className="study-market__dialog-body study-market__form">
      <MarketError message={error} />
      <p className="study-market__eyebrow">{listing.course.name}{listing.professor && ` · ${listing.professor}`}{listing.semester && ` · ${listing.semester}`}</p>
      <h3 className="study-market__detail-title">{listing.title}</h3><p className="study-market__muted">{listing.sellerName}의 공부 자료</p>
      <div className="study-market__detail-previews">{listing.previewUrls.map((url, index) => <img src={url} alt={`${listing.title} 미리보기 ${index + 1}`} key={index} />)}</div>
      <p className="study-market__description">{listing.description}</p>
      <details className="study-market__included"><summary>포함된 자료 {files.length}개 · {formatBytes(files.reduce((sum, file) => sum + file.bytes, 0))}</summary><ul>{files.map(file => <li key={file.id}><span>{file.path}</span><small>{formatBytes(file.bytes)}</small></li>)}</ul></details>
      <p className="study-market__hint">구매한 자료는 개인 학습용이에요. 재판매하거나 다른 사람에게 배포할 수 없어요. 자료 제공 전에는 결제 후 7일 이내 자동 환불을 요청할 수 있고, 제공 후에는 사유를 확인해 처리해요.</p>
      {reported ? <p className="study-market__notice" role="status">신고를 접수했어요. 운영자가 확인할게요.</p> : reporting ? <div className="study-market__form"><Field label="신고 사유"><textarea rows={3} value={reason} onChange={event => setReason(event.target.value)} maxLength={2000} placeholder="저작권, 개인정보 등 문제가 되는 내용을 알려 주세요." /></Field><div className="study-market__actions"><button className="button button--secondary" type="button" onClick={() => setReporting(false)} disabled={busy}>취소</button><button className="button button--secondary" type="button" onClick={() => void report()} disabled={busy || !reason.trim()}>신고 접수</button></div></div> : <button className="study-market__text-button study-market__align-start" type="button" onClick={signedIn ? () => setReporting(true) : onLogin}>문제가 있는 자료 신고</button>}
    </div>
    <footer className="study-market__dialog-footer"><strong className="study-market__detail-price">{formatWon(listing.price)}</strong><button type="button" className="button button--primary" disabled={busy || own || (!listing.owned && (!canTrade || listing.status !== 'published'))} onClick={() => void purchase()}>{busy ? '확인 중…' : own ? '내가 판매하는 자료' : listing.owned ? '구매한 자료 확인' : !signedIn ? '로그인하고 구매' : !canTrade ? '거래 준비 중' : '구매하기'}</button></footer>
  </MarketDialog>
}

export function CheckoutDialog({ order: initial, onClose, onComplete }: { order: StudyMarketOrder; onClose: () => void; onComplete: () => void }): JSX.Element {
  const [order, setOrder] = useState(initial)
  const [opening, setOpening] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [polls, setPolls] = useState(0)
  useEffect(() => {
    let active = true
    let timer: ReturnType<typeof setTimeout> | undefined
    let attempts = 0
    const poll = async (): Promise<void> => {
      try {
        const next = await marketRequest('orderStatus', { orderId: initial.id })
        if (!active) return
        setOrder(next); setError(null)
        if (next.status !== 'pending') { onComplete(); return }
      } catch (failure) { if (active) setError(errorMessage(failure)) }
      if (active && ++attempts < 120) timer = setTimeout(() => void poll(), 3000)
    }
    void poll()
    return () => { active = false; clearTimeout(timer) }
  }, [initial.id, polls, onComplete])
  const open = async (): Promise<void> => {
    setOpening(true); setError(null)
    try { await invoke('studyMarket:openCheckout', { orderId: order.id }); setPolls(value => value + 1) } catch (failure) { setError(errorMessage(failure)) } finally { setOpening(false) }
  }
  return <MarketDialog title={order.status === 'paid' ? '구매가 완료됐어요' : '결제 확인'} onClose={onClose} busy={opening}>
    <div className="study-market__dialog-body study-market__form"><h3>{order.title}</h3><div className="study-market__summary"><span>결제 금액</span><strong>{formatWon(order.amount)}</strong></div><MarketError message={error} />
      {order.status === 'pending' ? <><p>기본 브라우저에서 안전하게 결제해요. 결제를 마치면 여기에서 자동으로 확인해요.</p><p className="study-market__hint">창을 닫아도 구매 내역에서 이어서 확인할 수 있어요.</p></> : <p role="status">{order.status === 'paid' ? '구매 내역에서 내 과목으로 자료를 가져올 수 있어요.' : order.status === 'refunded' ? '환불이 완료됐어요.' : order.status === 'refund_pending' ? '환불을 처리하고 있어요.' : '결제가 완료되지 않았어요. 자료를 다시 선택해 구매할 수 있어요.'}</p>}
    </div><footer className="study-market__dialog-footer"><button type="button" className="button button--secondary" disabled={opening} onClick={onClose}>닫기</button>{order.status === 'pending' ? <button type="button" className="button button--primary" disabled={opening} onClick={() => void open()}>{opening ? '브라우저를 여는 중…' : '브라우저에서 결제'}</button> : order.status === 'paid' && <button type="button" className="button button--primary" onClick={onClose}>구매 내역 보기</button>}</footer>
  </MarketDialog>
}

export function ImportDialog({ order, onClose, onDone }: { order: StudyMarketOrder; onClose: () => void; onDone: () => void }): JSX.Element {
  const courses = useCoursesStore(state => state.courses)
  const [courseId, setCourseId] = useState('')
  const [accepted, setAccepted] = useState(order.supplyStartedAt !== null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const run = async (): Promise<void> => {
    setBusy(true); setError(null)
    try {
      await invoke('studyMarket:import', { orderId: order.id, ...(courseId ? { courseId } : {}), acceptSupply: accepted })
      await useCoursesStore.getState().loadCourses()
      onDone()
    } catch (failure) { setError(errorMessage(failure)) } finally { setBusy(false) }
  }
  return <MarketDialog title="내 과목으로 가져오기" busy={busy} onClose={onClose}><div className="study-market__dialog-body study-market__form"><p>{order.title}</p><Field label="자료를 넣을 과목"><select value={courseId} onChange={event => setCourseId(event.target.value)} disabled={busy}><option value="">새 과목 만들기 · {order.courseName}</option>{courses.filter(course => !course.archived && !course.missing && course.workspaceKind !== 'study-space').map(course => <option key={course.id} value={course.id}>{course.name}</option>)}</select></Field><p className="study-market__hint">별도 폴더에 가져와 기존 자료를 덮어쓰지 않아요.</p>{order.supplyStartedAt === null && <label className="study-market__check"><input type="checkbox" checked={accepted} onChange={event => setAccepted(event.target.checked)} disabled={busy} /><span>자료를 지금 제공받는 데 동의해요. 제공이 시작된 뒤에는 환불 사유를 확인해 처리해요.</span></label>}<MarketError message={error} />{busy && <p role="status">자료를 내려받고 확인하고 있어요…</p>}</div><footer className="study-market__dialog-footer"><button className="button button--secondary" type="button" onClick={onClose} disabled={busy}>취소</button><button className="button button--primary" type="button" onClick={() => void run()} disabled={busy || !accepted}>{busy ? '가져오는 중…' : '가져오기'}</button></footer></MarketDialog>
}

export function RefundDialog({ order, onClose, onDone }: { order: StudyMarketOrder; onClose: () => void; onDone: () => void }): JSX.Element {
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const submit = async (): Promise<void> => {
    setBusy(true); setError(null)
    try { await marketRequest('refund', { orderId: order.id, reason: reason.trim() }); onDone() } catch (failure) { setError(errorMessage(failure)) } finally { setBusy(false) }
  }
  return <MarketDialog title="환불 요청" busy={busy} onClose={onClose}><div className="study-market__dialog-body study-market__form"><p>{order.title} · {formatWon(order.amount)}</p><p className="study-market__hint">자료 제공 전이고 결제 후 7일 이내이면 자동으로 환불해요. 그 외에는 내용을 확인한 뒤 처리해요. 이미 내려받은 파일은 자동으로 삭제되지 않아요.</p><Field label="환불 사유"><textarea value={reason} onChange={event => setReason(event.target.value)} maxLength={2000} rows={4} placeholder="어떤 점이 문제였는지 알려 주세요." disabled={busy} /></Field><MarketError message={error} /></div><footer className="study-market__dialog-footer"><button className="button button--secondary" type="button" disabled={busy} onClick={onClose}>취소</button><button className="button button--primary" type="button" disabled={busy || !reason.trim()} onClick={() => void submit()}>{busy ? '요청 중…' : '환불 요청'}</button></footer></MarketDialog>
}
