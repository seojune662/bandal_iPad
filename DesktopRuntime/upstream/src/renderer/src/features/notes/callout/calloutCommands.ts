import { liftEmptyBlock, wrapIn } from '@milkdown/prose/commands'
import { wrappingInputRule } from '@milkdown/prose/inputrules'
import type { Command } from '@milkdown/prose/state'
import { $command, $inputRule, $useKeymap } from '@milkdown/utils'
import { calloutSchema } from './calloutSchema'
import type { CalloutType } from './calloutTypes'

export const wrapInCalloutCommand = $command<CalloutType, 'WrapInCallout'>(
  'WrapInCallout',
  (ctx) =>
    (type = 'note') =>
      wrapIn(calloutSchema.type(ctx), { type, title: '', collapsed: false })
)

export const calloutInputRule = $inputRule((ctx) =>
  wrappingInputRule(
    /^\s*>\s+\[!([a-z][\w-]*)\]([+-])?\s$/i,
    calloutSchema.type(ctx),
    (match) => ({
      type: match[1] ?? 'note',
      title: '',
      collapsed: match[2] === '-'
    })
  )
)

function exitEmptyCallout(typeName: string): Command {
  return (state, dispatch) => {
    const { $from, empty } = state.selection
    if (
      !empty ||
      !$from.parent.isTextblock ||
      $from.parent.content.size !== 0 ||
      $from.parentOffset !== 0
    ) {
      return false
    }

    let calloutDepth = -1
    for (let depth = $from.depth - 1; depth > 0; depth -= 1) {
      if ($from.node(depth).type.name === typeName) {
        calloutDepth = depth
        break
      }
    }
    if (calloutDepth < 0 || $from.index(calloutDepth) !== 0) return false

    return liftEmptyBlock(state, dispatch)
  }
}

export const calloutKeymap = $useKeymap('callout', {
  ExitCallout: {
    shortcuts: 'Backspace',
    priority: 100,
    command: (ctx) => exitEmptyCallout(calloutSchema.type(ctx).name)
  }
})
