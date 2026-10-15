import { fileURLToPath } from 'node:url'
const store = fileURLToPath(new URL('./PdfInputStore.tsx', import.meta.url))
const palette = fileURLToPath(new URL('./PdfPalette.tsx', import.meta.url))
const markdown = fileURLToPath(new URL('./markdown.ts', import.meta.url))
const persistence = fileURLToPath(new URL('./workspacePersistence.ts', import.meta.url))

function replace(source, anchor, replacement, count = 1) {
  if (source.split(anchor).length - 1 !== count) throw new Error(`iPad document input anchor changed: ${anchor.slice(0, 100)}`)
  return source.split(anchor).join(replacement)
}

/** iPad document interaction. Ink storage/history retain their original contracts. */
export function adaptInputSource(source, id) {
  let code = source
  const suffix = name => id.endsWith('/src/renderer/src/' + name)
  if (id.endsWith('/renderer/bootstrap.ts')) {
    code = `import { installMarkdownInputPolicy } from ${JSON.stringify(markdown)}\n` + code
    code = replace(code, '  installScribblePolicy()', '  installScribblePolicy()\n  installMarkdownInputPolicy()')
  }
  if (id.endsWith('/renderer/lifecycle.ts')) {
    code = `import { flushIPadWorkspaceLayout } from ${JSON.stringify(persistence)}\n` + code
    code = replace(code, '.then(([notes, ink]) => flushNativeWorkspace(notes, ink))', `.then(async ([notes, ink]) => {
      let report: Awaited<ReturnType<typeof flushNativeWorkspace>> | undefined
      let firstFailure: unknown, rejected = false
      try { report = await flushNativeWorkspace(notes, ink) }
      catch (error) { firstFailure = error; rejected = true }
      let layoutSaved = false
      try { layoutSaved = await flushIPadWorkspaceLayout() }
      catch (error) { if (!rejected) { firstFailure = error; rejected = true } }
      if (rejected) throw firstFailure
      if (layoutSaved) return report!
      return { ok: false, pending: [...report!.pending, { courseId: '', relPath: '', status: 'layout-save' }] }
    })`)
  }
  if (suffix('stores/workspaceStore.ts')) {
    code = `import { registerIPadWorkspaceSaveQueue } from ${JSON.stringify(persistence)}\n` + code
    code = replace(code, `        // Decorative churn (focus change). No debounce timer for focus alone,
        // but always park the snapshot so flush (beforeunload / course switch)
        // carries the latest active tab — otherwise quitting after only
        // switching tabs restores the wrong active tab.
        replacePendingSave(activeCourseId, persistentLayout(layout))`, `        // iPad may suspend or terminate without beforeunload. Persist tab
        // selection through the same debounced, serialized writer as layout.
        scheduleSave(activeCourseId, persistentLayout(layout))`)
    code += `\nregisterIPadWorkspaceSaveQueue({
  capture: () => useWorkspaceStore.getState().notifyLayoutChanged(),
  flush: () => useWorkspaceStore.getState().flushPendingSave(),
  status: () => ({ pending: pendingSaves.length > 0 || activeSave !== null, failed: pendingSaves.some(save => save.exhausted) })
})\n`
  }
  if (suffix('features/notes/noteAutoFocus.ts')) {
    code = `import { mayAutoFocusMarkdown } from ${JSON.stringify(markdown)}\n` + code
    code = replace(code, '  if (!root.isConnected', '  if (!mayAutoFocusMarkdown(root)) return false\n  if (!root.isConnected')
  }
  if (suffix('features/notes/NoteTab.tsx')) {
    code = `import { deactivateMarkdownInput } from ${JSON.stringify(markdown)}\n` + code
    code = replace(code, '          className="note-editor"', '          className="note-editor"\n          data-ipad-markdown-body="true"')
    code = replace(code, '      if (isActive) return\n      flushPendingEditorMarkdown()', '      if (isActive) return\n      deactivateMarkdownInput(containerRef.current)\n      flushPendingEditorMarkdown()')
  }
  for (const name of ['features/pdf/PdfTab.tsx', 'features/pdf/PdfToolbar.tsx', 'features/pdf/PdfPageView.tsx', 'features/pdf/tools/DrawingLayer.tsx']) {
    if (!suffix(name)) continue
    const original = name.includes('/tools/') ? "import { usePdfToolStore } from './toolStore'" : "import { usePdfToolStore } from './tools/toolStore'"
    code = replace(code, original, `import { usePdfInputStore as usePdfToolStore } from ${JSON.stringify(store)}`)
  }
  if (suffix('features/pdf/tools/PdfToolRail.tsx')) {
    code = replace(code, "import { usePdfToolStore, type PdfDrawingTool } from './toolStore'", `import type { PdfDrawingTool } from './toolStore'\nimport { usePdfInputStore as usePdfToolStore } from ${JSON.stringify(store)}`)
  }
  if (suffix('features/pdf/PdfTab.tsx')) {
    code = `import { PdfInputProvider } from ${JSON.stringify(store)}\n` + code
    code = replace(code, "import { PdfToolbar } from './PdfToolbar'", `import { PdfInputToolbar as PdfToolbar } from ${JSON.stringify(palette)}`)
    code = replace(code, '      <PdfViewer\n', '      <PdfInputProvider key={`${courseId}:${relPath}`} panelId={props.api.id} active={panelActive} visible={panelVisible} onActivate={() => props.api.setActive()}>\n      <PdfViewer\n')
    code = replace(code, '        pageNotePair={pageNotePair}\n      />', '        pageNotePair={pageNotePair}\n      />\n      </PdfInputProvider>')
  }
  if (suffix('features/pdf/PdfToolbar.tsx')) {
    code = replace(code, 'export interface PdfToolbarProps {', 'export interface PdfToolbarProps {\n  hideDrawingTools?: boolean')
    code = replace(code, '          if (toolsOpen) usePdfToolStore.getState().setActiveTool(\'select\')\n', '')
    code = replace(code, '      <button\n        className="pdf-toolbar__annotation-toggle"', '      {!props.hideDrawingTools && <>\n      <button\n        className="pdf-toolbar__annotation-toggle"')
    code = replace(code, '        beforeExport={props.flushAnnotations}\n      />', '        beforeExport={props.flushAnnotations}\n      />\n      </>}')
  }
  return code === source ? null : { code, map: null }
}
export default function ipadDocumentInputPlugin() { return { name: 'bandal-ipad-document-input', enforce: 'pre', transform: adaptInputSource } }
