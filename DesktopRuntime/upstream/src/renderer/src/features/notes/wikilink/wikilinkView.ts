/**
 * Node view for the wikilink chip: resolves the target against the course's
 * materials, opens it on click, or creates the note when nothing matches.
 *
 * The editor tells the view which course/note it belongs to through the
 * `wikilinkContextCtx` slice — NoteTab sets it in `editor.config()`, which
 * runs after every `$ctx` is injected and before the first render.
 */

import { $ctx, $view } from '@milkdown/utils'
import type { Node as ProseNode } from '@milkdown/prose/model'
import type { NodeView, NodeViewConstructor } from '@milkdown/prose/view'
import { showToast } from '../../../app/toast'
import { invoke } from '../../../lib/ipc'
import { openMaterialLink } from '../materialLinkNavigation'
import {
  WIKILINK_EMBED_LABEL,
  wikilinkLabel,
  wikilinkPartsFromNode,
  wikilinkSchema
} from './wikilinkSchema'
import {
  invalidateWikilinkResolver,
  resolveWikilink,
  subscribeWikilinkResolver
} from './wikilinkResolverStore'
import './wikilink.css'

export interface WikilinkEditorContext {
  courseId: string
  /** Read lazily so a rename never has to rebuild the editor. */
  getSelfRelPath: () => string
}

const DEFAULT_CONTEXT: WikilinkEditorContext = {
  courseId: '',
  getSelfRelPath: () => ''
}

export const wikilinkContextCtx = $ctx<WikilinkEditorContext, 'wikilinkContext'>(
  DEFAULT_CONTEXT,
  'wikilinkContext'
)

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function dirnameOf(relPath: string): string {
  const slash = relPath.lastIndexOf('/')
  return slash === -1 ? '' : relPath.slice(0, slash)
}

function basenameOf(relPath: string): string {
  return relPath.split('/').at(-1) ?? relPath
}

/**
 * Creates the note `[[target]]` points at, next to the current note (or in
 * the folder the target names), then opens it and refreshes every chip.
 */
export async function createWikilinkNote(
  context: WikilinkEditorContext,
  target: string
): Promise<void> {
  const targetDir = dirnameOf(target)
  const dirRelPath = targetDir === '' ? dirnameOf(context.getSelfRelPath()) : targetDir
  const title = basenameOf(target).replace(/\.(?:md|markdown)$/iu, '')
  const created = await invoke('notes:create', {
    courseId: context.courseId,
    dirRelPath,
    title
  })
  invalidateWikilinkResolver(context.courseId)
  openMaterialLink(context.courseId, { relPath: created.relPath, page: null })
}

export function openWikilink(
  context: WikilinkEditorContext,
  target: string
): void {
  if (context.courseId.length === 0 || target.trim().length === 0) return
  const resolved = resolveWikilink(context.courseId, target)
  if (resolved !== null) {
    openMaterialLink(context.courseId, { relPath: resolved, page: null })
    return
  }
  void createWikilinkNote(context, target).catch((caught: unknown) => {
    console.error('[Bandal] 위키링크 노트를 만들지 못했습니다.', caught)
    showToast(`노트를 만들지 못했습니다: ${errorMessage(caught)}`)
  })
}

export function createWikilinkNodeView(
  getContext: () => WikilinkEditorContext
): NodeViewConstructor {
  return (initialNode): NodeView => {
    let currentNode: ProseNode = initialNode
    const dom = document.createElement('span')
    const badge = document.createElement('span')
    const label = document.createElement('span')
    dom.className = 'note-wikilink'
    dom.contentEditable = 'false'
    dom.setAttribute('role', 'link')
    badge.className = 'note-wikilink__embed'
    badge.textContent = WIKILINK_EMBED_LABEL
    label.className = 'note-wikilink__label'
    dom.append(badge, label)

    const render = (): void => {
      const parts = wikilinkPartsFromNode(currentNode)
      const context = getContext()
      const resolved =
        context.courseId.length === 0
          ? null
          : resolveWikilink(context.courseId, parts.target)
      dom.dataset['wikilink'] = parts.target
      dom.dataset['resolved'] = String(resolved !== null)
      if (parts.heading === null) delete dom.dataset['heading']
      else dom.dataset['heading'] = parts.heading
      if (parts.alias === null) delete dom.dataset['alias']
      else dom.dataset['alias'] = parts.alias
      if (parts.embed) dom.dataset['embed'] = 'true'
      else delete dom.dataset['embed']
      badge.hidden = !parts.embed
      label.textContent = wikilinkLabel(parts)
      dom.title =
        resolved === null
          ? `${parts.target} — 클릭하면 새 노트를 만듭니다`
          : resolved
    }

    const handleClick = (event: MouseEvent): void => {
      event.preventDefault()
      openWikilink(getContext(), wikilinkPartsFromNode(currentNode).target)
    }

    dom.addEventListener('click', handleClick)
    const unsubscribe = subscribeWikilinkResolver(render)
    render()

    return {
      dom,
      update: (node) => {
        if (node.type !== currentNode.type) return false
        currentNode = node
        render()
        return true
      },
      ignoreMutation: () => true,
      destroy: () => {
        dom.removeEventListener('click', handleClick)
        unsubscribe()
      }
    }
  }
}

export const wikilinkView = $view(wikilinkSchema.node, (ctx) =>
  createWikilinkNodeView(() => ctx.get(wikilinkContextCtx.key))
)
