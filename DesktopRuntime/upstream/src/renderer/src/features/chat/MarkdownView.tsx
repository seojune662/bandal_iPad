/** Render Markdown as React elements; only KaTeX-generated markup uses HTML. */
import { memo, useMemo, useRef, type MouseEvent } from 'react'
import katex from 'katex'
import 'katex/dist/katex.min.css'
import { openHttpLink } from '../../app/openHttpLink'
import {
  IncrementalMarkdownParser,
  type MdBlockNode,
  type MdInline
} from './markdown'
import './chat-markdown.css'

const MathFormula = memo(function MathFormula({
  text,
  display,
  pending
}: {
  text: string
  display: boolean
  pending: boolean
}): JSX.Element {
  const html = useMemo(() => {
    if (pending) return null
    try {
      return katex.renderToString(text, {
        displayMode: display,
        output: 'htmlAndMathml',
        throwOnError: true,
        trust: false,
        strict: 'ignore',
        maxExpand: 1000,
        maxSize: 20
      })
    } catch {
      return null
    }
  }, [text, display, pending])
  const className = `chat-md__math${display ? ' chat-md__math--display' : ''}`
  if (pending) {
    return <span className={`${className} chat-md__math--pending`} aria-label="수식 작성 중">수식 작성 중<span aria-hidden="true"> ···</span></span>
  }
  if (html === null) {
    return <span className={`${className} chat-md__math--fallback`}>{text}</span>
  }
  // KaTeX escapes text and blocks HTML / URL extensions with trust:false.
  // Untrusted Markdown itself is never passed to dangerouslySetInnerHTML.
  return <span className={className} dangerouslySetInnerHTML={{ __html: html }} />
})

function InlineNodes({ nodes }: { nodes: MdInline[] }): JSX.Element {
  return <>{nodes.map((node, index) => {
    switch (node.kind) {
      case 'text': return <span key={index}>{node.text}</span>
      case 'code': return <code key={index} className="chat-md__code">{node.text}</code>
      case 'math': return <MathFormula key={index} text={node.text} display={node.display} pending={node.pending} />
      case 'break': return <br key={index} />
      case 'strong': return <strong key={index}><InlineNodes nodes={node.children} /></strong>
      case 'em': return <em key={index}><InlineNodes nodes={node.children} /></em>
      case 'delete': return <del key={index}><InlineNodes nodes={node.children} /></del>
      case 'link': return (
        <a key={index} href={node.href} target="_blank" rel="noreferrer noopener" className="chat-md__link" onClick={(event) => handleLinkClick(event, node.href)}>
          <InlineNodes nodes={node.children} />
        </a>
      )
    }
  })}</>
}

function handleLinkClick(event: MouseEvent<HTMLAnchorElement>, href: string): void {
  let url: URL
  try {
    url = new URL(href)
  } catch {
    return
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return
  event.preventDefault()
  openHttpLink(url.toString(), {
    shift: event.shiftKey,
    mod: window.bandal?.platform === 'darwin' ? event.metaKey : event.ctrlKey
  })
}

function Blocks({ nodes }: { nodes: MdBlockNode[] }): JSX.Element {
  return <>{nodes.map((node, index) => <BlockNode key={index} node={node} />)}</>
}

const BlockNode = memo(function BlockNode({ node }: { node: MdBlockNode }): JSX.Element {
  switch (node.kind) {
    case 'paragraph': return <p className="chat-md__p"><InlineNodes nodes={node.children} /></p>
    case 'heading': {
      const Tag = `h${Math.min(node.level + 1, 6)}` as keyof JSX.IntrinsicElements
      return <Tag className="chat-md__heading" data-level={node.level}><InlineNodes nodes={node.children} /></Tag>
    }
    case 'code-block': return (
      <div className="chat-md__codeblock">
        {node.lang !== null && <div className="chat-md__codeblock-header">{node.lang}</div>}
        <pre><code>{node.text}</code></pre>
      </div>
    )
    case 'math-block': return <div className="chat-md__equation"><MathFormula text={node.text} display pending={node.pending} /></div>
    case 'list': {
      const items = node.items.map((item, index) => (
        <li key={index} className={item.checked === null ? undefined : 'chat-md__task'}>
          {item.checked !== null && <input type="checkbox" checked={item.checked} disabled aria-label={item.checked ? '완료' : '미완료'} />}
          <Blocks nodes={item.children} />
        </li>
      ))
      return node.ordered
        ? <ol className="chat-md__list" start={node.start}>{items}</ol>
        : <ul className="chat-md__list">{items}</ul>
    }
    case 'quote': return <blockquote className="chat-md__quote"><Blocks nodes={node.children} /></blockquote>
    case 'table': return (
      <div className="chat-md__table-wrap" role="region" aria-label="답변 표" tabIndex={0}>
        <table className="chat-md__table">
          <thead><tr>{node.rows[0]?.map((cell, index) => <th key={index} scope="col" style={{ textAlign: node.align[index] ?? undefined }}><InlineNodes nodes={cell} /></th>)}</tr></thead>
          <tbody>{node.rows.slice(1).map((row, rowIndex) => (
            <tr key={rowIndex}>{row.map((cell, index) => <td key={index} style={{ textAlign: node.align[index] ?? undefined }}><InlineNodes nodes={cell} /></td>)}</tr>
          ))}</tbody>
        </table>
      </div>
    )
    case 'hr': return <hr className="chat-md__hr" />
  }
})

export interface MarkdownViewProps {
  text: string
  streaming?: boolean
}

export const MarkdownView = memo(function MarkdownView({ text, streaming = false }: MarkdownViewProps): JSX.Element {
  const parserRef = useRef<IncrementalMarkdownParser | null>(null)
  if (parserRef.current === null) parserRef.current = new IncrementalMarkdownParser()
  const blocks = parserRef.current.parse(text, streaming)
  return <div className="chat-md"><Blocks nodes={blocks} /></div>
})
