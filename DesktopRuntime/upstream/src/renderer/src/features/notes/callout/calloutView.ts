import type { Node as ProseNode } from '@milkdown/prose/model'
import type { NodeView } from '@milkdown/prose/view'
import { $view } from '@milkdown/utils'
import { calloutSchema } from './calloutSchema'
import {
  calloutLabel,
  normalizeCalloutType,
  type CalloutType
} from './calloutTypes'
import './callout.css'

const SVG_NAMESPACE = 'http://www.w3.org/2000/svg'

const CALLOUT_ICON_PATHS: Readonly<Record<CalloutType, readonly string[]>> = {
  note: ['M5 4h14v16H5z', 'M8 8h8M8 12h8M8 16h5'],
  abstract: ['M5 5h14M5 10h14M5 15h9M5 20h6'],
  info: ['M12 10v7', 'M12 7h.01', 'M3 12a9 9 0 1 0 18 0 9 9 0 0 0-18 0'],
  todo: ['M5 4h14v16H5z', 'm8 12 2.5 2.5L16 9'],
  tip: ['M9 18h6', 'M10 21h4', 'M8.5 14.5A6 6 0 1 1 15.5 14.5L15 16H9z'],
  success: ['m8 12 2.5 2.5L16 9', 'M3 12a9 9 0 1 0 18 0 9 9 0 0 0-18 0'],
  question: ['M9.5 9a2.7 2.7 0 1 1 4 2.4c-1 .7-1.5 1.2-1.5 2.6', 'M12 17h.01', 'M3 12a9 9 0 1 0 18 0 9 9 0 0 0-18 0'],
  warning: ['M12 4 2.5 20h19z', 'M12 10v4', 'M12 17h.01'],
  failure: ['m9 9 6 6M15 9l-6 6', 'M3 12a9 9 0 1 0 18 0 9 9 0 0 0-18 0'],
  bug: ['M8 9h8v8a4 4 0 0 1-8 0z', 'M9 5l2 2M15 5l-2 2M5 12h3M16 12h3M5 16h3M16 16h3'],
  example: ['M9 3h6', 'M10 3v6l-5 9a2 2 0 0 0 2 3h10a2 2 0 0 0 2-3l-5-9V3', 'M8 15h8'],
  quote: ['M6 7h5v5H8v5H5v-6a4 4 0 0 1 1-4M15 7h5v5h-3v5h-3v-6a4 4 0 0 1 1-4']
}

function sourceType(node: ProseNode): string {
  const value = node.attrs['type']
  return typeof value === 'string' && value.length > 0 ? value : 'note'
}

function nodeTitle(node: ProseNode): string {
  const value = node.attrs['title']
  return typeof value === 'string' ? value : ''
}

function nodeCollapsed(node: ProseNode): boolean {
  return node.attrs['collapsed'] === true
}

function createIcon(type: CalloutType): SVGSVGElement {
  const icon = document.createElementNS(SVG_NAMESPACE, 'svg')
  icon.classList.add('note-callout__icon')
  icon.setAttribute('aria-hidden', 'true')
  icon.setAttribute('viewBox', '0 0 24 24')
  icon.setAttribute('fill', 'none')
  icon.setAttribute('stroke', 'currentColor')
  icon.setAttribute('stroke-linecap', 'round')
  icon.setAttribute('stroke-linejoin', 'round')
  icon.setAttribute('stroke-width', '1.75')
  for (const pathData of CALLOUT_ICON_PATHS[type]) {
    const path = document.createElementNS(SVG_NAMESPACE, 'path')
    path.setAttribute('d', pathData)
    icon.append(path)
  }
  return icon
}

function createChevron(): SVGSVGElement {
  const icon = document.createElementNS(SVG_NAMESPACE, 'svg')
  const path = document.createElementNS(SVG_NAMESPACE, 'path')
  icon.classList.add('note-callout__chevron-icon')
  icon.setAttribute('aria-hidden', 'true')
  icon.setAttribute('viewBox', '0 0 24 24')
  icon.setAttribute('fill', 'none')
  icon.setAttribute('stroke', 'currentColor')
  icon.setAttribute('stroke-linecap', 'round')
  icon.setAttribute('stroke-linejoin', 'round')
  icon.setAttribute('stroke-width', '1.75')
  path.setAttribute('d', 'm6 9 6 6 6-6')
  icon.append(path)
  return icon
}

