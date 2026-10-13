/**
 * Which of the app's own capabilities the agent can reach — and, for the rest,
 * why not.
 *
 * This file exists because of a real failure. 학기 그룹 shipped in v0.8.2 with
 * a repo, IPC, and drag-and-drop in the sidebar. Eleven releases later the
 * agent still had no tool for it — the word "group" appeared ZERO times in the
 * whole agentTools layer — so a student who asked to change the semester got
 * the assistant clicking around a university website instead, because the
 * browser was the only surface it could see.
 *
 * Nothing detected that. There was no list to be missing from.
 *
 * So: every channel that CHANGES the study workspace must appear here, either
 * mapped to a tool or refused with a reason. A new feature that does neither
 * fails `coverage.test.ts` with the channel name in the message. The point is
 * not the mapping — it is that forgetting becomes loud.
 *
 * Out of scope on purpose: identity (`auth:*`), secrets (`credentials:*`), the
 * assistant's own plumbing (`chat:*`, `agent:*`, `agentTools:*`,
 * `browserAgent:*`), and app/system surfaces (`settings:*`, `update:*`,
 * `window:*`, `shell:*`, `print:*`, `layout:*`, `media:*`, `context:*`). Those
 * are not the study workspace. `mcp:*` manages external tool configuration,
 * so it does not belong in
 * WORKSPACE_PREFIXES either. An agent that could sign the student out or read
 * the credential store is a different product.
 */

/** The prefixes this file governs — the student's study workspace. */
export const WORKSPACE_PREFIXES: readonly string[] = [
  'activity',
  'annotations',
  'board',
  'calendar',
  'canvas',
  'courseGroups',
  'courseLinks',
  'courses',
  'drawings',
  'favorites',
  'link',
  'learning',
  'links',
  'materials',
  'notes',
  'pdf',
  'search',
  'study',
  'whiteboard'
]

/** Channel name → the agent tool that covers it. */
export const AGENT_CHANNEL_TOOLS: Readonly<Record<string, string>> = {
  'courses:create': 'create_course',
  'courses:rename': 'rename_course',
  'courses:archive': 'archive_course',
  'courses:delete': 'delete_course',
  'courses:organize': 'set_course_group',
  'courseGroups:create': 'create_course_group',
  'courseGroups:rename': 'rename_course_group',
  'courseGroups:delete': 'delete_course_group',
  'courseLinks:create': 'create_course_link',
  'courseLinks:update': 'update_course_link',
  'courseLinks:delete': 'delete_course_link',
  'materials:move': 'move_material',
  'materials:rename': 'rename_material',
  'materials:delete': 'delete_material',
  'materials:duplicate': 'duplicate_material',
  'materials:writeFile': 'write_file',
  'materials:createFolder': 'create_folder',
  'notes:create': 'create_note',
  'notes:write': 'overwrite_note',
  'notes:rename': 'rename_material',
  'board:createTask': 'create_task',
  'board:updateTask': 'update_task',
  'board:reorderTasks': 'update_task',
  'board:deleteTask': 'delete_task',
  'favorites:add': 'add_favorite',
  'favorites:rename': 'rename_favorite',
  'favorites:remove': 'remove_favorite',
  'links:create': 'link_materials',
  'search:query': 'search_course',
  'canvas:create': 'create_board',
  'canvas:rename': 'rename_board',
  'canvas:remove': 'delete_board',
  'canvas:setPageCount': 'add_page',
  'canvas:putShape': 'add_shapes',
  'canvas:removeShapes': 'remove_shapes',
  'link:sendHighlightToNote': 'send_highlight_to_note',
  'link:sendWebClipToNote': 'send_web_clip_to_note'
}

/**
 * App tools that can mutate the study workspace.
 *
 * Workflow-pack runs derive their runtime allowlist gate from this set so the
 * security boundary stays coupled to the capability coverage map above. A
 * newly mapped mutation therefore becomes restricted automatically instead
 * of relying on a second hand-maintained list.
 */
