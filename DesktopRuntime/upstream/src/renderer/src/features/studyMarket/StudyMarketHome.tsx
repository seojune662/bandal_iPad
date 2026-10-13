import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { StudyMarketApi, StudyMarketCourse, StudyMarketDashboard, StudyMarketListing, StudyMarketOrder } from '../../../../shared/types/studyMarket'
import { Icon } from '../../app/icons'
import { showToast } from '../../app/toast'
import { useAuthStore } from '../../stores/authStore'
import { useCoursesStore } from '../../stores/coursesStore'
import { useUniversityStore } from '../../stores/universityStore'
import { findUniversity, isCustomUniversityId } from '../../../../shared/universities'
import { invoke } from '../../lib/ipc'
import { useUiStore } from '../../stores/uiStore'
import { marketRequest, readCourseBindings } from './api'
import { OPEN_STUDY_MARKET_SELL_EVENT, takeStudyMarketSellIntent, type StudyMarketSellIntent } from './controller'
import { SchoolDialog, CourseBindingDialog, SellerDialog, OperatorPanel } from './ManagementDialogs'
import { CheckoutDialog, ImportDialog, ListingDialog, RefundDialog } from './PurchaseDialogs'
import { SaleDialog } from './SaleDialog'
import { MarketEmpty, MarketError, MarketIcon } from './primitives'
import { errorMessage, formatWon } from './presentation'
import './studyMarket.css'

export { openStudyMarketSell, OPEN_STUDY_MARKET_SELL_EVENT } from './controller'

type Tab = 'browse' | 'purchases' | 'sales' | 'operator'
const ORDER_LABELS: Record<StudyMarketOrder['status'], string> = { pending: '결제 대기', paid: '구매 완료', refund_pending: '환불 처리 중', refunded: '환불 완료', failed: '결제 실패', cancelled: '결제 취소' }
const SELLER_LABELS: Record<StudyMarketDashboard['seller']['status'], string> = { unregistered: '판매자 등록', pending: '본인인증 확인 중', ready: '판매 가능', verification_required: '본인인증 필요', suspended: '판매 일시 중지' }
const PAYOUT_LABELS: Record<StudyMarketDashboard['payouts'][number]['status'], string> = { pending: '지급 대기', reserved: '지급 처리 중', paid: '지급 완료', failed: '지급 확인 필요', held: '지급 보류' }

function mappedCustomSchool(id: string): string {
  try { return localStorage.getItem(`bandal:study-market:university-map:${id}`) ?? '' } catch { return '' }
}

