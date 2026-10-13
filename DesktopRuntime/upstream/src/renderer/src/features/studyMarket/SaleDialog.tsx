import { useEffect, useMemo, useRef, useState } from 'react'
import { STUDY_MARKET_LIMITS, normalizeMarketCourseName, type StudyMarketCourse, type StudyMarketListing, type StudyMarketPreparedBundle, type StudyMarketPreview } from '../../../../shared/types/studyMarket'
import type { MaterialNode } from '../../../../shared/types/materials'
import { useCoursesStore } from '../../stores/coursesStore'
import { invoke } from '../../lib/ipc'
import { flushOpenNoteSession } from '../notes/noteSessionRegistry'
import { marketRequest, readCourseBindings, saveCourseBinding } from './api'
import type { StudyMarketSellIntent } from './controller'
import { Field, MarketDialog, MarketError } from './primitives'
import { errorMessage, formatBytes, formatWon, initialSaleSelection, saleMaterials, sellerProceeds, validPrice } from './presentation'
import { renderMarketPreview } from './renderPreview'

export function SaleDialog({ universityId, universityName, marketCourses, intent, draft, canPublish, onClose, onSaved }: {
  universityId: string; universityName: string; marketCourses: StudyMarketCourse[]
  intent: StudyMarketSellIntent | null; draft: StudyMarketListing | null; canPublish: boolean
  onClose: () => void; onSaved: (published: boolean) => void
}): JSX.Element {
  const allCourses = useCoursesStore(state => state.courses)
  const localCourses = useMemo(() => allCourses.filter(course => !course.missing && !course.archived && course.workspaceKind !== 'study-space'), [allCourses])
  const [step, setStep] = useState(draft && draft.status !== 'published' ? 1 : 0)
  const [replacingFiles, setReplacingFiles] = useState(draft?.status === 'published')
  const reusingDraft = draft !== null && !replacingFiles
  const [localCourseId, setLocalCourseId] = useState(intent?.courseId ?? localCourses[0]?.id ?? '')
  const [courseName, setCourseName] = useState(draft?.course.name ?? '')
  const [boundCourseId, setBoundCourseId] = useState(draft?.course.id ?? '')
  const [files, setFiles] = useState<MaterialNode[]>([])
  const [selected, setSelected] = useState<string[]>([])
  const [loadingFiles, setLoadingFiles] = useState(false)
  const [bundle, setBundle] = useState<StudyMarketPreparedBundle | null>(null)
  const bundleRef = useRef<StudyMarketPreparedBundle | null>(null)
  const [previews, setPreviews] = useState<StudyMarketPreview[]>([])
  const [sourceId, setSourceId] = useState('')
  const [previewPage, setPreviewPage] = useState('1')
  const [previewText, setPreviewText] = useState('')
  const [title, setTitle] = useState(draft?.title ?? '')
  const [description, setDescription] = useState(draft?.description ?? '')
  const [priceText, setPriceText] = useState(draft ? String(draft.price) : '')
  const [professor, setProfessor] = useState(draft?.professor ?? '')
  const [semester, setSemester] = useState(draft?.semester ?? '')
  const [rightsConfirmed, setRightsConfirmed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [busyLabel, setBusyLabel] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [savedDraft, setSavedDraft] = useState<StudyMarketListing | null>(draft)
  const price = validPrice(priceText)
  const previewUrls = [...(reusingDraft ? draft?.previewUrls ?? [] : []), ...previews.map(preview => preview.dataUrl)]
  const paidFiles = bundle?.files.filter(file => !file.preview) ?? (reusingDraft ? draft?.files.filter(file => !file.preview) ?? [] : [])
  const selectedBytes = files.filter(file => selected.includes(file.relPath)).reduce((sum, file) => sum + (file.size ?? 0), 0)
  const sourceFile = bundle?.files.find(file => file.id === sourceId)
  const isPdf = sourceFile?.mime === 'application/pdf'
  const isText = sourceFile?.mime.startsWith('text/') ?? false
  const metadataValid = title.trim().length > 0 && description.trim().length > 0 && price !== null && previewUrls.length > 0

  useEffect(() => () => {
    const current = bundleRef.current
    if (current) void invoke('studyMarket:discardBundle', { bundleId: current.id }).catch(() => {})
  }, [])

  useEffect(() => {
    if (reusingDraft || !localCourseId) return
    let cancelled = false
    setLoadingFiles(true)
    setFiles([])
    setSelected([])
    setError(null)
    const binding = readCourseBindings(universityId)[localCourseId]
    const bound = marketCourses.find(course => course.id === binding)
    const local = localCourses.find(course => course.id === localCourseId)
    setCourseName(bound?.name ?? local?.name ?? '')
    void invoke('materials:tree', { courseId: localCourseId }).then(tree => {
      if (cancelled) return
      const allowed = saleMaterials(tree)
      setFiles(allowed)
      setSelected(initialSaleSelection(allowed, intent?.courseId === localCourseId ? intent.relPath : undefined))
    }).catch(failure => { if (!cancelled) setError(errorMessage(failure)) }).finally(() => { if (!cancelled) setLoadingFiles(false) })
    return () => { cancelled = true }
  }, [localCourseId, universityId, reusingDraft, marketCourses, localCourses, intent])

  const prepare = async (): Promise<void> => {
    if (busy || !localCourseId || !courseName.trim() || selected.length === 0) return
    setBusy(true); setBusyLabel('자료를 준비하고 있어요'); setError(null)
    try {
      for (const relPath of selected) {
        if (!/\.md$/i.test(relPath)) continue
        const flushed = await flushOpenNoteSession({ courseId: localCourseId, relPath })
        if (flushed && ['conflict', 'error', 'unavailable'].includes(flushed.result.status)) {
          setError('저장하지 못한 필기가 있어요. 해당 필기를 저장한 뒤 다시 시도해 주세요.')
          return
        }
      }
      const common = marketCourses.find(course => normalizeMarketCourseName(course.name) === normalizeMarketCourseName(courseName))
        ?? await marketRequest('createCourse', { universityId, name: courseName.trim() })
      setBoundCourseId(common.id)
      saveCourseBinding(universityId, localCourseId, common.id)
      const prepared = await invoke('studyMarket:prepare', { courseId: localCourseId, relPaths: selected })
      if (bundleRef.current) await invoke('studyMarket:discardBundle', { bundleId: bundleRef.current.id })
      bundleRef.current = prepared
      setBundle(prepared); setPreviews([]); setSourceId(prepared.files[0]?.id ?? '')
      if (!title) setTitle(`${common.name} 공부 자료`)
      setStep(1)
    } catch (failure) { setError(errorMessage(failure)) } finally { setBusy(false) }
  }

  const addPreview = async (external = false): Promise<void> => {
    if (!bundle || busy || previewUrls.length >= STUDY_MARKET_LIMITS.previews) return
    setBusy(true); setBusyLabel('미리보기를 만들고 있어요'); setError(null)
    try {
      let dataUrl: string
      if (external) {
        const picked = await invoke('studyMarket:pickPreviewImage', {})
        if (!picked) return
        dataUrl = picked.dataUrl
      } else {
        const source = await invoke('studyMarket:previewSource', { bundleId: bundle.id, fileId: sourceId, ...(isPdf ? { page: Number(previewPage) } : {}), ...(isText && previewText.trim() ? { text: previewText.trim() } : {}) })
        dataUrl = await renderMarketPreview(source)
      }
      const preview = await invoke('studyMarket:preview', { bundleId: bundle.id, fileId: sourceId || bundle.files[0]!.id, dataUrl })
      setPreviews(current => [...current, preview])
    } catch (failure) { setError(errorMessage(failure)) } finally { setBusy(false) }
  }

  const save = async (publish: boolean): Promise<void> => {
    if (busy || !metadataValid || (publish && (!rightsConfirmed || !canPublish)) || price === null) return
    setBusy(true); setBusyLabel(publish ? '자료를 공개하고 있어요' : '임시 저장하고 있어요'); setError(null)
    try {
      const listing = await marketRequest('saveDraft', {
        ...(savedDraft ? { id: savedDraft.id } : {}), universityId, courseId: boundCourseId,
        title: title.trim(), description: description.trim(), price, professor: professor.trim(), semester: semester.trim(),
        files: bundle ? [...bundle.files.filter(file => !file.preview), ...previews.map(preview => preview.file)] : draft?.files ?? [],
        rightsConfirmed
      })
      setSavedDraft(listing)
      if (bundle) await invoke('studyMarket:upload', { bundleId: bundle.id, versionId: listing.versionId, fileIds: [...paidFiles.map(file => file.id), ...previews.map(preview => preview.file.id)], publish })
      else if (publish) await marketRequest('publish', { versionId: listing.versionId })
      onSaved(publish)
    } catch (failure) { setError(errorMessage(failure)) } finally { setBusy(false) }
  }

  const removePreview = async (index: number): Promise<void> => {
    const preview = previews[index]
    if (!bundle || !preview || busy) return
    setBusy(true); setBusyLabel('미리보기를 삭제하고 있어요')
    try {
      await invoke('studyMarket:discardPreview', { bundleId: bundle.id, fileId: preview.file.id })
      setPreviews(current => current.filter(item => item.file.id !== preview.file.id))
    } catch (failure) { setError(errorMessage(failure)) } finally { setBusy(false) }
  }

  return <MarketDialog title={draft?.status === 'published' ? '판매 자료 수정하기' : draft?.status === 'withdrawn' ? '판매 재개' : draft ? '판매 자료 이어서 만들기' : '내 공부 판매하기'} busy={busy} onClose={onClose} wide>
    <ol className="study-market__steps" aria-label="판매 등록 단계">{['자료 선택', '판매 정보', '공개 전 확인'].map((label, index) => <li key={label} aria-current={step === index ? 'step' : undefined} data-active={step === index}><span>{index + 1}</span>{label}</li>)}</ol>
    <fieldset className="study-market__dialog-body study-market__fieldset" disabled={busy}>
      <MarketError message={error} />
      {step === 0 && <div className="study-market__form">
        {draft?.status === 'published' && <p className="study-market__notice">수정할 자료를 새로 선택해 주세요. 이전 구매자는 구매 당시의 자료를 그대로 받아요.</p>}
        <p className="study-market__muted">{universityName}에서 나눌 자료를 골라 주세요. 선택한 파일의 사본을 판매해요.</p>
        <Field label="내 과목"><select value={localCourseId} onChange={event => setLocalCourseId(event.target.value)} disabled={busy}>{localCourses.length === 0 && <option value="">먼저 과목을 만들어 주세요</option>}{localCourses.map(course => <option key={course.id} value={course.id}>{course.name}</option>)}</select></Field>
        <Field label="마켓플레이스 과목" hint="같은 이름의 과목으로 모여요. 개인 폴더 이름은 바뀌지 않아요."><input list="study-market-common-courses" value={courseName} maxLength={100} onChange={event => setCourseName(event.target.value)} disabled={busy} placeholder="예: 경제학원론" /><datalist id="study-market-common-courses">{marketCourses.map(course => <option key={course.id} value={course.name} />)}</datalist></Field>
        <div className="study-market__section-title"><strong>판매할 자료</strong><button type="button" className="study-market__text-button" disabled={busy || files.length === 0} onClick={() => setSelected(selected.length === files.length ? [] : files.map(file => file.relPath))}>{selected.length === files.length ? '전체 해제' : '전체 선택'}</button></div>
        <div className="study-market__file-picker" aria-busy={loadingFiles}>{loadingFiles ? <p role="status">자료를 불러오고 있어요…</p> : files.length === 0 ? <p>판매할 수 있는 자료가 아직 없어요.</p> : files.map(file => <label key={file.relPath} className="study-market__file-option"><input type="checkbox" disabled={busy} checked={selected.includes(file.relPath)} onChange={event => setSelected(current => event.target.checked ? [...current, file.relPath] : current.filter(path => path !== file.relPath))} /><span>{file.relPath}</span><small>{formatBytes(file.size ?? 0)}</small></label>)}</div>
        <p className="study-market__hint">{selected.length}개 · {formatBytes(selectedBytes)} / 최대 100개 · 전체 200 MB · 파일당 50 MB<br />PDF, 필기·텍스트, 이미지, Word, PowerPoint, Excel 파일을 판매할 수 있어요.</p>
      </div>}
      {step === 1 && <div className="study-market__form">
        {reusingDraft && <button type="button" className="study-market__text-button study-market__align-start" onClick={() => { setReplacingFiles(true); setStep(0) }}>자료 다시 선택</button>}
        {bundle?.warnings.map(warning => <p className="study-market__notice" key={warning}>{warning}</p>)}
        <Field label="자료 제목"><input value={title} onChange={event => setTitle(event.target.value)} maxLength={100} placeholder="예: 중간고사 핵심 개념과 연습문제" /></Field>
        <Field label="설명"><textarea value={description} onChange={event => setDescription(event.target.value)} maxLength={4000} rows={3} placeholder="어떤 내용인지, 어떻게 공부할 때 도움이 되는지 알려 주세요." /></Field>
        <div className="study-market__form-row"><Field label="교수명 · 선택"><input value={professor} onChange={event => setProfessor(event.target.value)} maxLength={100} placeholder="교수명" /></Field><Field label="학기 · 선택"><input value={semester} onChange={event => setSemester(event.target.value)} maxLength={40} placeholder="예: 2026년 2학기" /></Field></div>
        <Field label="묶음 가격" hint={price === null ? '원 단위의 금액을 입력해 주세요.' : `판매 시 ${formatWon(sellerProceeds(price))}을 받아요. 수수료 10%에 결제·정산 비용이 포함돼요.`}><div className="study-market__price-input"><input inputMode="numeric" value={priceText} onChange={event => setPriceText(event.target.value)} placeholder="0" aria-label="묶음 가격 (원)" /><span>원</span></div></Field>
        <div className="study-market__section-title"><strong>공개 미리보기 <small>{previewUrls.length}/3</small></strong></div>
        <p className="study-market__hint">누구나 볼 수 있는 이미지예요. 개인정보를 가리고 최소 1장을 추가해 주세요.</p>
        <div className="study-market__preview-grid">{previewUrls.map((url, index) => <figure key={`${url.slice(-24)}-${index}`}><img src={url} alt={`공개 미리보기 ${index + 1}`} />{index >= (reusingDraft ? draft?.previewUrls.length ?? 0 : 0) && <button type="button" disabled={busy} aria-label={`미리보기 ${index + 1} 삭제`} onClick={() => void removePreview(index - (reusingDraft ? draft?.previewUrls.length ?? 0 : 0))}>×</button>}</figure>)}</div>
        {bundle && previewUrls.length < 3 && <div className="study-market__preview-builder">
          <Field label="자료에서 미리보기 만들기"><select value={sourceId} disabled={busy} onChange={event => { setSourceId(event.target.value); setPreviewPage('1'); setPreviewText('') }}>{paidFiles.map(file => <option key={file.id} value={file.id}>{file.path}</option>)}</select></Field>
          {isPdf && <Field label="공개할 페이지"><input type="number" min={1} step={1} value={previewPage} onChange={event => setPreviewPage(event.target.value)} /></Field>}
          {isText && <Field label="공개할 문장 · 선택" hint="비워 두면 자료의 앞부분으로 만들어요."><textarea value={previewText} onChange={event => setPreviewText(event.target.value)} maxLength={1500} rows={3} /></Field>}
          <div className="study-market__actions"><button className="button button--secondary" type="button" disabled={busy || (!isPdf && !isText && !sourceFile?.mime.startsWith('image/')) || (isPdf && (!Number.isInteger(Number(previewPage)) || Number(previewPage) < 1))} onClick={() => void addPreview()}>미리보기 만들기</button><button className="button button--secondary" type="button" disabled={busy} onClick={() => void addPreview(true)}>이미지 직접 추가</button></div>
          {sourceFile && !isPdf && !isText && !sourceFile.mime.startsWith('image/') && <p className="study-market__hint">문서에서 보여 주고 싶은 부분을 이미지로 준비해 추가해 주세요.</p>}
        </div>}
      </div>}
      {step === 2 && <div className="study-market__form">
        <p className="study-market__eyebrow">{universityName} · {courseName}</p><h3 className="study-market__confirm-title">{title}</h3><p className="study-market__description">{description}</p>
        <div className="study-market__preview-grid">{previewUrls.map((url, index) => <figure key={index}><img src={url} alt={`공개 미리보기 ${index + 1}`} /></figure>)}</div>
        <div className="study-market__summary"><span>자료 {paidFiles.length}개 · {formatBytes(paidFiles.reduce((sum, file) => sum + file.bytes, 0))}</span><strong>{formatWon(price ?? 0)}</strong></div>
        <p className="study-market__hint">공개한 자료는 이 시점의 사본으로 제공해요. 원래 과목 폴더를 수정해도 판매 자료는 바뀌지 않아요.</p>
        <label className="study-market__check"><input type="checkbox" checked={rightsConfirmed} onChange={event => setRightsConfirmed(event.target.checked)} /><span>직접 만든 자료이거나 판매할 권한이 있어요. 교수·출판사의 허락 없는 자료, 타인의 개인정보, 구매한 자료를 다시 판매하지 않아요.</span></label>
        {!canPublish && <p className="study-market__notice">임시 저장할 수 있어요. 판매자 등록과 거래 준비가 완료되면 공개할 수 있어요.</p>}
      </div>}
      {busy && <p className="study-market__hint" role="status">{busyLabel}…</p>}
    </fieldset>
    <footer className="study-market__dialog-footer">
      <button type="button" className="button button--secondary" disabled={busy} onClick={step > (reusingDraft ? 1 : 0) ? () => { setStep(step - 1); setError(null) } : onClose}>{step > (reusingDraft ? 1 : 0) ? '이전' : '취소'}</button>
      <div className="study-market__actions">{step > 0 && <button type="button" className="button button--secondary" disabled={busy || !metadataValid} onClick={() => void save(false)}>임시 저장</button>}{step === 0 ? <button type="button" className="button button--primary" disabled={busy || loadingFiles || selected.length === 0 || selected.length > STUDY_MARKET_LIMITS.files || selectedBytes > STUDY_MARKET_LIMITS.bundleBytes || !courseName.trim()} onClick={() => void prepare()}>다음</button> : step === 1 ? <button type="button" className="button button--primary" disabled={busy || !metadataValid} onClick={() => setStep(2)}>공개 전 확인</button> : <button type="button" className="button button--primary" disabled={busy || !rightsConfirmed || !canPublish} onClick={() => void save(true)}>판매 시작</button>}</div>
    </footer>
  </MarketDialog>
}
