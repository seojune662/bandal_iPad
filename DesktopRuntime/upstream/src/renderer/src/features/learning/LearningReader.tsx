import { useCallback, useEffect, useId, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import type { LearningArticleSnapshot, LearningProjectSnapshot } from '../../../../shared/types/learning'
import { showToast } from '../../app/toast'
import { Icon } from '../../app/icons'
import { createBrowserTab } from '../../app/tabCommands'
import { invoke } from '../../lib/ipc'
import { learningWordForSurface, readerSavedOccurrence, readerSelectionKey, readerVocabularyMatches, readerWordSelection, selectionInReader, type ReaderWordSelection } from './readerSelection'
import { learningError, notifyLearningChanged } from './learningNavigation'
import { startLearningRun } from './learningStartedRuns'
import { ReaderDictionaryPopover, type ReaderDefinitionDraft, type ReaderSelectionAnchor } from './ReaderDictionaryPopover'
import { useReaderProgress } from './useReaderProgress'
import { LearningSources } from './LearningSources'

interface ReaderSelection { value: ReaderWordSelection; anchor: ReaderSelectionAnchor }

export function LearningReader({ project, article, active = true, onUpdate, onComplete, onArticle }: {
  project: LearningProjectSnapshot; article: LearningArticleSnapshot
  active?: boolean
  onUpdate: (project: LearningProjectSnapshot) => void; onComplete: () => void; onArticle: (id: string) => void
}): JSX.Element {
  const [selected, setSelected] = useState<ReaderSelection | null>(null)
  const [vocabularyOpen, setVocabularyOpen] = useState(false)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [activeToken, setActiveToken] = useState<string | null>(null)
  const root = useRef<HTMLDivElement>(null)
  const drawer = useRef<HTMLElement>(null)
  const drawerTrigger = useRef<HTMLButtonElement>(null)
  const drawerId = useId()
  const hintId = useId()
  const contextKey = JSON.stringify([project.projectId, project.binding.courseId, project.binding.rootRelPath, article.id])
  const currentContext = useRef(contextKey); currentContext.current = contextKey
  const currentSelection = useRef<string | null>(null); currentSelection.current = selected ? readerSelectionKey(selected.value) : null
  const mounted = useRef(false)
  const working = useRef(false)
  const pointer = useRef<{ x: number; y: number } | null>(null)
  const suppressClick = useRef(false)
  const readingPackId = project.purpose === 'english-reading' ? project.packId : undefined
  const saved = project.occurrences.filter(item => item.sourceRef.articleId === article.id)
  const savedWords = [...new Set(saved.map(item => item.wordId))].flatMap(id => { const word = project.words.find(item => item.id === id); return word ? [word] : [] })
  const matches = useMemo(() => new Map(article.paragraphs.map(paragraph => [paragraph.id, readerVocabularyMatches(paragraph.text, project.words)])), [article.paragraphs, project.words])
  const occurrence = selected ? readerSavedOccurrence(saved, selected.value) : undefined
  const selectedWord = occurrence ? project.words.find(word => word.id === occurrence.wordId) : selected ? learningWordForSurface(project.words, selected.value.surface) : undefined
  const priorExamples = selectedWord ? project.occurrences.filter(item => item.wordId === selectedWord.id && item.sourceRef.articleId !== article.id) : []
  const closeSelection = useCallback(() => setSelected(null), [])
  const progress = useReaderProgress(root, project, article, onUpdate, caught => setError(learningError(caught)))

  useEffect(() => {
    mounted.current = true; working.current = false
    setSelected(null); setNotice(null); setError(null); setPending(false); setActiveToken(null); setVocabularyOpen(false)
    return () => { mounted.current = false }
  }, [contextKey])

  useEffect(() => { if (!active) { setSelected(null); setVocabularyOpen(false) } }, [active])

  useEffect(() => {
    if (!vocabularyOpen) return
    const escape = (event: globalThis.KeyboardEvent): void => {
      if (event.key === 'Escape' && !event.defaultPrevented) { event.preventDefault(); setVocabularyOpen(false); drawerTrigger.current?.focus() }
    }
    document.addEventListener('keydown', escape)
    drawer.current?.querySelector<HTMLButtonElement>('[aria-label="단어장 닫기"]')?.focus()
    return () => document.removeEventListener('keydown', escape)
  }, [vocabularyOpen])

  const isCurrent = (): boolean => mounted.current && currentContext.current === contextKey
  const select = (value: ReaderWordSelection | null, anchor: ReaderSelectionAnchor): void => {
    if (!value) { closeSelection(); return }
    setSelected({ value, anchor }); setNotice(null); setError(null)
  }
  const saveWord = async (draft: ReaderDefinitionDraft): Promise<void> => {
    if (!selected || working.current || occurrence) return
    const value = selected.value
    const selectionKey = readerSelectionKey(value)
    working.current = true; setPending(true); setError(null)
    try {
      const next = await invoke('learning:saveWord', { binding: project.binding, ...value,
        ...(selectedWord ? { lemma: selectedWord.lemma, partOfSpeech: selectedWord.partOfSpeech } : {}), ...draft })
      notifyLearningChanged()
      if (!isCurrent()) return
      onUpdate(next)
      if (currentSelection.current === selectionKey) setNotice('단어와 이 문장을 함께 담았어요.')
    } catch (caught) { if (isCurrent() && currentSelection.current === selectionKey) setError(learningError(caught)); else if (isCurrent()) showToast(`“${value.surface}” 저장 실패: ${learningError(caught)}`, 'danger') }
    finally { if (isCurrent()) { working.current = false; setPending(false) } }
  }
  const explain = async (wordId: string): Promise<void> => {
    if (working.current) return
    const selectionKey = currentSelection.current
    working.current = true; setPending(true); setError(null)
    try {
      await startLearningRun({ binding: project.binding, kind: 'explain-word', ...(readingPackId ? { packId: readingPackId } : {}), articleIds: [article.id], wordIds: [wordId] })
      if (isCurrent() && currentSelection.current === selectionKey) setNotice('AI가 이 문장의 뜻과 표현을 정리하고 있어요.')
    } catch (caught) { if (isCurrent() && currentSelection.current === selectionKey) setError(learningError(caught)) }
    finally { if (isCurrent()) { working.current = false; setPending(false) } }
  }
  const complete = async (): Promise<void> => {
    if (working.current) return
    working.current = true; setPending(true); setError(null)
    try {
      await progress.flush()
      const next = await invoke('learning:completeArticle', { binding: project.binding, articleId: article.id })
      notifyLearningChanged()
      if (!isCurrent()) return
      onUpdate(next); onComplete()
      if (project.purpose === 'english-reading' && project.readingSetupConfirmed) await startLearningRun({ binding: project.binding, kind: 'find-articles', ...(readingPackId ? { packId: readingPackId } : {}), articleIds: [article.id] }).catch(caught => showToast(`읽은 기록은 저장됐어요. 다음 글을 찾지 못했습니다: ${learningError(caught)}`, 'danger'))
    } catch (caught) { if (isCurrent()) setError(learningError(caught)) }
    finally { if (isCurrent()) { working.current = false; setPending(false) } }
  }
  const tokenKeyboard = (event: KeyboardEvent<HTMLElement>, value: ReaderWordSelection | null): void => {
    if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); select(value, { element: event.currentTarget, keyboard: true }); return }
    if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return
    const tokens = Array.from(root.current?.querySelectorAll<HTMLElement>('[data-reader-token]') ?? [])
    const index = tokens.indexOf(event.currentTarget)
    const paragraph = event.currentTarget.dataset.wordParagraph
    const target = event.key === 'Home' ? tokens.find(token => token.dataset.wordParagraph === paragraph)
      : event.key === 'End' ? tokens.findLast(token => token.dataset.wordParagraph === paragraph)
        : tokens[index + (event.key === 'ArrowRight' ? 1 : -1)]
    event.preventDefault()
    if (target) { setActiveToken(target.dataset.readerToken ?? null); target.focus() }
  }
  let firstToken = true
  return <div className="learning-reader-shell">
    <div className="learning-reader-toolbar"><div className="learning-reader-progress" aria-label={`읽기 진행 ${Math.round(progress.fraction * 100)}%`}><span className="learning-reader-progress-track"><span style={{ width: `${Math.round(progress.fraction * 100)}%` }} /></span><span>{Math.round(progress.fraction * 100)}%</span><span className="learning-reader-duration">약 {article.estimatedMinutes}분</span></div><div><button type="button" className="learning-text-button learning-reader-original" onClick={() => createBrowserTab(article.sourceUrl)}>원문 <Icon name="link" /></button><button ref={drawerTrigger} type="button" className="learning-reader-vocabulary-toggle" aria-label="이 글의 단어장" aria-expanded={vocabularyOpen} aria-controls={drawerId} onClick={() => { setVocabularyOpen(open => !open); setSelected(null) }}><Icon name="fileText" /><span>이 글의 단어</span><strong>{savedWords.length}</strong></button></div></div>
    <div className="learning-reader-layout" data-vocabulary-open={vocabularyOpen || undefined}>
      <div className="learning-reader" ref={root} onScroll={progress.onScroll}
        onPointerDown={event => { if (event.button === 0) { pointer.current = { x: event.clientX, y: event.clientY }; suppressClick.current = false } }}
        onPointerUp={event => {
          if (event.button !== 0 || !pointer.current) return
          const moved = Math.hypot(event.clientX - pointer.current.x, event.clientY - pointer.current.y) > 4
          pointer.current = null
          const selection = window.getSelection()
          const value = root.current ? selectionInReader(article, root.current, selection) : null
          if (moved && value && selection?.rangeCount) {
            const range = selection.getRangeAt(0).cloneRange()
            const container = range.startContainer instanceof HTMLElement ? range.startContainer : range.startContainer.parentElement
            if (container) { suppressClick.current = true; select(value, { element: container, range, keyboard: false }) }
          } else if (moved) { suppressClick.current = true; closeSelection() }
        }}>
        <article className="learning-reader-paper"><div className="learning-reader-meta"><span>{article.siteName ?? new URL(article.sourceUrl).hostname}</span><span>{article.wordCount} words</span></div><h1>{article.title}</h1>{article.byline && <p className="learning-muted">{article.byline}</p>}
          <p className="learning-reader-hint" id={hintId}><span>단어를 누르면 뜻이 바로 나와요.</span> 표현은 드래그해서 찾아보세요.<span className="sr-only">본문에서는 좌우 화살표로 단어를 이동하고 Enter로 사전을 엽니다. Tab으로 본문을 나갑니다.</span></p>
          {article.paragraphs.map(paragraph => {
            const tokens: JSX.Element[] = []; let offset = 0
            for (const match of paragraph.text.matchAll(/[A-Za-z]+(?:['’\-][A-Za-z]+)*/g)) {
              const start = match.index; const end = start + match[0].length
              const token = `${paragraph.id}:${start}`
              const tabIndex = activeToken ? activeToken === token ? 0 : -1 : firstToken ? 0 : -1
              firstToken = false
              tokens.push(<span key={`text-${offset}`}>{paragraph.text.slice(offset, start)}</span>)
              const marked = saved.some(item => item.sourceRef.paragraphId === paragraph.id && (item.sourceRef.start ?? Infinity) < end && (item.sourceRef.end ?? -1) > start)
              const recurring = matches.get(paragraph.id)?.find(item => item.start < end && item.end > start)
              const selectedHere = selected?.value.sourceRef.paragraphId === paragraph.id && (selected.value.sourceRef.start ?? Infinity) < end && (selected.value.sourceRef.end ?? -1) > start
              const value = (): ReaderWordSelection | null => readerWordSelection(article, paragraph.id, start, end)
              tokens.push(<span key={`word-${start}`} className="learning-reader-word" data-reader-token={token} data-word-start={start} data-word-end={end} data-word-paragraph={paragraph.id} data-saved={marked || undefined} data-recurring={recurring ? true : undefined} data-selected={selectedHere || undefined} role="button" tabIndex={tabIndex} aria-label={`“${match[0]}” 뜻 보기`} aria-describedby={hintId} aria-haspopup="dialog" onFocus={() => setActiveToken(token)}
                onClick={event => { if (suppressClick.current) { suppressClick.current = false; return }; select(value(), { element: event.currentTarget, keyboard: false }) }}
                onKeyDown={event => tokenKeyboard(event, value())}>{match[0]}</span>)
              offset = end
            }
            tokens.push(<span key="last">{paragraph.text.slice(offset)}</span>)
            return <p key={paragraph.id} data-learning-paragraph={paragraph.id}>{tokens}</p>
          })}
          <footer className="learning-reader-footer"><p>이 글에서 {savedWords.length}개의 단어를 담았어요.</p><button className="button button--primary" type="button" disabled={pending} onClick={() => void complete()}>{pending ? '처리 중…' : project.purpose === 'english-reading' && project.readingSetupConfirmed ? '읽기 완료 · 다음 글 찾기' : '읽기 완료'} <Icon name="chevronRight" /></button>{!selected && error && <p className="learning-error" role="alert">{error}</p>}</footer>
        </article>
      </div>
      {vocabularyOpen && <><button type="button" className="learning-reader-drawer-backdrop" aria-label="단어장 바깥 닫기" tabIndex={-1} onClick={() => { setVocabularyOpen(false); drawerTrigger.current?.focus() }} /><aside className="learning-word-panel" id={drawerId} ref={drawer} aria-label="읽기 단어장"><header className="learning-word-panel-header"><div><p className="learning-eyebrow">MY WORDS</p><h2>이 글의 단어 <span>{savedWords.length}</span></h2></div><button type="button" className="bare-icon-button" aria-label="단어장 닫기" onClick={() => { setVocabularyOpen(false); drawerTrigger.current?.focus() }}><Icon name="x" /></button></header>
        <p className="learning-muted">읽으며 담은 단어와 문장을 다시 살펴보세요.</p>
        <div className="learning-word-mini-list">{savedWords.map(word => <div key={word.id}><strong>{word.surface}</strong><span>{word.meaning || '뜻을 아직 적지 않았어요'}</span><button className="learning-text-button" type="button" disabled={pending} onClick={() => void explain(word.id)}>AI 문맥 설명</button></div>)}{savedWords.length === 0 && <div className="learning-empty">아직 담은 단어가 없어요.<p>본문의 단어를 눌러 뜻을 확인하고 담아보세요.</p></div>}</div>
        {!selected && notice && <p className="learning-notice" role="status">{notice}</p>}
      </aside></>}
    </div>
    {selected && <ReaderDictionaryPopover key={`${contextKey}:${readerSelectionKey(selected.value)}`} selection={selected.value} anchor={selected.anchor} reader={root} word={selectedWord} occurrence={occurrence} pending={pending} notice={notice} error={error} onClose={closeSelection} onSave={draft => void saveWord(draft)} onExplain={occurrence ? () => void explain(occurrence.wordId) : undefined}
      priorExamples={priorExamples.length > 0 ? <details className="learning-prior-examples"><summary>이전에 만난 문장 {priorExamples.length}</summary>{priorExamples.slice(-3).map(item => <blockquote key={item.id}><p>{item.sentence}</p>{item.meaning && <small>{item.meaning}</small>}<LearningSources binding={project.binding} sources={[item.sourceRef]} onArticle={onArticle} /></blockquote>)}</details> : null} />}
  </div>
}
