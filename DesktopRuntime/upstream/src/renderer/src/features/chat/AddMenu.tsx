import { prepareQuickAction } from './quickActions'
import { showToast } from '../../app/toast'
import { useCallback, useEffect, useRef, useState } from 'react'
import type { AgentProvider } from '../../../../shared/types/agent-events'
import { CREATION_KINDS, CREATION_LABELS, type ChatSkill } from '../../../../shared/types/chatCapabilities'
import type { MaterialSearchHit } from '../../../../shared/types/materials'
import { invoke } from '../../lib/ipc'
import { Icon } from '../../app/icons'
import { ComposerPopover } from './ComposerPopover'
import { updateComposerDraft, useComposerDraft } from './composerDraftStore'
import { mentionHitsFromTree } from './Composer'

export function AddMenu({ courseId, conversationId, provider, disabled, screenAvailable }: {
  courseId: string; conversationId: string; provider: AgentProvider; disabled: boolean; screenAvailable: boolean
}): JSX.Element {
  const [open, setOpen] = useState(false), [section, setSection] = useState<'main' | 'files' | 'skills'>('main')
  const [skills, setSkills] = useState<ChatSkill[]>([]), [files, setFiles] = useState<MaterialSearchHit[]>([])
  const [query, setQuery] = useState(''), [loading, setLoading] = useState(false), [error, setError] = useState<string | null>(null)
  const anchor = useRef<HTMLButtonElement>(null)
  const draft = useComposerDraft(conversationId)
  const close = useCallback(() => setOpen(false), [])
  const finish = (): void => {
    close()
    requestAnimationFrame(() => anchor.current?.closest('.chat-composer')?.querySelector('textarea')?.focus())
  }
  useEffect(() => {
    if (!open) return
    let live = true
    setLoading(true); setError(null); setSkills([])
    void Promise.all([invoke('agent:skills', { provider, courseId }), invoke('materials:tree', { courseId })]).then(([nextSkills, tree]) => {
      if (live) { setSkills(nextSkills); setFiles(mentionHitsFromTree(tree)) }
    }).catch(() => { if (live) setError('목록을 불러오지 못했어요. 메뉴를 다시 열어 주세요.') }).finally(() => { if (live) setLoading(false) })
    return () => { live = false }
  }, [open, provider, courseId])
  const addFile = (file: { name: string; path?: string; relPath?: string }): void => {
    if (draft.files.length >= 20) { setError('파일은 한 번에 20개까지 첨부할 수 있어요.'); return }
    updateComposerDraft(conversationId, (current) => ({ files: [...current.files.filter((item) => (item.relPath ?? item.path) !== (file.relPath ?? file.path)), file].slice(0, 20) }))
  }
  const pickFiles = async (): Promise<void> => {
    try {
      const { paths } = await invoke('chat:pickAttachments', {})
      for (const path of paths) addFile({ path, name: path.split(/[\\/]/).pop() ?? path })
      finish()
    } catch { setError('파일 선택을 열지 못했어요. 다시 시도해 주세요.') }
  }
  return <>
    <button ref={anchor} className="chat-add-trigger" type="button" aria-label="추가" title="사진, 파일, 스킬 추가" aria-haspopup="dialog" aria-expanded={open} disabled={disabled} onClick={() => { setSection('main'); setQuery(''); setOpen(!open) }}>+</button>
    {open && <ComposerPopover anchor={anchor} label="대화에 추가" onClose={close}>
      <div className="chat-menu-heading">{section !== 'main' && <button type="button" aria-label="추가 메뉴로 돌아가기" onClick={() => { setSection('main'); setQuery('') }}>‹</button>}{section === 'main' ? '추가' : section === 'files' ? '과목 자료' : '설치된 스킬'}</div>
      {error && <p role="alert" className="chat-menu-error">{error}</p>}
      {section === 'main' ? <>
        <button className="chat-add-item" type="button" onClick={() => void pickFiles()}><span aria-hidden="true"><Icon name="plus" /></span><span>사진 및 파일<small>기기에서 선택</small></span></button>
        <button className="chat-add-item" type="button" onClick={() => setSection('files')}><span aria-hidden="true"><Icon name="folder" /></span><span>과목 자료<small>현재 과목의 파일 연결</small></span></button>
        <button className="chat-add-item" type="button" onClick={() => { updateComposerDraft(conversationId, { browser: !draft.browser }); finish() }}><span aria-hidden="true"><Icon name="link" /></span><span>현재 브라우저 페이지</span></button>
        <button className="chat-add-item" type="button" disabled={!screenAvailable} onClick={() => { close(); void prepareQuickAction('screen', conversationId).catch(error => showToast(error instanceof Error ? error.message : String(error), 'danger')) }}><span aria-hidden="true"><Icon name="layoutRight" /></span><span>현재 화면<small>{screenAvailable ? '미리 확인한 뒤 전송' : '데스크톱 앱에서 사용'}</small></span></button>
        <button className="chat-add-item" type="button" disabled={!screenAvailable} onClick={() => { close(); void prepareQuickAction('region', conversationId).catch(error => showToast(error instanceof Error ? error.message : String(error), 'danger')) }}><span aria-hidden="true">⌗</span><span>영역 선택해서 질문</span></button>
        <div className="chat-menu-heading">만들기</div>
        {CREATION_KINDS.map((kind) => {
          const skill = skills.find((item) => item.creationKinds.includes(kind))
          return <button className="chat-add-item" key={kind} type="button" disabled={loading || !skill} onClick={() => {
            if (!skill) return
            updateComposerDraft(conversationId, { creation: kind, skills: [skill] }); finish()
          }}><span aria-hidden="true"><Icon name="file" /></span><span>{CREATION_LABELS[kind]} 만들기<small>{loading ? '연결 확인 중…' : skill ? skill.name : '해당 생성 스킬 연결 필요'}</small></span></button>
        })}
        <button className="chat-add-item" type="button" onClick={() => setSection('skills')}><span aria-hidden="true"><Icon name="puzzle" /></span><span>스킬 선택<small>{skills.length}개 연결됨</small></span></button>
        <p className="chat-menu-note">현재 AI 계정에 설치된 스킬을 사용해요. 새로 설치했다면 메뉴를 다시 열어 주세요. 연결 설정은 설정 → AI에서 관리할 수 있어요.</p>
      </> : <>
        <input className="chat-menu-search" aria-label={section === 'files' ? '과목 자료 검색' : '스킬 검색'} placeholder="검색…" value={query} onChange={(event) => setQuery(event.target.value)} />
        {loading && <p role="status" className="chat-menu-note">불러오는 중…</p>}
        {section === 'files' ? files.filter((file) => `${file.name} ${file.relPath}`.toLowerCase().includes(query.toLowerCase())).slice(0, 60).map((file) => <button className="chat-add-item" key={file.relPath} type="button" onClick={() => { addFile({ name: file.name, relPath: file.relPath }); finish() }}><span aria-hidden="true"><Icon name="folder" /></span><span>{file.name}<small>{file.relPath}</small></span></button>) : skills.filter((skill) => `${skill.name} ${skill.description}`.toLowerCase().includes(query.toLowerCase())).map((skill) => <button className="chat-add-item" key={skill.id} type="button" aria-pressed={draft.skills.some((item) => item.id === skill.id)} onClick={() => {
          updateComposerDraft(conversationId, (current) => ({ skills: current.skills.some((item) => item.id === skill.id) ? current.skills.filter((item) => item.id !== skill.id) : [...current.skills, skill], creation: null })); finish()
        }}><span aria-hidden="true"><Icon name="puzzle" /></span><span>{skill.name}<small>{skill.description}</small></span></button>)}
        {!loading && (section === 'files' ? files : skills).length === 0 && <p className="chat-menu-note">연결된 {section === 'files' ? '자료가' : '스킬이'} 없어요.</p>}
      </>}
    </ComposerPopover>}
  </>
}