export default function StudyMarketHome(): JSX.Element {
  const auth = useAuthStore(state => state.auth)
  const university = useUniversityStore(state => state.university)
  const localCourses = useCoursesStore(state => state.courses)
  const signedIn = auth.phase === 'signed-in'
  const [context, setContext] = useState<StudyMarketApi['context']['res'] | null>(null)
  const [contextError, setContextError] = useState<string | null>(null)
  const contextSequence = useRef(0)
  const [schoolId, setSchoolId] = useState('')
  const [schoolReady, setSchoolReady] = useState('')
  const [schoolDialog, setSchoolDialog] = useState(false)
  const [courses, setCourses] = useState<StudyMarketCourse[]>([])
  const [tab, setTab] = useState<Tab>('browse')
  const [query, setQuery] = useState('')
  const [sort, setSort] = useState<'newest' | 'price'>('newest')
  const [onlyMine, setOnlyMine] = useState(false)
  const [courseFilter, setCourseFilter] = useState('')
  const [bindingDialog, setBindingDialog] = useState(false)
  const [bindingRevision, setBindingRevision] = useState(0)
  const [listings, setListings] = useState<StudyMarketListing[]>([])
  const [nextCursor, setNextCursor] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [listError, setListError] = useState<string | null>(null)
  const [listRevision, setListRevision] = useState(0)
  const requestSequence = useRef(0)
  const [dashboard, setDashboard] = useState<StudyMarketDashboard | null>(null)
  const [dashboardError, setDashboardError] = useState<string | null>(null)
  const [dashboardLoading, setDashboardLoading] = useState(false)
  const dashboardSequence = useRef(0)
  const liveAccount = useRef(auth.profile?.id)
  liveAccount.current = signedIn ? auth.profile?.id : undefined
  const previousAccount = useRef(liveAccount.current)
  const [detail, setDetail] = useState<StudyMarketListing | null>(null)
  const [checkout, setCheckout] = useState<StudyMarketOrder | null>(null)
  const [importOrder, setImportOrder] = useState<StudyMarketOrder | null>(null)
  const [refundOrder, setRefundOrder] = useState<StudyMarketOrder | null>(null)
  const [selling, setSelling] = useState(false)
  const [saleIntent, setSaleIntent] = useState<StudyMarketSellIntent | null>(null)
  const [draft, setDraft] = useState<StudyMarketListing | null>(null)
  const [sellerDialog, setSellerDialog] = useState(false)
  const [pendingListing, setPendingListing] = useState<string | null>(null)
  const school = context?.universities.find(item => item.id === schoolId)
  const canTrade = context?.tradingEnabled === true
  const canPublish = canTrade && dashboard?.seller.status === 'ready'
  const login = (): void => useUiStore.getState().openSettings('account')
  const mine = useMemo(() => {
    const bindings = readCourseBindings(schoolId)
    const activeLocalIds = new Set(localCourses.filter(course => !course.archived).map(course => course.id))
    return [...new Set(Object.entries(bindings).filter(([localId, id]) => activeLocalIds.has(localId) && courses.some(course => course.id === id)).map(([, id]) => id))]
  }, [schoolId, localCourses, courses, bindingRevision])
  const courseIds = useMemo(() => courseFilter ? [courseFilter] : onlyMine ? mine : undefined, [courseFilter, onlyMine, mine])

  const loadContext = useCallback(async (): Promise<void> => {
    const sequence = ++contextSequence.current
    setContextError(null)
    try { const data = await marketRequest('context', {}); if (sequence === contextSequence.current) setContext(data) } catch (failure) { if (sequence === contextSequence.current) setContextError(errorMessage(failure)) }
  }, [])
  const refreshDashboard = useCallback(async (): Promise<void> => {
    const sequence = ++dashboardSequence.current
    const accountId = auth.profile?.id
    if (!signedIn) { setDashboard(null); setDashboardLoading(false); setDashboardError(null); return }
    setDashboardLoading(true)
    try { const data = await marketRequest('dashboard', {}); if (sequence === dashboardSequence.current && liveAccount.current === accountId) { setDashboard(data); setDashboardError(null) } } catch (failure) { if (sequence === dashboardSequence.current && liveAccount.current === accountId) setDashboardError(errorMessage(failure)) } finally { if (sequence === dashboardSequence.current && liveAccount.current === accountId) setDashboardLoading(false) }
  }, [signedIn, auth.profile?.id])
  const completeCheckout = useCallback((): void => { void refreshDashboard(); setListRevision(value => value + 1) }, [refreshDashboard])

  useEffect(() => { void useAuthStore.getState().init(); void useUniversityStore.getState().init(); void useCoursesStore.getState().loadCourses(); void loadContext() }, [loadContext])
  useEffect(() => { void refreshDashboard() }, [refreshDashboard])
  useEffect(() => {
    if (previousAccount.current !== liveAccount.current) {
      setDashboard(null); setCheckout(null); setImportOrder(null); setRefundOrder(null); setSellerDialog(false)
      if (previousAccount.current !== undefined) { setSelling(false); setDraft(null) }
      previousAccount.current = liveAccount.current
    }
  }, [auth.profile?.id, signedIn])
  useEffect(() => () => { contextSequence.current += 1; dashboardSequence.current += 1; requestSequence.current += 1 }, [])
  useEffect(() => {
    if (!context) return
    const selected = university ? context.universities.find(item => item.id === university.id)?.id
      ?? (isCustomUniversityId(university.id) ? context.universities.find(item => item.id === mappedCustomSchool(university.id))?.id : undefined)
      ?? context.universities.find(item => item.name === university.nameKo)?.id ?? '' : ''
    setSchoolId(selected)
  }, [context, university?.id, university?.nameKo])
  useEffect(() => {
    setSchoolReady(''); setContextError(null)
    if (!schoolId) return
    const sequence = ++contextSequence.current
    let active = true
    void marketRequest('context', { universityId: schoolId }).then(result => { if (active && sequence === contextSequence.current) { setContext(result); setSchoolReady(schoolId) } }).catch(failure => { if (active && sequence === contextSequence.current) setContextError(errorMessage(failure)) })
    return () => { active = false }
  }, [schoolId, signedIn, auth.profile?.id, listRevision])
  useEffect(() => { setCourseFilter(''); setOnlyMine(false); setDetail(null) }, [schoolId])
  useEffect(() => {
    if (!schoolId || schoolReady !== schoolId) { setCourses([]); return }
    let active = true
    void marketRequest('courses', { universityId: schoolId }).then(result => { if (active) setCourses(result) }).catch(failure => { if (active) setListError(errorMessage(failure)) })
    return () => { active = false }
  }, [schoolId, schoolReady, listRevision])
  useEffect(() => {
    const current = ++requestSequence.current
    setListings([]); setNextCursor(null); setListError(null)
    if (!schoolId || schoolReady !== schoolId || (onlyMine && mine.length === 0 && !courseFilter)) { setLoading(false); return }
    setLoading(true)
    const timer = setTimeout(() => {
      void marketRequest('listings', { universityId: schoolId, q: query.trim(), sort, ...(courseIds ? { courseIds } : {}) }).then(result => {
        if (current === requestSequence.current) { setListings(result.listings); setNextCursor(result.nextCursor) }
      }).catch(failure => { if (current === requestSequence.current) setListError(errorMessage(failure)) }).finally(() => { if (current === requestSequence.current) setLoading(false) })
    }, query ? 220 : 0)
    return () => { clearTimeout(timer); requestSequence.current += 1 }
  }, [schoolId, schoolReady, query, sort, courseIds, onlyMine, mine.length, courseFilter, listRevision])
  useEffect(() => {
    const handle = (): void => {
      const intent = takeStudyMarketSellIntent()
      if (intent) { setSaleIntent(intent); setDraft(null); setSelling(true) }
    }
    handle()
    window.addEventListener(OPEN_STUDY_MARKET_SELL_EVENT, handle)
    return () => window.removeEventListener(OPEN_STUDY_MARKET_SELL_EVENT, handle)
  }, [])
  useEffect(() => {
    if (selling && !signedIn && auth.phase !== 'unconfigured' && auth.phase !== 'signing-in') { setSelling(false); login() }
  }, [selling, signedIn, auth.phase])

  const chooseSchool = (id: string): void => {
    setSchoolDialog(false); setCourseFilter(''); setOnlyMine(false); setQuery('')
    const update = async (): Promise<void> => {
      if (findUniversity(id)) await useUniversityStore.getState().selectPreset(id)
      else {
        const selected = useUniversityStore.getState().university
        if (!selected || !isCustomUniversityId(selected.id)) {
          const name = context?.universities.find(item => item.id === id)?.name
          if (!name) return
          await useUniversityStore.getState().addCustom({ nameKo: name })
        }
        const custom = useUniversityStore.getState().university
        if (custom) { try { localStorage.setItem(`bandal:study-market:university-map:${custom.id}`, id) } catch { /* The session still works. */ } }
      }
      setSchoolId(id)
    }
    void update().catch(failure => setContextError(errorMessage(failure)))
  }
  const receipt = async (order: StudyMarketOrder): Promise<void> => {
    if (!order.receiptUrl) return
    try { await invoke('shell:openExternal', { url: order.receiptUrl }) } catch { showToast('영수증을 열지 못했어요. 잠시 후 다시 시도해 주세요.', 'danger') }
  }

  const more = async (): Promise<void> => {
    if (loading || !nextCursor) return
    const current = requestSequence.current
    setLoading(true)
    try {
      const result = await marketRequest('listings', { universityId: schoolId, q: query.trim(), sort, cursor: nextCursor, ...(courseIds ? { courseIds } : {}) })
      if (current === requestSequence.current) { setListings(previous => [...previous, ...result.listings.filter(item => !previous.some(existing => existing.id === item.id))]); setNextCursor(result.nextCursor) }
    } catch (failure) { if (current === requestSequence.current) setListError(errorMessage(failure)) } finally { if (current === requestSequence.current) setLoading(false) }
  }
  const startSelling = (): void => {
    if (!signedIn) { login(); return }
    setDraft(null); setSaleIntent(null); setSelling(true)
    if (!schoolId) setSchoolDialog(true)
  }
  const withdraw = async (listing: StudyMarketListing): Promise<void> => {
    setPendingListing(listing.id)
    try { await marketRequest('withdraw', { listingId: listing.id }); await refreshDashboard(); setListRevision(value => value + 1); showToast('새로운 구매를 중지했어요. 기존 구매자는 계속 자료를 받을 수 있어요.') } catch (failure) { setDashboardError(errorMessage(failure)) } finally { setPendingListing(null) }
  }
  const sales = dashboard?.listings ?? []
  const purchases = dashboard?.purchases ?? []
  return <main className="study-market" aria-label="공부 마켓플레이스">
    <div className="study-market__content">
      <header className="study-market__header"><div><button type="button" className="study-market__school-button" onClick={() => setSchoolDialog(true)}>{school?.name ?? '대학교 선택'}<span aria-hidden="true">⌄</span></button><h1>마켓플레이스</h1><p>나의 공부가 누군가의 다음 공부가 되는 곳.</p></div><button className="button button--primary study-market__sell-button" type="button" onClick={startSelling}><Icon name="plus" />내 공부 판매</button></header>
      <nav className="study-market__tabs" aria-label="마켓플레이스 메뉴">{([['browse', '둘러보기'], ['purchases', '구매한 자료'], ['sales', '판매 관리']] as const).map(([id, label]) => <button type="button" key={id} aria-current={tab === id ? 'page' : undefined} data-active={tab === id} onClick={() => setTab(id)}>{label}</button>)}{dashboard?.operator && <button type="button" aria-current={tab === 'operator' ? 'page' : undefined} data-active={tab === 'operator'} onClick={() => setTab('operator')}>운영</button>}</nav>
      <MarketError message={contextError} retry={() => { void loadContext(); setListRevision(value => value + 1) }} />
      {context?.notice && <p className="study-market__notice">{context.notice}</p>}
      {!canTrade && context && !context.notice && <p className="study-market__notice">자료 거래를 준비하고 있어요. 판매 자료는 임시 저장할 수 있어요.</p>}
      {tab === 'browse' && <>
        {schoolId ? <><div className="study-market__toolbar"><label className="study-market__search"><Icon name="search" /><input aria-label="과목과 자료 검색" placeholder="어떤 과목의 자료를 찾나요?" value={query} onChange={event => setQuery(event.target.value)} />{query && <button type="button" aria-label="검색 지우기" onClick={() => setQuery('')}><Icon name="x" /></button>}</label><select aria-label="자료 정렬" value={sort} onChange={event => setSort(event.target.value as 'newest' | 'price')}><option value="newest">최신순</option><option value="price">낮은 가격순</option></select></div><div className="study-market__filters"><button type="button" className="study-market__chip" aria-pressed={!onlyMine && !courseFilter} onClick={() => { setOnlyMine(false); setCourseFilter('') }}>전체 과목</button><button type="button" className="study-market__chip" aria-pressed={onlyMine && !courseFilter} onClick={() => { setCourseFilter(''); setOnlyMine(true); if (mine.length === 0) setBindingDialog(true) }}>내 과목</button><select aria-label="과목 선택" value={courseFilter} onChange={event => { setCourseFilter(event.target.value); setOnlyMine(false) }}><option value="">과목 선택</option>{courses.map(course => <option value={course.id} key={course.id}>{course.name}</option>)}</select><button className="study-market__text-button study-market__binding-button" type="button" onClick={() => setBindingDialog(true)}>내 과목 연결</button></div><MarketError message={listError} retry={() => setListRevision(value => value + 1)} />
          {loading && listings.length === 0 ? <div className="study-market__skeleton" role="status" aria-label="자료를 불러오는 중">{[0, 1, 2].map(index => <div key={index}><span /><span /><span /></div>)}</div> : listings.length === 0 && !listError ? <MarketEmpty title={query ? '찾는 자료가 아직 없어요' : onlyMine && mine.length === 0 ? '내 과목을 연결해 주세요' : '이 학교의 첫 공부를 나눠 보세요'}>{query ? '과목 이름이나 다른 검색어로 찾아보세요.' : onlyMine && mine.length === 0 ? '내가 듣는 과목의 자료만 간편하게 볼 수 있어요.' : '정리한 필기, 연습문제, 시험 준비 자료를 하나의 묶음으로 판매할 수 있어요.'}</MarketEmpty> : <div className="study-market__listing-list">{listings.map(listing => <button type="button" className="study-market__listing" key={listing.id} onClick={() => setDetail(listing)}><span className="study-market__listing-image">{listing.previewUrls[0] ? <img src={listing.previewUrls[0]} alt="" loading="lazy" /> : <MarketIcon />}</span><span className="study-market__listing-copy"><span className="study-market__eyebrow">{listing.course.name}{listing.professor && ` · ${listing.professor}`}{listing.semester && ` · ${listing.semester}`}</span><strong>{listing.title}</strong><span className="study-market__listing-description">{listing.description}</span><small>{listing.sellerName} · 자료 {listing.files.filter(file => !file.preview).length}개</small></span><span className="study-market__listing-price">{listing.owned ? '구매한 자료' : formatWon(listing.price)}<Icon name="chevronRight" /></span></button>)}</div>}{nextCursor && <button className="button button--secondary study-market__more" type="button" disabled={loading} onClick={() => void more()}>{loading ? '불러오는 중…' : '더 보기'}</button>}
        </> : !context && !contextError ? <MarketEmpty title="마켓플레이스를 불러오고 있어요" /> : <MarketEmpty title="우리 학교의 공부를 만나 보세요" action={<button className="button button--primary" type="button" onClick={() => setSchoolDialog(true)}>대학교 선택</button>}>선택한 대학교를 기준으로 자료를 모아 볼 수 있어요.</MarketEmpty>}
      </>}
      {(tab === 'purchases' || tab === 'sales') && (!signedIn ? <MarketEmpty title={tab === 'purchases' ? '구매한 자료를 한곳에서' : '나의 공부를 나눠 보세요'} action={<button className="button button--primary" type="button" onClick={login}>로그인</button>}>반달 계정으로 로그인하면 구매와 판매 내역을 이어서 볼 수 있어요.</MarketEmpty> : <><MarketError message={dashboardError} retry={() => void refreshDashboard()} />{dashboardLoading && !dashboard ? <p role="status" className="study-market__loading">내역을 불러오고 있어요…</p> : <>
        {tab === 'purchases' && <><div className="study-market__section-title"><p className="study-market__muted">구매한 자료는 언제든 내 과목으로 가져올 수 있어요.</p><button type="button" className="study-market__text-button" onClick={() => void refreshDashboard()}>새로고침</button></div>{purchases.length === 0 ? <MarketEmpty title="아직 구매한 자료가 없어요">둘러보기에서 내 공부에 필요한 자료를 찾아보세요.</MarketEmpty> : <div className="study-market__rows">{purchases.map(order => <div className="study-market__row" key={order.id}><span className="study-market__row-icon"><Icon name="fileText" /></span><div className="study-market__row-copy"><span className="study-market__eyebrow">{order.courseName} · {new Date(order.createdAt).toLocaleDateString('ko-KR')}</span><strong>{order.title}</strong><small>{formatWon(order.amount)} · {ORDER_LABELS[order.status]}</small></div><div className="study-market__row-actions">{order.receiptUrl && <button className="study-market__text-button" type="button" onClick={() => void receipt(order)}>영수증</button>}{order.status === 'paid' && <><button className="study-market__text-button" type="button" onClick={() => setRefundOrder(order)}>환불 요청</button><button className="button button--secondary" type="button" onClick={() => setImportOrder(order)}>내 과목에 가져오기</button></>}{order.status === 'pending' && <button className="button button--secondary" type="button" onClick={() => setCheckout(order)}>결제 확인</button>}</div></div>)}</div>}</>}
        {tab === 'sales' && <><div className="study-market__seller-status"><div><strong>{SELLER_LABELS[dashboard?.seller.status ?? 'unregistered']}</strong><p>{dashboard?.seller.reason || (dashboard?.seller.status === 'ready' ? '결제 후 7일이 지난 판매대금을 매주 금요일 지급해요.' : '자료를 임시 저장한 뒤 판매자 등록을 완료해 주세요.')}</p></div>{dashboard?.seller.status === 'unregistered' ? <button className="button button--secondary" type="button" onClick={() => setSellerDialog(true)}>판매자 등록</button> : <button className="button button--secondary" type="button" onClick={() => void refreshDashboard()}>상태 확인</button>}</div><div className="study-market__totals"><div><span>판매 건수</span><strong>{dashboard?.salesCount ?? 0}<small>건</small></strong></div><div><span>지급 대기</span><strong>{formatWon(dashboard?.pendingAmount ?? 0)}</strong></div><div><span>지급 완료</span><strong>{formatWon(dashboard?.paidAmount ?? 0)}</strong></div></div><div className="study-market__section-title"><h2>내 판매 자료</h2><button className="study-market__text-button" type="button" onClick={startSelling}>새 자료 판매</button></div>{sales.length === 0 ? <MarketEmpty title="첫 판매 자료를 만들어 보세요">내 과목의 자료를 고르고 가격을 정하면 돼요.</MarketEmpty> : <div className="study-market__rows">{sales.map(listing => <div className="study-market__row" key={listing.id}><div className="study-market__row-copy"><span className="study-market__eyebrow">{listing.course.name} · {listing.status === 'published' ? '판매 중' : listing.status === 'draft' || listing.status === 'sealing' ? '임시 저장' : listing.status === 'blocked' ? '판매 제한' : '판매 중지'}</span><strong>{listing.title}</strong><small>{formatWon(listing.price)}</small></div><div className="study-market__row-actions">{listing.status === 'draft' || listing.status === 'sealing' ? <button className="button button--secondary" type="button" onClick={() => { chooseSchool(listing.universityId); setDraft(listing); setSaleIntent(null); setSelling(true) }}>이어서 만들기</button> : <button className="study-market__text-button" type="button" onClick={() => setDetail(listing)}>보기</button>}{(listing.status === 'published' || listing.status === 'withdrawn') && <button className="button button--secondary" type="button" onClick={() => { chooseSchool(listing.universityId); setDraft(listing); setSaleIntent(null); setSelling(true) }}>{listing.status === 'published' ? '수정하기' : '판매 재개'}</button>}{listing.status === 'published' && <button className="button button--secondary" type="button" disabled={pendingListing === listing.id} onClick={() => void withdraw(listing)}>판매 중지</button>}</div></div>)}</div>}{!!dashboard?.payouts.length && <><div className="study-market__section-title"><h2>지급 내역</h2></div><div className="study-market__rows">{dashboard.payouts.map(payout => <div className="study-market__row" key={payout.id}><div className="study-market__row-copy"><strong>{formatWon(payout.amount)}</strong><small>{payout.paidAt ? new Date(payout.paidAt).toLocaleDateString('ko-KR') : payout.scheduledAt ? `${new Date(payout.scheduledAt).toLocaleDateString('ko-KR')} 예정` : '정산 가능 금액 확인 중'}{payout.reason && ` · ${payout.reason}`}</small></div><span className="study-market__badge">{PAYOUT_LABELS[payout.status]}</span></div>)}</div></>}</>}
      </>}</>)}
      {tab === 'operator' && dashboard?.operator && <OperatorPanel />}
    </div>
    {schoolDialog && <SchoolDialog universities={context?.universities ?? []} currentName={university?.nameKo ?? ''} signedIn={signedIn} onClose={() => { setSchoolDialog(false); if (!schoolId) setSelling(false) }} onSelect={chooseSchool} onLogin={login} />}
    {bindingDialog && schoolId && <CourseBindingDialog universityId={schoolId} courses={courses} onClose={() => setBindingDialog(false)} onSaved={() => { setBindingDialog(false); setBindingRevision(value => value + 1) }} />}
    {selling && signedIn && school && schoolReady === school.id && !schoolDialog && <SaleDialog universityId={school.id} universityName={school.name} marketCourses={courses} intent={saleIntent} draft={draft} canPublish={canPublish} onClose={() => setSelling(false)} onSaved={published => { setSelling(false); setTab('sales'); void refreshDashboard(); setListRevision(value => value + 1); showToast(published ? '판매를 시작했어요.' : '판매 자료를 임시 저장했어요.') }} />}
    {detail && <ListingDialog listing={detail} signedIn={signedIn} canTrade={canTrade} own={detail.sellerId === auth.profile?.id} onClose={() => setDetail(null)} onLogin={login} onOrder={order => { setDetail(null); setCheckout(order); setTab('purchases'); void refreshDashboard() }} />}
    {checkout && <CheckoutDialog order={checkout} onClose={() => { setCheckout(null); setTab('purchases'); void refreshDashboard() }} onComplete={completeCheckout} />}
    {importOrder && <ImportDialog order={importOrder} onClose={() => setImportOrder(null)} onDone={() => { setImportOrder(null); void refreshDashboard(); showToast('내 과목에 자료를 가져왔어요.') }} />}
    {refundOrder && <RefundDialog order={refundOrder} onClose={() => setRefundOrder(null)} onDone={() => { setRefundOrder(null); void refreshDashboard(); showToast('환불 요청을 접수했어요.') }} />}
    {sellerDialog && <SellerDialog onClose={() => setSellerDialog(false)} onDone={() => { setSellerDialog(false); void refreshDashboard(); showToast('등록했어요. 토스페이먼츠의 본인인증 안내를 확인해 주세요.') }} />}
  </main>
}
