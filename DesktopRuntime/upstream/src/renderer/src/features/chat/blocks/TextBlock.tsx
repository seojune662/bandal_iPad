/**
 * Streaming markdown text block. Renders through MarkdownView (React-escaped,
 * never raw HTML) with a soft caret while the block is still streaming.
 */

import type { TextBlockView } from '../chatModel'
import { MarkdownView } from '../MarkdownView'

export interface TextBlockProps {
  block: TextBlockView
}

export function TextBlock({ block }: TextBlockProps): JSX.Element | null {
  if (block.text === '' && !block.streaming) {
    return null
  }
  return (
    <div className="chat-text" data-streaming={block.streaming || undefined}>
      <MarkdownView text={block.text} streaming={block.streaming} />
    </div>
  )
}
