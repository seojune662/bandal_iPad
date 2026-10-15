// Real dialogs, playback, source navigation and drawing toolbar. The remaining
// static specimens exercise feature CSS with long labels, not business logic.
import { useEffect, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { CourseFormDialog } from '../../../upstream/src/renderer/src/features/courses/CourseDialogs'
import { FeedbackDialog } from '../../../upstream/src/renderer/src/features/help/FeedbackDialog'
import { RecordingPlayer } from '../../../upstream/src/renderer/src/features/recordings/RecordingPlayer'
import { LearningSources } from '../../../upstream/src/renderer/src/features/learning/LearningSources'
import { CanvasToolRail } from '../../../upstream/src/renderer/src/features/canvas/CanvasToolRail'
import { setIpcAdapter, type IpcAdapter } from '../../../upstream/src/renderer/src/lib/ipc'
import { setLocale } from '../../../upstream/src/renderer/src/i18n'
import '../../../upstream/src/renderer/src/styles/tokens.css'
import '../../../upstream/src/renderer/src/styles/base.css'
import '../../../upstream/src/renderer/src/app/app-shell.css'
import '../../../upstream/src/renderer/src/app/quick-search.css'
import '../../../upstream/src/renderer/src/features/courses/courses.css'
import '../../../upstream/src/renderer/src/features/recordings/recording.css'
import '../../../upstream/src/renderer/src/features/learning/learning.css'
import '../../../upstream/src/renderer/src/features/canvas/canvas.css'
import '../../../upstream/src/renderer/src/features/board/boardPopovers.css'
import '../../../upstream/src/renderer/src/features/studyMarket/studyMarket.css'
import '../../../upstream/src/renderer/src/features/notes/note-tab.css'
import '../../../upstream/src/renderer/src/features/links/graph/linkGraph.css'
import '../../../upstream/src/renderer/src/features/ink/ink.css'
import '../../../upstream/src/renderer/src/features/browser/browser.css'
import '../../../upstream/src/renderer/src/features/browser/browserProfiles.css'
import '../../browser/browser.css'
import '../layout/layout.css'
import '../touch/touch.css'
import '../input/input.css'

const trace = { events: [] as string[], show: (_view: string) => {}, settings: (_open: boolean) => {} }
const invoke = async (channel: string) => {
  trace.events.push(channel)
  if (channel === 'feedback:send') return { ok: true }
  throw new Error(`Unexpected surfaces fixture IPC ${channel}`)
}
Object.assign(window, { surfacesUI: trace, bandal: { platform: 'ipad', invoke, on: () => () => {} } })
setIpcAdapter({ invoke, on: () => () => {} } as IpcAdapter)
setLocale('ko-KR')
// Comparison mode omits only the new shared UI layer; fixtures still use the
// actual upstream reset and existing iPad adapters in both captures.
if (!new URLSearchParams(location.search).has('before')) await import('./styles.css')
const longTitle = '긴 한국어 과목 이름과 여러 자료를 함께 확인하는 학습 공간'
function BrowserMenuSpecimen(): JSX.Element {
  const [presentation, setPresentation] = useState('desktop')
  return <section className="browser-panel">
    <header className="browser-toolbar"><nav className="browser-toolbar__nav"><button className="browser-nav-button" aria-label="뒤로">←</button><button className="browser-nav-button" aria-label="새로고침">↻</button></nav><div className="browser-address" data-display-url><div className="browser-address__field"><input aria-label="웹 주소" defaultValue="https://example.com/learning" /><span className="browser-address__display"><strong>example.com</strong>/learning</span></div></div><button className="browser-nav-button browser-toolbar__more" aria-label="브라우저 메뉴">⋯</button></header>
    <div className="browser-toolbar-menu" data-compact style={{ top: 68, right: 12 }} aria-label="브라우저 메뉴">
      <div className="browser-toolbar-menu__title">브라우저</div>
      <section className="ipad-browser-menu-section"><h3>보기</h3><fieldset className="ipad-browser-presentation"><legend>페이지 표시</legend>{([['mobile', '모바일'], ['desktop', '데스크톱']] as const).map(([value, label]) => <button key={value} aria-pressed={presentation === value} onClick={() => setPresentation(value)}>{label}</button>)}<small>기기에 맞는 페이지 표시 방식을 선택하세요.</small></fieldset><div className="ipad-browser-zoom"><button aria-label="축소">−</button><button>100<span>%</span></button><button aria-label="확대">+</button></div></section>
      <section className="ipad-browser-menu-section"><h3>페이지 작업</h3>{['페이지에서 찾기', '읽기 목록에 저장', 'PDF로 저장'].map(label => <button key={label} aria-label={label}><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M4 4h12v12H4zM7 8h6M7 12h6" fill="none" stroke="currentColor" /></svg></button>)}</section>
      <section className="ipad-browser-menu-section"><h3>최근 방문</h3><div className="ipad-browser-history"><button><strong>학습 자료 모음과 긴 페이지 제목</strong><span>example.com/learning/resources</span></button></div></section>
    </div>
  </section>
}
function Fixture(): JSX.Element {
  const [view, setView] = useState('learning'), [settings, setSettings] = useState(false)
  const audio = useRef<HTMLAudioElement>(null)
  useEffect(() => { trace.show = setView; trace.settings = setSettings }, [])
  return <div className="surfaces-fixture ipad-shell">
    <main>
      {view === 'course' && <CourseFormDialog open mode="create" onClose={() => setView('learning')} onSubmit={async (name, color) => { trace.events.push(`course:${name}:${color}`) }} />}
      {view === 'feedback' && <FeedbackDialog initiallyOpen />}
      {view === 'learning' && <section className="learning-panel"><div className="learning-content-scroll"><nav className="learning-navigation">{['학습 홈', '학습 자료', '오늘의 복습', '저장한 단어'].map((label, i) => <button key={label} aria-current={i === 0 ? 'page' : undefined} onClick={() => trace.events.push(label)}>{label}</button>)}</nav><div className="learning-page"><h1>나의 학습</h1><p className="learning-lead">읽고, 풀고, 기억하는 학습을 여기서 이어가세요.</p><div className="learning-stats">{['읽은 자료', '저장한 단어', '오늘 복습', '학습 시간'].map(label => <button key={label}><strong>12</strong><span>{label}</span></button>)}</div><div className="learning-project-grid">{[0, 1].map(i => <button className="learning-project-card" key={i}><strong>{longTitle}</strong><span>최근 학습으로 돌아가기</span></button>)}</div><LearningSources binding={{ courseId: 'course', rootRelPath: '' }} sources={[{ kind: 'article', articleId: 'article', title: '원문 예문으로 돌아가기', quote: 'Learn with the original context.' }]} onArticle={id => trace.events.push(`source:${id}`)} /><div className="learning-form-row"><label className="learning-field">자료 선택<select><option>{longTitle}</option></select></label><label className="learning-field">학습 목표<textarea defaultValue="긴 문장을 편하게 읽고 내용을 이해하기" /></label></div></div></div></section>}
      {view === 'recording' && <section className="recording"><header className="recording__header"><strong className="recording__heading">강의 녹음과 받아쓰기</strong><div className="recording__header-actions"><button className="recording__settings-button">설정</button></div></header><div className="recording__main"><div className="recording__console"><h1>{longTitle}</h1><RecordingPlayer audioRef={audio} src="data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQAAAAA=" duration={125} defaultRate={1} onError={() => {}} /></div></div></section>}
      {view === 'canvas' && <section className="canvas-tab"><header className="canvas-tab__header"><button className="canvas-tab__title">생각 정리</button></header><CanvasToolRail canUndo canRedo enabled background="grid" surface="light" backgroundBusy={false} pageBusy={false} exportingPdf={false} onUndo={() => trace.events.push('undo')} onRedo={() => trace.events.push('redo')} onInsertImages={() => trace.events.push('image')} onBackgroundChange={() => {}} onSurfaceToggle={() => {}} onAddPage={() => trace.events.push('page')} onExportPdf={() => trace.events.push('export')} /><div className="canvas-tab__viewport"><div style={{ height: 1000 }}>종이</div></div></section>}
      {view === 'browser' && <BrowserMenuSpecimen />}
      {view === 'browserprofiles' && <section className="browser-panel"><div className="browser-find"><input className="browser-find__input" aria-label="페이지에서 찾기" placeholder="페이지에서 찾기" /><span className="browser-find__count">1 / 3</span><button className="browser-find__step" aria-label="다음 결과">↓</button></div><section className="browser-profile-manager" style={{ margin: 16 }}><h2>브라우저 프로필</h2><form className="browser-profile-manager__form"><div className="browser-profile-manager__fields"><label className="browser-profile-manager__name-field">프로필 이름<input defaultValue="학습용" /></label><label>아이콘<select aria-label="프로필 아이콘"><option>책</option><option>별</option></select></label></div></form><div className="browser-profile-select" style={{ marginTop: 16 }}><label>가져올 프로필<select aria-label="가져올 프로필"><option>기본 프로필</option></select></label></div></section></section>}
      {view === 'menu' && <div className="context-menu" role="menu" style={{ left: 12, top: 12 }}><p className="context-menu__label">{longTitle}</p><button role="menuitem">이름 변경</button><div className="context-menu__color-palette">{['gold', 'green', 'blue', 'pink', 'violet', 'orange'].map(color => <button key={color} className="context-menu__color-swatch" aria-label={color} data-selected={color === 'blue'}><span style={{ background: 'var(--course-blue)' }} /></button>)}</div><button role="menuitem" className="context-menu__danger">삭제</button></div>}
      {view === 'toast' && <div className="toast-host"><div className="toast"><span className="toast__message">자료를 가져오지 못했습니다. 네트워크 연결을 확인한 다음 다시 시도해 주세요. {longTitle}</span><button className="toast__action" onClick={() => trace.events.push('retry')}>다시 시도</button><button className="toast__dismiss" aria-label="알림 닫기">×</button></div></div>}
      {view === 'market' && <section className="study-market"><div className="study-market__content"><header className="study-market__header"><h1>학습 자료</h1><button className="button button--primary">자료 올리기</button></header><div className="study-market__toolbar"><label className="study-market__search"><input aria-label="자료 검색" placeholder="필요한 자료 검색" /><button aria-label="검색 지우기">×</button></label><select aria-label="정렬"><option>최신순</option></select></div><button className="study-market__listing"><span className="study-market__listing-image">PDF</span><span className="study-market__listing-copy"><strong>{longTitle}</strong><span className="study-market__listing-description">한 학기 학습 내용을 차근차근 정리한 자료</span></span><span className="study-market__listing-price">12,000원</span></button></div></section>}
      {view === 'board' && <div className="board-editor" style={{ top: 24, left: 12 }}><form><header className="board-editor__header"><h3>과제 편집</h3><button className="bare-icon-button">×</button></header><label className="board-field">과제 이름<input defaultValue={longTitle} /></label><footer className="board-editor__footer"><button className="board-button">취소</button><button className="button button--primary">저장</button></footer></form></div>}
      {view === 'graph' && <div className="link-graph-overlay"><div className="link-graph-overlay__surface"><header className="link-graph-overlay__head"><strong>자료 연결</strong><div className="link-graph-overlay__actions"><button className="bare-icon-button">×</button></div></header><svg className="link-graph" /></div></div>}
      {view === 'documents' && <><div className="note-tab"><div className="milkdown"><div className="editor" contentEditable suppressContentEditableWarning><p>본문의 글자 크기와 행간은 문서 설정을 따릅니다.</p></div></div></div><div className="pdf-tab"><span className="document-ink" style={{ color: 'var(--drawing-color-ink)' }}>문서 잉크</span></div></>}
    </main>
    {settings && <section className="shell-settings-overlay" data-open="true" style={{ position: 'fixed', inset: 0, zIndex: 240, background: 'var(--bg-overlay)' }}><h1>설정</h1></section>}
  </div>
}
const style = document.createElement('style')
style.textContent = '.surfaces-fixture{height:100%;overflow:hidden}.surfaces-fixture>main{height:100%;min-width:0;overflow:hidden}.surfaces-fixture .learning-sources{margin-top:16px}'
document.head.append(style)
createRoot(document.getElementById('root')!).render(<Fixture />)