export const calloutView = $view(
  calloutSchema.node,
  () =>
    (initialNode, editorView, getPos): NodeView => {
      let currentNode = initialNode
      let titleInput: HTMLInputElement | null = null

      const dom = document.createElement('div')
      const header = document.createElement('div')
      const iconSlot = document.createElement('span')
      const title = document.createElement('span')
      const toggle = document.createElement('button')
      const body = document.createElement('div')

      dom.className = 'note-callout'
      header.className = 'note-callout__header'
      header.contentEditable = 'false'
      iconSlot.className = 'note-callout__icon-slot'
      title.className = 'note-callout__title'
      toggle.type = 'button'
      toggle.className = 'note-callout__toggle'
      toggle.append(createChevron())
      body.className = 'note-callout__body'
      header.append(iconSlot, title, toggle)
      dom.append(header, body)

      const updateAttrs = (attrs: Record<string, unknown>): void => {
        const position = getPos()
        if (position === undefined) return
        editorView.dispatch(
          editorView.state.tr.setNodeMarkup(position, undefined, {
            ...currentNode.attrs,
            ...attrs
          })
        )
      }

      const render = (): void => {
        const rawType = sourceType(currentNode)
        const normalizedType = normalizeCalloutType(rawType)
        const collapsed = nodeCollapsed(currentNode)

        dom.dataset.callout = normalizedType
        dom.dataset.calloutType = rawType
        dom.dataset.calloutTitle = nodeTitle(currentNode)
        dom.dataset.calloutCollapsed = String(collapsed)
        iconSlot.replaceChildren(createIcon(normalizedType))
        if (titleInput === null) {
          title.textContent = nodeTitle(currentNode) || calloutLabel(rawType)
        }
        body.hidden = collapsed
        toggle.setAttribute('aria-expanded', String(!collapsed))
        toggle.setAttribute(
          'aria-label',
          collapsed ? '콜아웃 펼치기' : '콜아웃 접기'
        )
      }

      const finishTitleEdit = (save: boolean): void => {
        const input = titleInput
        if (input === null) return
        titleInput = null
        const value = input.value
        input.replaceWith(title)
        if (save && value !== nodeTitle(currentNode)) {
          title.textContent = value || calloutLabel(sourceType(currentNode))
          updateAttrs({ title: value })
        } else {
          render()
        }
      }

      const handleTitleDoubleClick = (): void => {
        if (titleInput !== null) return
        const input = document.createElement('input')
        input.type = 'text'
        input.className = 'note-callout__title-input'
        input.value = nodeTitle(currentNode)
        input.placeholder = calloutLabel(sourceType(currentNode))
        input.setAttribute('aria-label', '콜아웃 제목')
        input.addEventListener('blur', () => finishTitleEdit(true), {
          once: true
        })
        input.addEventListener('keydown', (event) => {
          if (event.key === 'Enter') {
            event.preventDefault()
            finishTitleEdit(true)
          } else if (event.key === 'Escape') {
            event.preventDefault()
            finishTitleEdit(false)
          }
        })
        titleInput = input
        title.replaceWith(input)
        input.focus()
        input.select()
      }

      const handleToggle = (): void => {
        updateAttrs({ collapsed: !nodeCollapsed(currentNode) })
      }

      title.addEventListener('dblclick', handleTitleDoubleClick)
      toggle.addEventListener('click', handleToggle)
      render()

      return {
        dom,
        contentDOM: body,
        update: (node) => {
          if (node.type !== currentNode.type) return false
          currentNode = node
          render()
          return true
        },
        stopEvent: (event) =>
          event.target instanceof Node && header.contains(event.target),
        ignoreMutation: (mutation) =>
          header.contains(mutation.target) ||
          (mutation.type === 'attributes' &&
            (mutation.target === dom || mutation.target === body)),
        destroy: () => {
          title.removeEventListener('dblclick', handleTitleDoubleClick)
          toggle.removeEventListener('click', handleToggle)
        }
      }
    }
)
