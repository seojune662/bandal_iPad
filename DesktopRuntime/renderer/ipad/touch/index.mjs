import { fileURLToPath } from 'node:url'
const actions = fileURLToPath(new URL('./actions.tsx', import.meta.url))
const css = fileURLToPath(new URL('./touch.css', import.meta.url))
const tabDrag = fileURLToPath(new URL('./tabDrag.ts', import.meta.url))
function replace(source, anchor, value) {
  if (source.split(anchor).length !== 2) throw new Error(`iPad touch adapter anchor changed: ${anchor.slice(0,100)}`)
  return source.replace(anchor, value)
}
export function adaptTouchSource(source, id) {
  let code = source
  if (id.endsWith('/renderer/bootstrap.ts')) code = `import ${JSON.stringify(css)}\n` + code
  if (id.endsWith('/features/workspace/WorkspaceTab.tsx')) {
    code = replace(code, "      dockviewTab.setAttribute('role', 'tab')", "      dockviewTab.dataset.ipadPanelId = props.api.id\n      dockviewTab.setAttribute('role', 'tab')")
  }
  if (id.endsWith('/features/workspace/WorkspaceHost.tsx')) {
    code = `import { installWorkspaceTouchDrag } from ${JSON.stringify(tabDrag)}\n` + code
    code = replace(code, '    const stopSession = installWorkspaceDragSession(host)', '    const stopSession = installWorkspaceDragSession(host)\n    const stopTouchDrag = installWorkspaceTouchDrag(host)')
    code = replace(code, 'stopTabs(); stopSession(); stopNavigation();', 'stopTouchDrag(); stopTabs(); stopSession(); stopNavigation();')
  }
  if (id.endsWith('/features/workspace/CourseTabMoveOverlay.tsx')) {
    code = replace(code, 'className="course-tab-move-preview"', 'className="course-tab-move-preview" data-bandal-native-overlay="true"')
  }
  if (id.endsWith('/app/GlobalNavigation.tsx')) {
    code = `import { revealWorkspaceCourseDropSidebar } from ${JSON.stringify(tabDrag)}\n` + code
    code = replace(code, 'onClick={openCourses}', 'onClick={openCourses}\n          onDragEnter={revealWorkspaceCourseDropSidebar}\n          onDragOver={revealWorkspaceCourseDropSidebar}')
  }
  if (id.endsWith('/features/materials/WhiteboardsGroup.tsx')) {
    code = `import { WhiteboardTouchActions } from ${JSON.stringify(actions)}\n` + code
    code = replace(code, '<MaterialRowAffordance target={{ courseId, board }}>', '<WhiteboardTouchActions label={board.title} disabled={pending}><MaterialRowAffordance target={{ courseId, board }}>')
    code = replace(code, '</MaterialRowAffordance>', '</MaterialRowAffordance></WhiteboardTouchActions>')
  }
  if (id.endsWith('/features/board/BoardPanel.tsx')) {
    code = `import { BoardTouchActions } from ${JSON.stringify(actions)}\n` + code
    code = replace(code, '    <article\n      className="board-card"', '    <BoardTouchActions label={task.title} disabled={disabled} onMenu={onContextMenu}>\n    <article\n      className="board-card"')
    code = replace(code, '    </article>', '    </article>\n    </BoardTouchActions>')
    code = replace(code, '          className="board-context-menu"', '          className="board-context-menu"\n          data-bandal-native-overlay="true"')
  }
  if (id.endsWith('/features/canvas/CanvasToolRail.tsx')) {
    code = replace(code, '    <div className="canvas-tools" role="toolbar" aria-label="개인 화이트보드 도구">', '    <div className="ipad-canvas-tools">\n    <div className="canvas-tools" role="toolbar" aria-label="개인 화이트보드 도구" aria-description="좁은 화면에서는 좌우로 밀어 모든 도구를 볼 수 있습니다" tabIndex={0}>')
    code = replace(code, '    </div>\n  )\n}', '    </div>\n    <div className="ipad-canvas-tools__hint" aria-hidden="true">← 도구를 좌우로 밀어 더 보기 →</div>\n    </div>\n  )\n}')
  }
  return source === code ? null : { code, map: null }
}
export default function ipadTouchPlugin() { return { name: 'bandal-ipad-touch-actions', enforce: 'pre', transform: adaptTouchSource } }
