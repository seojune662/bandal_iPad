import { useEffect, useRef, useState } from 'react'
import { Icon } from '../../app/icons'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { useUiStore } from '../../stores/uiStore'
import { NewLearningDialog } from './NewLearningDialog'
import { learningDisplayName } from './learningPresentation'
import { useCoursesStore } from '../../stores/coursesStore'
import { LearningProjectGroups, useLearningProjects } from './LearningProjects'
import './learning.css'

/** Mounted once by the shell, so search and scroll survive rail switches. */
export function LearningSpacesPanel({ hidden }: { hidden: boolean }): JSX.Element {
  const { projects, loading, error, reload } = useLearningProjects()
  const courses = useCoursesStore(state => state.courses)
  const [query, setQuery] = useState('')
  const [creating, setCreating] = useState(false)
  const search = useRef<HTMLInputElement>(null)
  const home = useWorkspaceStore(state => state.surface === 'learning-home')
  const settingsOpen = useUiStore(state => state.isSettingsOpen)
  const open = useUiStore(state => state.leftRailOpen && state.courseRailOpen)
  useEffect(() => { if (!home && !hidden && open && !settingsOpen && !search.current?.closest('[inert], [hidden]')) search.current?.focus({ preventScroll: true }) }, [home, hidden, open, settingsOpen])
  const filtered = projects.filter(project => `${learningDisplayName(project, courses)} ${project.topic}`.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()))
  return <aside id="learning-spaces-panel" className="app-rail app-rail--left course-sidebar learning-spaces-panel" aria-label="학습 공간 목록" hidden={hidden}>
    <header className="learning-spaces-header"><div><h2>학습 공간</h2></div><button className="bare-icon-button" type="button" aria-label="학습 공간 새로고침" onClick={() => void reload()}><Icon name="refresh" /></button></header>
    <label className="learning-spaces-search"><Icon name="search" /><input ref={search} className="text-field" type="search" aria-label="학습 공간 검색" placeholder="공간 검색" value={query} onChange={event => setQuery(event.target.value)} /></label>
    <button className="button button--primary learning-spaces-create" type="button" onClick={() => setCreating(true)}><Icon name="plus" /> 새 학습</button>
    <div className="learning-spaces-scroll">{loading && <p className="learning-muted" role="status">학습 공간 불러오는 중…</p>}{error && <p className="learning-error" role="alert">{error} <button className="learning-text-button" type="button" onClick={() => void reload()}>다시 불러오기</button></p>}<LearningProjectGroups projects={filtered} compact />{query && !filtered.length && <p className="learning-muted">검색한 공간이 없어요.</p>}</div>
    {creating && <NewLearningDialog onClose={() => setCreating(false)} />}
  </aside>
}
