import { useEffect, useState, type FormEvent } from 'react'
import type { StudyMarketApi, StudyMarketCourse, StudyMarketOperatorCase, StudyMarketUniversity } from '../../../../shared/types/studyMarket'
import { useCoursesStore } from '../../stores/coursesStore'
import { marketRequest, readCourseBindings, saveCourseBinding } from './api'
import { Field, MarketDialog, MarketEmpty, MarketError } from './primitives'
import { errorMessage, formatWon } from './presentation'

export function SchoolDialog({ universities, currentName, signedIn, onSelect, onClose, onLogin }: { universities: StudyMarketUniversity[]; currentName: string; signedIn: boolean; onSelect: (id: string) => void; onClose: () => void; onLogin: () => void }): JSX.Element {
  const [query, setQuery] = useState('')
  const [requestName, setRequestName] = useState(currentName)
  const [requested, setRequested] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const request = async (): Promise<void> => {
    if (!signedIn) { onLogin(); return }
    setBusy(true)
    try { await marketRequest('requestUniversity', { name: requestName.trim() }); setRequested(true) } catch (failure) { setError(errorMessage(failure)) } finally { setBusy(false) }
  }
  const found = universities.filter(school => school.name.replace(/\s/g, '').includes(query.replace(/\s/g, '')))
  return <MarketDialog title="대학교 선택" onClose={onClose} busy={busy}><div className="study-market__dialog-body study-market__form"><p className="study-market__hint">선택한 학교의 자료를 모아 봐요. 재학 여부를 인증하는 기능은 아니에요.</p>{currentName && <p className="study-market__hint">반달에서 선택한 학교: {currentName}</p>}<Field label="학교 검색"><input autoFocus value={query} onChange={event => setQuery(event.target.value)} placeholder="대학교 이름" /></Field><div className="study-market__school-options">{found.map(school => <button type="button" key={school.id} onClick={() => onSelect(school.id)}>{school.name}<span aria-hidden="true">→</span></button>)}{found.length === 0 && <p className="study-market__muted">검색된 학교가 없어요.</p>}</div><details className="study-market__included"><summary>우리 학교가 없나요?</summary>{requested ? <p role="status">추가 요청을 보냈어요. 운영자가 학교를 확인하면 선택할 수 있어요.</p> : <div className="study-market__form"><Field label="추가할 대학교"><input value={requestName} onChange={event => setRequestName(event.target.value)} maxLength={100} /></Field><button className="button button--secondary" type="button" disabled={busy || !requestName.trim()} onClick={() => void request()}>{signedIn ? '학교 추가 요청' : '로그인하고 요청'}</button></div>}</details><MarketError message={error} /></div></MarketDialog>
}

export function CourseBindingDialog({ universityId, courses, onClose, onSaved }: { universityId: string; courses: StudyMarketCourse[]; onClose: () => void; onSaved: () => void }): JSX.Element {
  const localCourses = useCoursesStore(state => state.courses)
  const [bindings, setBindings] = useState(() => readCourseBindings(universityId))
  return <MarketDialog title="내 과목 연결" onClose={onClose}><div className="study-market__dialog-body study-market__form"><p className="study-market__hint">내 과목을 마켓플레이스의 과목과 연결하면 듣는 수업의 자료만 모아 볼 수 있어요.</p>{localCourses.filter(course => !course.archived && course.workspaceKind !== 'study-space').map(local => <Field key={local.id} label={local.name}><select value={bindings[local.id] ?? ''} onChange={event => setBindings(current => ({ ...current, [local.id]: event.target.value }))}><option value="">연결하지 않음</option>{courses.map(course => <option key={course.id} value={course.id}>{course.name}</option>)}</select></Field>)}{localCourses.length === 0 && <p>먼저 반달에서 과목을 만들어 주세요.</p>}</div><footer className="study-market__dialog-footer"><button className="button button--secondary" type="button" onClick={onClose}>취소</button><button className="button button--primary" type="button" onClick={() => { Object.entries(bindings).forEach(([local, market]) => saveCourseBinding(universityId, local, market)); onSaved() }}>연결 저장</button></footer></MarketDialog>
}

