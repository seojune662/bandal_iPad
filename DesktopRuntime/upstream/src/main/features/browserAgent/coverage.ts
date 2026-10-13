/**
 * What a person does in a browser — and whether the agent can do it.
 *
 * The app side already has this (`agentTools/coverage.ts`), and it exists
 * because 학기 그룹 shipped with a repo, IPC and a sidebar UI, and the agent
 * had no tool for it for eleven releases. Nobody noticed, because there was no
 * list to be missing from.
 *
 * The browser side was in exactly that state. `guestActions` could go back,
 * reload, find, copy and zoom; the agent could do none of them. It could not
 * scroll AT ALL — so a page longer than the snapshot budget simply had no
 * below-the-fold, and there was no way to learn that.
 *
 * Unlike the app side there is no machine-readable capability list to derive
 * from, so this one is written by hand. That is fine: the value is not the
 * list, it is that a capability nobody decided about fails a test instead of
 * being discovered by a student a year later.
 */

/** Something a person does to a web page. */
export interface BrowserCapability {
  /** Stable key, used by the tests and the decision map. */
  id: string
  /** What the person is doing, in their words. */
  what: string
}

export const BROWSER_CAPABILITIES: readonly BrowserCapability[] = [
  { id: 'read', what: '페이지 내용을 읽는다' },
  { id: 'inspect-controls', what: '누를 수 있는 것들을 살펴본다' },
  { id: 'list-tabs', what: '열어 둔 탭을 본다' },
  { id: 'open', what: '주소를 연다' },
  { id: 'scroll', what: '접힌 아래를 본다' },
  { id: 'click', what: '누른다' },
  { id: 'type', what: '입력칸에 쓴다' },
  { id: 'press-key', what: 'Enter·Tab·Esc·방향키를 누른다' },
  { id: 'select-option', what: '드롭다운에서 고른다' },
  { id: 'hover', what: '마우스를 올린다' },
  { id: 'back', what: '뒤로 간다' },
  { id: 'forward', what: '앞으로 간다' },
  { id: 'reload', what: '새로고침한다' },
  { id: 'stop-loading', what: '로딩을 멈춘다' },
  { id: 'focus-tab', what: '다른 탭으로 옮긴다' },
  { id: 'close-tab', what: '탭을 닫는다' },
  { id: 'find-in-page', what: '페이지에서 찾는다' },
  { id: 'submit', what: '제출한다' },
  { id: 'fill-saved-login', what: '저장된 로그인을 채운다' },
  { id: 'attach-file', what: '파일을 첨부한다' },
  { id: 'download', what: '파일을 받는다' },
  { id: 'hand-over', what: '사람에게 넘긴다' },
  { id: 'screenshot', what: '화면을 이미지로 본다' },
  { id: 'print', what: '인쇄한다' },
  { id: 'zoom', what: '확대·축소한다' },
  { id: 'copy', what: '선택한 것을 복사한다' },
  { id: 'devtools', what: '개발자 도구를 연다' },
  { id: 'dismiss-dialog', what: '페이지가 띄운 알림 창을 닫는다' }
]

/** Capability → the agent tool that covers it. */
export const AGENT_BROWSER_TOOLS: Readonly<Record<string, string>> = {
  read: 'browser_read',
  'inspect-controls': 'browser_snapshot',
  'list-tabs': 'browser_tabs',
  open: 'browser_open',
  scroll: 'browser_scroll',
  click: 'browser_click',
  type: 'browser_type',
  'press-key': 'browser_key',
  'select-option': 'browser_select',
  hover: 'browser_hover',
  back: 'browser_back',
  forward: 'browser_forward',
  reload: 'browser_reload',
  'stop-loading': 'browser_stop',
  'focus-tab': 'browser_focus_tab',
  'close-tab': 'browser_close_tab',
  'find-in-page': 'browser_find',
  submit: 'browser_submit',
  'fill-saved-login': 'browser_use_saved_login',
  'attach-file': 'browser_attach_file',
  download: 'browser_download',
  'hand-over': 'browser_handoff'
}

/**
 * Capabilities the agent deliberately does not get, and why.
 *
 * A reason is required, and "we did not get to it" is not one — that is the
 * state this file exists to make visible.
 */
export const NOT_FOR_AGENT_BROWSER: Readonly<Record<string, string>> = {
  screenshot:
    '페이지를 이미지로 보는 건 다른 구조다. 한 장이 수천 토큰이고, 매 스냅샷마다 붙으면 대화 하나가 그것만으로 찬다. 지금 표현은 ref 색인 아웃라인이고, 표나 시간표가 텍스트로 안 잡히면 그건 수집기를 고칠 문제이지 그림을 덧붙일 문제가 아니다.',
  print:
    '인쇄는 OS 인쇄 패널이 뜨는 일이다. 사람이 서 있어야 하고, ⌘P 로 학생이 직접 한다.',
  zoom: '배율은 학생의 눈에 맞추는 것이다. 에이전트가 정할 근거가 없다.',
  copy: '클립보드는 학생의 것이다. 에이전트는 읽은 내용을 그냥 답에 담으면 된다.',
  devtools:
    '사람이 보는 도구다. 게다가 DevTools 가 붙어 있으면 CDP 를 양보하도록 돼 있어(cdp.ts) 에이전트가 스스로 열면 자기 발을 밟는다.',
  'dismiss-dialog':
    '페이지가 띄운 alert/confirm 을 에이전트가 대신 눌러 주면, 그 창이 무엇을 물었는지 아무도 모르는 채로 답이 나간다. 대신 페이지 스크립트에 타임아웃을 걸어 매달리지 않게 하고(pageDriver.PAGE_SCRIPT_TIMEOUT_MS) 학생에게 넘긴다.'
}
