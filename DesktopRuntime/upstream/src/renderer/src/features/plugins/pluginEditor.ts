import { Plugin } from '@milkdown/prose/state'
import type { EditorState } from '@milkdown/prose/state'
import type { EditorView } from '@milkdown/prose/view'
import type {
  PluginEditorRequest,
  PluginEditorSelection,
} from '../../../../shared/types/pluginEditor'
import { invoke, onPush } from '../../lib/ipc'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { usePluginsStore } from '../../stores/pluginsStore'

interface Session {
  view: EditorView
  courseId: string
  panelId: string | undefined
  relPath(): string
  touched: number
}
const sessions = new Set<Session>()
const snapshots = new Map<
  string,
  {
    session: Session
    state: EditorState
    pluginId: string
    path: string
    expires: number
  }
>()
let touch = 0

export function createPluginEditorAccess(
  courseId: string,
  relPath: () => string,
  panelId?: string,
): Plugin {
  return new Plugin({
    view(view) {
      const session = { view, courseId, panelId, relPath, touched: ++touch }
      sessions.add(session)
      const focus = (): void => {
        session.touched = ++touch
      }
      view.dom.addEventListener('focus', focus)
      return {
        destroy() {
          sessions.delete(session)
          view.dom.removeEventListener('focus', focus)
          for (const [token, entry] of snapshots)
            if (entry.session === session) snapshots.delete(token)
        },
      }
    },
  })
}

export function handlePluginEditorRequest(
  request: PluginEditorRequest,
): PluginEditorSelection | null {
  const plugin = usePluginsStore
    .getState()
    .plugins.find((p) => p.manifest.id === request.pluginId)
  const required =
    request.action === 'getSelection' ? 'editor.read' : 'editor.write'
  if (
    !plugin ||
    !['active', 'starting'].includes(plugin.state) ||
    !plugin.enabled ||
    !plugin.approvedPermissions?.includes(required)
  )
    throw new Error('Plugin editor access is no longer approved')
  for (const [token, entry] of snapshots)
    if (entry.expires < Date.now()) snapshots.delete(token)
  const workspace = useWorkspaceStore.getState()
  const source = workspace.activePanelSource?.()
  const panelId = source?.panelId ?? workspace.activePanelId
  // Older adapters do not identify panels. A real panel must never fall back
  // to the most recently focused duplicate of the same note.
  const tab = source?.descriptor ??
    (panelId ? null : workspace.activeTabDescriptor())
  const session =
    tab?.kind === 'note'
      ? [...sessions]
          .filter(
            (s) =>
              s.courseId === tab.payload.courseId &&
              (!panelId || s.panelId === panelId) &&
              s.relPath() === tab.payload.relPath &&
              s.view.dom.getClientRects().length > 0,
          )
          .sort((a, b) => b.touched - a.touched)[0]
      : undefined
  if (session === undefined) {
    if (request.action === 'getSelection') return null
    throw new Error('The target note is no longer active')
  }
  if (request.action === 'getSelection') {
    // At most one outstanding selection per plugin, bounded across idle use.
    for (const [token, entry] of snapshots)
      if (entry.pluginId === request.pluginId) snapshots.delete(token)
    const token = crypto.randomUUID()
    const state = session.view.state
    snapshots.set(token, {
      session,
      state,
      pluginId: request.pluginId,
      path: session.relPath(),
      expires: Date.now() + 60_000,
    })
    return {
      token,
      courseId: session.courseId,
      relPath: session.relPath(),
      from: state.selection.from,
      to: state.selection.to,
      text: state.doc.textBetween(
        state.selection.from,
        state.selection.to,
        '\n',
      ),
    }
  }
  const snapshot = snapshots.get(request.token ?? '')
  snapshots.delete(request.token ?? '')
  if (
    !snapshot ||
    snapshot.pluginId !== request.pluginId ||
    snapshot.session !== session ||
    snapshot.path !== session.relPath() ||
    !snapshot.state.doc.eq(session.view.state.doc) ||
    !snapshot.state.selection.eq(session.view.state.selection)
  )
    throw new Error('The note or selection changed. Read the selection again.')
  if (typeof request.text !== 'string' || request.text.length > 100_000)
    throw new Error('Invalid replacement text')
  session.view.dispatch(
    session.view.state.tr
      .insertText(
        request.text,
        snapshot.state.selection.from,
        snapshot.state.selection.to,
      )
      .scrollIntoView(),
  )
  session.view.focus()
  return null
}

export function subscribePluginEditor(): () => void {
  return onPush('plugins:editorRequest', (request) => {
    try {
      const value = handlePluginEditorRequest(request)
      void invoke('plugins:editorReply', {
        requestId: request.requestId,
        value,
      }).catch(() => undefined)
    } catch (error) {
      void invoke('plugins:editorReply', {
        requestId: request.requestId,
        value: null,
        error: error instanceof Error ? error.message : String(error),
      }).catch(() => undefined)
    }
  })
}
