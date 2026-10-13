import type { Node as ProseNode } from '@milkdown/prose/model'
import type { NodeView, NodeViewConstructor } from '@milkdown/prose/view'

function isTask(node: ProseNode): boolean {
  return typeof node.attrs['checked'] === 'boolean'
}

/** A small, theme-neutral NodeView that makes GFM task items clickable. */
export const taskListItemView: NodeViewConstructor = (
  initialNode,
  editorView,
  getPos
): NodeView => {
  let currentNode = initialNode
  const dom = document.createElement('li')
  const checkbox = document.createElement('input')
  const contentDOM = document.createElement('div')

  checkbox.type = 'checkbox'
  checkbox.className = 'note-task-checkbox'
  checkbox.contentEditable = 'false'
  contentDOM.className = 'note-list-item-content'
  dom.append(checkbox, contentDOM)

  const render = (): void => {
    const task = isTask(currentNode)
    dom.classList.toggle('note-list-item--task', task)
    dom.dataset.itemType = task ? 'task' : 'list'
    dom.dataset.checked = String(currentNode.attrs['checked'] === true)
    checkbox.hidden = !task
    checkbox.checked = currentNode.attrs['checked'] === true
    checkbox.setAttribute(
      'aria-label',
      checkbox.checked ? '완료한 항목으로 표시됨' : '완료하지 않은 항목으로 표시됨'
    )
  }

  const handleChange = (): void => {
    const position = getPos()
    if (position === undefined || !isTask(currentNode)) return
    editorView.dispatch(
      editorView.state.tr.setNodeMarkup(position, undefined, {
        ...currentNode.attrs,
        checked: checkbox.checked
      })
    )
  }

  checkbox.addEventListener('change', handleChange)
  render()

  return {
    dom,
    contentDOM,
    update: (node) => {
      if (node.type !== currentNode.type) return false
      currentNode = node
      render()
      return true
    },
    stopEvent: (event) => event.target === checkbox,
    ignoreMutation: (mutation) =>
      mutation.type === 'attributes' &&
      (mutation.target === dom || mutation.target === checkbox),
    destroy: () => checkbox.removeEventListener('change', handleChange)
  }
}
