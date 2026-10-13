#!/usr/bin/env python3
"""Prepare a reviewable desktop integration patch; never modifies desktop sources."""
import argparse
import difflib
from pathlib import Path


def replace_once(content, needle, replacement):
    if content.count(needle) != 1:
        raise ValueError("Desktop integration anchor changed; inspect and update staging script")
    return content.replace(needle, replacement, 1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--desktop", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    updates = {}
    menu = (args.desktop / "src/main/menu.ts").read_text()
    menu = "import { iPadCompanionMenu } from './features/ipadSync/runtime'\n" + menu
    menu = replace_once(menu, "    { label: '윈도우', role: 'windowMenu' }", "    iPadCompanionMenu(),\n    { label: '윈도우', role: 'windowMenu' }")
    updates["src/main/menu.ts"] = menu

    handlers = (args.desktop / "src/main/ipc/registerHandlers.ts").read_text()
    handlers = "import { installIPadCompanion } from '../features/ipadSync/runtime'\n" + handlers
    needle = "  const account = createAccountRuntime(state => broadcast('auth:changed', state))"
    handlers = replace_once(handlers, needle, needle + """
  const ipadCompanion = installIPadCompanion({
    db,
    userDataPath: deps.userDataPath ?? app.getPath('userData'),
    getClient: () => account.getClient(),
    changed: courseIds => {
      broadcast('courses:changed', {})
      broadcast('board:changed', { courseId: null })
      for (const courseId of courseIds) {
        materialsRepo.invalidateTree(courseId)
        broadcast('materials:changed', { courseId })
      }
    }
  })
  app.on('will-quit', () => ipadCompanion.dispose())
""")
    handlers = replace_once(handlers, "  handle('auth:signOut', async () => {\n    await account.auth().signOut()", "  handle('auth:signOut', async () => {\n    ipadCompanion.pause()\n    await account.auth().signOut()")
    updates["src/main/ipc/registerHandlers.ts"] = handlers

    annotations = (args.desktop / "src/renderer/src/features/pdf/useAnnotations.ts").read_text()
    annotations = replace_once(annotations, "import { invoke } from '../../lib/ipc'", "import { invoke, onPush } from '../../lib/ipc'")
    needle = "  const create = useCallback((input: CreateAnnotationInput): Promise<Annotation | null> => {"
    annotations = replace_once(annotations, needle, """  useEffect(() => onPush('materials:changed', ({ courseId: changedCourseId }) => {
    if (changedCourseId !== courseId) return
    void enqueue(async () => {
      try {
        session.annotations = await invoke('annotations:listForFile', { courseId, relPath })
        session.loadError = null
      } catch (cause) { session.loadError = errorMessage(cause) }
      finally { publish() }
    })
  }), [courseId, relPath, enqueue, publish, session])

""" + needle)
    updates["src/renderer/src/features/pdf/useAnnotations.ts"] = annotations

    builder = (args.desktop / "electron-builder.yml").read_text()
    builder = replace_once(builder, "\nextraResources:\n", "\nextraResources:\n  - from: resources/ipad-bridge\n    to: ipad-bridge\n    filter:\n      - '**/*'\n")
    updates["electron-builder.yml"] = builder
    updates["src/main/features/ipadSync/runtime.ts"] = (here / "desktop-src/runtime.ts").read_text()
    updates["resources/ipad-bridge/bridge.py"] = (here / "bridge.py").read_text()
    updates["resources/ipad-bridge/pdf_geometry.swift"] = (here / "pdf_geometry.swift").read_text()
    chunks = []
    for relative, updated in updates.items():
        source = args.desktop / relative
        original = source.read_text() if source.exists() else ""
        chunks.extend(difflib.unified_diff(original.splitlines(keepends=True), updated.splitlines(keepends=True),
                                         fromfile="a/" + relative if source.exists() else "/dev/null", tofile="b/" + relative))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("".join(chunks))
    print(f"Staged {len(updates)} files in {args.output}; desktop sources unchanged")


if __name__ == "__main__": main()