// Toss seller registration accepts the official three-digit bank codes.
// https://docs.tosspayments.com/codes/org-codes
const BANKS = [['004', 'KB국민은행'], ['088', '신한은행'], ['020', '우리은행'], ['081', '하나은행'], ['011', 'NH농협은행'], ['003', 'IBK기업은행'], ['090', '카카오뱅크'], ['092', '토스뱅크'], ['089', '케이뱅크'], ['023', 'SC제일은행'], ['031', 'iM뱅크'], ['032', '부산은행'], ['034', '광주은행'], ['035', '제주은행'], ['037', '전북은행'], ['039', '경남은행']] as const

export function SellerDialog({ onClose, onDone }: { onClose: () => void; onDone: () => void }): JSX.Element {
  const [form, setForm] = useState({ displayName: '', name: '', email: '', phone: '', bankCode: '004', accountNumber: '', holderName: '' })
  const [consent, setConsent] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const change = (key: keyof typeof form, value: string): void => setForm(current => ({ ...current, [key]: key === 'phone' ? value.replace(/[^0-9]/g, '') : value }))
  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault(); setBusy(true); setError(null)
    try { await marketRequest('registerSeller', form); onDone() } catch (failure) { setError(errorMessage(failure)) } finally { setBusy(false) }
  }
  return <MarketDialog title="판매자 등록" onClose={onClose} busy={busy}><form onSubmit={event => void submit(event)}><fieldset className="study-market__dialog-body study-market__form study-market__fieldset" disabled={busy}><p className="study-market__hint">판매대금을 받을 정보를 등록해 주세요. 이름·계좌·연락처는 구매자에게 공개되지 않아요. 등록 후 토스페이먼츠의 본인인증 안내를 확인해 주세요.</p><Field label="공개 판매자 이름"><input required value={form.displayName} maxLength={40} onChange={event => change('displayName', event.target.value)} /></Field><Field label="본인 이름"><input required autoComplete="name" value={form.name} maxLength={50} onChange={event => change('name', event.target.value)} /></Field><div className="study-market__form-row"><Field label="이메일"><input required type="email" autoComplete="email" value={form.email} maxLength={100} onChange={event => change('email', event.target.value)} /></Field><Field label="휴대폰 번호"><input required type="tel" autoComplete="tel" value={form.phone} maxLength={20} onChange={event => change('phone', event.target.value)} /></Field></div><Field label="정산 은행"><select value={form.bankCode} onChange={event => change('bankCode', event.target.value)}>{BANKS.map(([code, label]) => <option key={code} value={code}>{label}</option>)}</select></Field><Field label="계좌번호"><input required inputMode="numeric" value={form.accountNumber} maxLength={14} onChange={event => change('accountNumber', event.target.value.replace(/[^0-9]/g, ''))} /></Field><Field label="예금주"><input required value={form.holderName} maxLength={50} onChange={event => change('holderName', event.target.value)} /></Field><p className="study-market__hint">판매금액의 90%를 받아요. 결제 후 7일이 지나고 정산 가능한 판매대금을 매주 금요일 지급해요. 휴일·심사·환불 확인이 필요한 경우 늦어질 수 있어요.</p><label className="study-market__check"><input type="checkbox" checked={consent} onChange={event => setConsent(event.target.checked)} /><span>정산과 본인확인을 위해 입력한 정보를 토스페이먼츠에 전달하는 데 동의해요.</span></label><MarketError message={error} /></fieldset><footer className="study-market__dialog-footer"><button type="button" className="button button--secondary" disabled={busy} onClick={onClose}>취소</button><button type="submit" className="button button--primary" disabled={busy || !consent || Object.values(form).some(value => !value.trim())}>{busy ? '등록 중…' : '등록하고 본인인증'}</button></footer></form></MarketDialog>
}

const CASE_NAMES: Record<StudyMarketOperatorCase['kind'], string> = { report: '자료 신고', refund: '환불 검토', payout: '지급 실패', receivable: '미수금', school: '학교 추가' }
type OperatorAction = StudyMarketApi['operatorAction']['req']['action']
const CASE_ACTIONS: Record<StudyMarketOperatorCase['kind'], Array<[OperatorAction, string]>> = { report: [['block', '자료 숨김'], ['resolveReport', '신고 처리 완료']], refund: [['refund', '환불 승인'], ['rejectRefund', '환불 반려']], payout: [['holdSeller', '판매자 지급 보류'], ['releaseSeller', '보류 해제']], receivable: [['holdSeller', '판매자 지급 보류']], school: [['addUniversity', '학교 추가']] }