export const AGENT_MUTATING_TOOL_NAMES: ReadonlySet<string> = new Set(
  Object.values(AGENT_CHANNEL_TOOLS)
)

/**
 * Channels the agent deliberately cannot reach, and why.
 *
 * A reason is required. "We did not get to it" is not one — that is the state
 * this file exists to make visible, so leave such a channel out entirely and
 * let the test fail.
 */
export const NOT_FOR_AGENT: Readonly<Record<string, string>> = {
  // -- irreversible or outside the app's own data ---------------------------
  'courses:purge':
    '휴지통 비우기는 되돌릴 수 없고 디스크의 실제 폴더를 지운다. 학생이 직접 누른다.',
  'courses:pickFolder': 'OS 폴더 선택 창. 사람이 서 있어야 하는 자리다.',
  'courses:addFromFolder':
    '폴더 선택 창의 결과를 받는 짝. pickFolder 없이는 의미가 없다.',
  'courses:relink':
    '끊긴 과목을 다른 폴더에 다시 붙이는 일. 잘못 붙이면 남의 과목 자료를 그 과목 것으로 만든다.',
  'courses:setColor':
    '과목 색상은 학생의 시각적 취향이므로 사이드바에서 직접 고른다.',
  'materials:reveal': 'Finder 를 여는 일. 앱 밖의 동작이다.',
  'materials:preview': 'OS 미리보기(Quick Look)를 여는 일. 앱 밖의 동작이다.',
  'links:remove':
    '링크 해제는 학생이 화면에서 한 번 누르면 되고, 에이전트가 자료 그래프를 지울 이유가 없다.',
  'links:updatePageNote':
    '페이지 스크롤 동기화 설정은 현재 열린 두 패널의 직접 조작 상태라 학생이 화면에서 선택한다.',

  // -- internal plumbing, not capabilities ----------------------------------
  'materials:snapshot': '자료 목록을 즉시 복원하기 위한 UI 캐시. 에이전트는 list_materials로 완성된 목록을 읽는다.',
  'materials:hoverPreview': '자료 행의 읽기 전용 미리보기. 에이전트의 자료 읽기는 read_material을 사용한다.',
  'materials:watch': '파일 감시자 수명. 렌더러가 패널을 열고 닫으며 관리한다.',
  'materials:unwatch': '파일 감시자를 떼는 짝. 위와 같은 이유로 렌더러 소관이다.',
  'activity:record': '텔레메트리. 에이전트가 자기 활동을 위조할 자리가 아니다.',
  'pdf:setViewState':
    '학생이 보던 페이지의 기록. 에이전트가 학생의 시점을 바꿔칠 자리가 아니다.',
  'canvas:open': '캔버스 세션 수명. 렌더러가 관리한다.',
  'canvas:hoverPreview': '자료 행의 첫 페이지 미리보기를 위한 제한된 읽기 전용 조회다.',
  'search:indexPdfPages': '색인 배관. 검색이 알아서 부른다.',
  'study:tools': '학습 계획 러너의 내부 표면.',
  'study:run': '위와 같음 — 에이전트가 자기를 재귀 호출할 자리다.',
  'study:generate': '학습 실행의 시작은 사용자 UI가 담당하며 에이전트가 자기를 재귀 호출하지 않는다.',
  'learning:create': '학습 공간의 위치·관심 주제는 사용자 시작 화면에서 결정한다.',
  'learning:updateSettings': '학습 공간 종류·관심 주제·연결 과목과 AI 제공자·모델은 사용자가 설정 화면에서 확인하고 선택한다.',
  'learning:rename': '학습 공간의 표시 이름은 사용자가 목록에서 직접 정하며 원본 과목과 폴더 경로는 유지한다.',
  'learning:delete': '학습 공간 목록 제거는 진행 중 학습 중단과 보존할 기록을 사용자가 확인하고 결정한다.',
  'learning:restore': '제거한 학습 공간의 복원은 사용자가 삭제 목록에서 원래 공간을 확인하고 결정한다.',
  'learning:dismissRun': '실패 안내를 숨길지는 학습자가 결정하며 에이전트가 자기 실패를 목록에서 숨기지 않는다.',
  'learning:addArticle': '네이티브 실행은 learning_verify_article와 learning_submit_result로 검증된 기사만 제출한다.',
  'learning:saveWord': '모르는 표현은 학습자가 원문에서 직접 선택하고 저장한다.',
  'learning:updateWord': '표현의 익숙함과 사용자 수정은 학습자의 판단을 보존한다.',
  'learning:updateOccurrence': '문맥별 뜻은 학습자가 예문과 함께 직접 수정하고 보존한다.',
  'learning:saveProgress': '읽기 위치는 실제 읽기 화면의 스크롤 위치를 저장한다.',
  'learning:completeArticle': '읽기 완료는 학습자가 직접 표시하며 AI가 대신 처리하지 않는다.',
  'learning:saveQuizAnswer': '학습자의 답과 자기평가는 학습자가 직접 입력한다.',
  'learning:finishQuiz': '학습자의 풀이 완료와 채점은 학습 화면에서 실행한다.',
  'learning:reviewCard': '기억 정도와 다음 복습일은 학습자의 실제 카드 응답으로 기록한다.',
  'learning:run': '학습 실행의 시작은 사용자 UI가 담당하며 AI가 재귀 실행하지 않는다.',
  'learning:runCancel': '실행 취소는 사용자의 학습 화면에서 요청한다.',
  'learning:runRetry': '중단된 작업 재시도는 사용자가 선택하며 AI가 재귀 실행하지 않는다.',
  'learning:importPreview': '기존 자료 변환은 사용자가 원본 자료를 선택하고 미리보기를 요청한다.',
  'learning:importSave': '가져오기 미리보기를 확인한 사용자가 새 학습 자료 저장을 확정한다.',

  // -- shared/group surfaces, which are a different product ------------------

  // -- the agent cannot compute what these need -----------------------------
  'annotations:create':
    '하이라이트는 PDF 페이지 위의 좌표 사각형이다. 에이전트는 그걸 계산할 수단이 없고, 짐작해서 그으면 엉뚱한 문단이 칠해진다. 이미 있는 하이라이트를 필기로 보내는 건 link:sendHighlightToNote 가 한다.',
  'annotations:update': '위와 같은 이유 — 좌표를 다루는 일이다.',
  'annotations:delete':
    '학생이 자기 손으로 그은 표시다. 지우는 건 본인이 판단할 일이고, 되돌릴 수도 없다.',
  'drawings:create':
    '자유 필기(잉크)는 점의 궤적이다. 에이전트가 만들 만한 것이 아니다.',
  'drawings:update': '자유 필기의 궤적을 고치는 일이다. 위와 같은 이유로 사람 몫이다.',
  'drawings:delete': '학생이 손으로 그린 것이다. 지우는 건 본인 몫이다.',
  'canvas:setBackground': '보드 배경은 취향이다. 시켜서 바꿀 일이 아니다.',
  'favorites:reorder':
    '순서는 취향이고, 에이전트에겐 학생이 무엇을 자주 쓰는지 알 근거가 없다.',

  // -- already covered by a better path --------------------------------------
  'materials:downloadFromUrl':
    '주소에서 자료를 받는 일은 browser_download 가 한다. 그쪽은 학생의 로그인 세션을 쓰고 사이트 권한 게이트를 지난다.',
  'materials:import':
    'OS 파일 선택 창이 짝인 경로다. 에이전트가 부를 자리가 없고, 파일을 만드는 일은 write_file 이 한다.',
  'pdf:exportAnnotated':
    '저장 위치를 묻는 OS 창이 뜬다. 사람이 서 있어야 하는 자리다.',
  'canvas:exportPdf': '위와 같음 — 저장 창이 뜬다.'
}
