import { useEffect, useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { createPortal } from 'react-dom'
import type { DictionaryEntry, DictionaryLookupResult, DictionarySource } from '../../../../shared/types/dictionary'
import type { LearningOccurrence, LearningWord } from '../../../../shared/types/learning'
import { Icon } from '../../app/icons'
import { createBrowserTab } from '../../app/tabCommands'
import { invoke } from '../../lib/ipc'
import type { ReaderWordSelection } from './readerSelection'

export interface ReaderDefinitionDraft {
  meaning: string
  lemma?: string
  partOfSpeech?: string
  pronunciation?: string
  dictionarySource?: DictionarySource
}
export interface ReaderSelectionAnchor {
  element: HTMLElement
  range?: Range
  keyboard: boolean
}

export function ReaderDictionaryPopover({ selection, anchor, reader, word, occurrence, pending, error, notice, priorExamples, onClose, onSave, onExplain }: {
  selection: ReaderWordSelection
  anchor: ReaderSelectionAnchor
  reader: RefObject<HTMLDivElement>
  word: LearningWord | undefined
  occurrence: LearningOccurrence | undefined
  pending: boolean
  error: string | null
  notice: string | null
  priorExamples: ReactNode
  onClose: () => void
  onSave: (draft: ReaderDefinitionDraft) => void
  onExplain: (() => void) | undefined
}): JSX.Element {
  const root = useRef<HTMLElement>(null)
  const closeButton = useRef<HTMLButtonElement>(null)
  const close = useRef(onClose); close.current = onClose
  const [lookup, setLookup] = useState<DictionaryLookupResult | null>(null)
  const [chosen, setChosen] = useState<{ entry: DictionaryEntry; meaning: string } | null>(null)
  const [meaning, setMeaning] = useState(occurrence?.meaning || word?.meaning || '')
  const [source, setSource] = useState<DictionarySource | undefined>(occurrence?.dictionarySource ?? word?.dictionarySource)
  const edited = useRef(false)
  const [position, setPosition] = useState({ left: 12, top: 12, maxHeight: 500 })
  const savedMeaning = occurrence?.meaning || word?.meaning

  useEffect(() => {
    let active = true
    void invoke('learning:lookupDictionary', { text: selection.surface }).then(result => {
      if (!active) return
      setLookup(result)
      const entry = result.entries[0]
      const sense = entry?.senses[0]
      if (entry && sense && !savedMeaning && !edited.current) { setChosen({ entry, meaning: sense.meaning }); setMeaning(sense.meaning); setSource(entry.source) }
    }).catch(() => { if (active) setLookup({ status: 'unavailable', entries: [] }) })
    return () => { active = false }
  }, [selection.surface])

  useLayoutEffect(() => {
    const update = (): void => {
      const element = root.current
      if (!element || !anchor.element.isConnected) { close.current(); return }
      const rect = anchor.range?.getBoundingClientRect?.() ?? anchor.element.getBoundingClientRect()
      const bounds = reader.current?.getBoundingClientRect()
      if (bounds && bounds.height > 0 && (rect.bottom <= bounds.top || rect.top >= bounds.bottom)) { close.current(); return }
      const viewport = window.visualViewport
      const width = viewport?.width ?? window.innerWidth
      const height = viewport?.height ?? window.innerHeight
      const margin = 12
      const availableBelow = height - rect.bottom - margin - 9
      const availableAbove = rect.top - margin - 9
      const above = availableBelow < Math.min(element.scrollHeight, 340) && availableAbove > availableBelow
      const maxHeight = Math.max(120, (above ? availableAbove : availableBelow))
      const actualHeight = Math.min(element.scrollHeight, maxHeight)
      const left = Math.max(margin, Math.min(width - element.offsetWidth - margin, rect.left + rect.width / 2 - element.offsetWidth / 2))
      const top = Math.max(margin, Math.min(height - actualHeight - margin, above ? rect.top - actualHeight - 9 : rect.bottom + 9))
      setPosition(previous => previous.left === left && previous.top === top && previous.maxHeight === maxHeight ? previous : { left, top, maxHeight })
    }
    update()
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(update)
    if (root.current) observer?.observe(root.current)
    if (reader.current) observer?.observe(reader.current)
    window.addEventListener('resize', update)
    window.addEventListener('scroll', update, true)
    return () => { observer?.disconnect(); window.removeEventListener('resize', update); window.removeEventListener('scroll', update, true) }
  }, [anchor, reader, lookup])

  useEffect(() => {
    if (anchor.keyboard) closeButton.current?.focus()
    const outside = (event: PointerEvent): void => {
      if (event.target instanceof Node && !root.current?.contains(event.target) && !anchor.element.contains(event.target)) close.current()
    }
    const keyboard = (event: KeyboardEvent): void => {
      if (event.key !== 'Escape' || event.defaultPrevented) return
      event.preventDefault(); event.stopPropagation()
      close.current()
      if (anchor.keyboard && anchor.element.isConnected) anchor.element.focus()
    }
    document.addEventListener('pointerdown', outside, true)
    document.addEventListener('keydown', keyboard, true)
    return () => { document.removeEventListener('pointerdown', outside, true); document.removeEventListener('keydown', keyboard, true) }
  }, [anchor])

  const selectSense = (entry: DictionaryEntry, selectedMeaning: string): void => {
    edited.current = true; setChosen({ entry, meaning: selectedMeaning }); setMeaning(selectedMeaning); setSource(entry.source)
  }
  const openSource = (url: string): void => { onClose(); createBrowserTab(url) }
  const save = (): void => {
    onSave({ meaning: meaning.trim(), ...(chosen ? { lemma: chosen.entry.headword, partOfSpeech: chosen.entry.partOfSpeech, pronunciation: chosen.entry.pronunciation } : {}), ...(source && meaning.trim() ? { dictionarySource: source } : {}) })
  }
  return createPortal(<section ref={root} className="learning-dictionary-popover" role="dialog" aria-label={`${selection.surface} 사전`}
    style={{ left: position.left, top: position.top, maxHeight: position.maxHeight }}>
    <header className="learning-dictionary-header"><div><span className="learning-dictionary-label">바로 찾는 영어사전</span><h2>{selection.surface}</h2></div><button ref={closeButton} type="button" className="bare-icon-button" aria-label="사전 닫기" onClick={() => { onClose(); if (anchor.keyboard) anchor.element.focus() }}><Icon name="x" /></button></header>
    <div className="learning-dictionary-body">
      {savedMeaning && <div className="learning-dictionary-saved-meaning"><span>{(occurrence?.dictionarySource ?? word?.dictionarySource)?.modified ? '직접 정리한 뜻' : occurrence ? '이 문맥에 저장한 뜻' : '내 단어장에 있는 뜻'}</span><p>{savedMeaning}</p>{(occurrence?.dictionarySource ?? word?.dictionarySource) && <button type="button" className="learning-dictionary-source" onClick={() => openSource((occurrence?.dictionarySource ?? word!.dictionarySource)!.url)}>Wiktionary 출처 <Icon name="link" /></button>}</div>}
      {!lookup ? <p className="learning-dictionary-status" role="status">사전 찾는 중…</p> : lookup.status === 'found' ? <div className="learning-dictionary-entries">
        {lookup.entries.map(entry => <section key={entry.id} className="learning-dictionary-entry"><div className="learning-dictionary-entry-heading"><strong>{entry.headword}</strong>{entry.partOfSpeech && <span>{entry.partOfSpeech}</span>}{entry.pronunciation && <small>{entry.pronunciation}</small>}</div>
          <div className="learning-dictionary-senses" aria-label={`${entry.headword} 사전 뜻`}>{entry.senses.map((sense, index) => <button key={`${index}-${sense.meaning}`} type="button" aria-pressed={chosen?.entry.id === entry.id && chosen.meaning === sense.meaning} onClick={() => selectSense(entry, sense.meaning)}><span className="learning-dictionary-sense-number">{index + 1}</span><span><strong>{sense.meaning}</strong>{sense.definition && <small>{sense.definition}</small>}</span></button>)}</div>
          <button type="button" className="learning-dictionary-source" onClick={() => openSource(entry.source.url)}>Wiktionary · 오프라인 사전 <Icon name="link" /></button>
        </section>)}
      </div> : <div className="learning-dictionary-empty"><strong>{lookup.status === 'unavailable' ? '사전을 열지 못했어요' : '사전에 없는 표현이에요'}</strong><p>{lookup.status === 'unavailable' ? '뜻을 직접 적거나 외부 사전에서 찾아보세요.' : '긴 표현이나 전문 용어는 외부 사전에서 더 찾아볼 수 있어요.'}</p></div>}
      {!occurrence && <details className="learning-dictionary-note"><summary>뜻 직접 적기</summary><label className="learning-field"><span>저장할 뜻</span><input className="text-field" aria-label="저장할 뜻" value={meaning} placeholder="뜻 없이 단어만 담아도 괜찮아요" onChange={event => { edited.current = true; setChosen(current => current ? { ...current, meaning: event.target.value } : null); setMeaning(event.target.value); setSource(current => current ? { ...current, modified: true } : undefined) }} disabled={pending} /></label></details>}
      <details className="learning-dictionary-context"><summary>이 문장의 쓰임</summary><blockquote>{selection.sentence}</blockquote></details>
      {priorExamples}
      <details className="learning-dictionary-credits"><summary>사전 출처 · 라이선스</summary><p>Wiktionary 기여자 · Kaikki/Wiktextract · Daniel Gregorini/koreader-dicts v1.2.0. 반달에서 표시 형식과 검색 색인을 가공했습니다.</p><p><button type="button" onClick={() => openSource('https://creativecommons.org/licenses/by-sa/4.0/')}>CC BY-SA 4.0</button>{' · '}<button type="button" onClick={() => openSource('https://github.com/DanielGregorini/koreader-dicts/releases/tag/v1.2.0')}>사전 데이터</button>{' · '}<button type="button" onClick={() => openSource('https://kaikki.org/')}>Kaikki</button></p><p>활용형: WordNet 3.0 © 2006 Princeton University. <button type="button" onClick={() => openSource('https://wordnet.princeton.edu/license-and-commercial-use')}>이용 조건</button></p></details>
      {notice && <p className="learning-notice" role="status">{notice}</p>}{error && <p className="learning-error" role="alert">{error}</p>}
    </div>
    <footer className="learning-dictionary-footer"><button type="button" className="button button--primary learning-dictionary-save" disabled={pending || Boolean(occurrence)} onClick={save}>{occurrence ? '저장됨' : pending ? '담는 중…' : word ? '이 문맥도 담기' : '단어장에 담기'}{!occurrence && <Icon name="plus" />}</button>
      <div className="learning-dictionary-secondary"><button className="learning-text-button" type="button" disabled={pending || !onExplain} title={onExplain ? 'AI로 이 문장의 쓰임을 자세히 설명합니다' : '단어장에 담은 뒤 문맥 설명을 요청할 수 있어요'} onClick={onExplain}>AI 문맥 설명</button><button className="learning-text-button" type="button" onClick={() => openSource(`https://en.dict.naver.com/#/search?query=${encodeURIComponent(selection.surface)}`)}>네이버 영어사전에서 찾기 <Icon name="link" /></button></div>
    </footer>
  </section>, document.body)
}