export function OperatorPanel(): JSX.Element {
  const [data, setData] = useState<StudyMarketApi['operatorDashboard']['res'] | null>(null)
  const [target, setTarget] = useState<StudyMarketOperatorCase | null>(null)
  const [action, setAction] = useState<OperatorAction>('resolveReport')
  const [reason, setReason] = useState('')
  const [name, setName] = useState('')
  const [schoolSlug, setSchoolSlug] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const load = async (): Promise<void> => { try { setData(await marketRequest('operatorDashboard', {})); setError(null) } catch (failure) { setError(errorMessage(failure)) } }
  useEffect(() => { void load() }, [])
  const run = async (): Promise<void> => {
    if (!target) return
    setBusy(true)
    try { await marketRequest('operatorAction', { action, id: action === 'resolveReport' ? target.id : action === 'addUniversity' ? schoolSlug.trim() : target.subjectId, reason: reason.trim(), ...(action === 'addUniversity' ? { name: name.trim() } : {}) }); setTarget(null); setReason(''); await load() } catch (failure) { setError(errorMessage(failure)) } finally { setBusy(false) }
  }
  return <section className="study-market__management"><div className="study-market__section-title"><h2>운영</h2><button className="study-market__text-button" type="button" onClick={() => void load()}>새로고침</button></div><MarketError message={error} />{!data ? <p role="status">운영 내역을 불러오고 있어요…</p> : data.cases.length === 0 ? <MarketEmpty title="처리할 요청이 없어요" /> : <div className="study-market__rows">{data.cases.map(item => <div className="study-market__row" key={item.id}><div className="study-market__row-copy"><span className="study-market__eyebrow">{CASE_NAMES[item.kind]} · {item.status}</span><strong>{item.reason}</strong><small>{new Date(item.createdAt).toLocaleString('ko-KR')}{item.amount !== undefined && ` · ${formatWon(item.amount)}`}</small></div><button className="button button--secondary" type="button" onClick={() => { setTarget(item); setAction(CASE_ACTIONS[item.kind][0]![0]); setName(item.kind === 'school' ? item.reason : '') }}>처리</button></div>)}</div>}{data && data.audit.length > 0 && <details className="study-market__included"><summary>최근 운영 기록</summary><ul>{data.audit.map(item => <li key={item.id}><span>{item.action} · {item.reason}</span><small>{new Date(item.createdAt).toLocaleDateString('ko-KR')}</small></li>)}</ul></details>}{target && <MarketDialog title={CASE_NAMES[target.kind]} onClose={() => setTarget(null)} busy={busy}><div className="study-market__dialog-body study-market__form"><p>{target.reason}</p><Field label="처리 방법"><select value={action} onChange={event => setAction(event.target.value as OperatorAction)}>{CASE_ACTIONS[target.kind].map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></Field>{action === 'addUniversity' && <><Field label="공식 학교 이름"><input value={name} onChange={event => setName(event.target.value)} /></Field><Field label="학교 식별자" hint="영문 소문자·숫자·하이픈으로 입력해 주세요. 예: snu"><input value={schoolSlug} onChange={event => setSchoolSlug(event.target.value)} maxLength={80} /></Field></>}<Field label="처리 사유"><textarea value={reason} onChange={event => setReason(event.target.value)} maxLength={2000} rows={3} /></Field><MarketError message={error} /></div><footer className="study-market__dialog-footer"><button className="button button--secondary" type="button" disabled={busy} onClick={() => setTarget(null)}>취소</button><button className="button button--primary" type="button" disabled={busy || !reason.trim() || (action === 'addUniversity' && (!name.trim() || !/^[a-z][a-z0-9-]{1,79}$/.test(schoolSlug.trim())))} onClick={() => void run()}>처리 확정</button></footer></MarketDialog>}</section>
}
