import React, { useEffect, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { Editor, defaultValueCtx, editorViewCtx, rootCtx, serializerCtx } from '@milkdown/core'
import { commonmark, createCodeBlockCommand, toggleEmphasisCommand, toggleStrongCommand, wrapInBlockquoteCommand, wrapInBulletListCommand, wrapInHeadingCommand } from '@milkdown/preset-commonmark'
import { gfm, insertTableCommand, toggleStrikethroughCommand } from '@milkdown/preset-gfm'
import { history, undoCommand, redoCommand } from '@milkdown/plugin-history'
import { Plugin } from '@milkdown/prose/state'
import { $prose, callCommand, replaceAll } from '@milkdown/utils'
import { isEditorDocument, send, type EditorDocument } from './bridge'
import './styles.css'

function App() {
  const container = useRef<HTMLDivElement>(null)
  const editor = useRef<Editor | null>(null)
  const document = useRef<EditorDocument | null>(null)
  const applying = useRef(false)
  const lastMarkdown = useRef('')
  const [status, setStatus] = useState('필기를 불러오는 중…')
  const [ready, setReady] = useState(false)
  const [error, setError] = useState('')
  const [selectedLink, setSelectedLink] = useState<string | null>(null)

  useEffect(() => {
    let disposed = false
    let pending: EditorDocument | null = null
    let changeSequence = 0
    const load = (value: EditorDocument) => {
      if (!isEditorDocument(value)) throw new Error('잘못된 필기 문서입니다.')
      if (!editor.current) { pending = value; return }
      if (document.current?.materialID === value.materialID && lastMarkdown.current === value.markdown) return
      document.current = value
      setSelectedLink(null)
      lastMarkdown.current = value.markdown
      applying.current = true
      try { editor.current.action(replaceAll(value.markdown, true)) }
      finally { applying.current = false }
      setStatus('자동 저장')
      setError('')
    }
    window.bandalEditor = { load, getMarkdown: () => lastMarkdown.current }
    const reportChange = $prose(ctx => new Plugin({
      props: {
        handleDOMEvents: {
          // Editing a linked word first reveals a separate, user-activated link.
          // WK cancels that navigation and opens it in the appropriate app tab.
          click: (view, event) => {
            const anchor = (event.target as Element | null)?.closest('a')
            if (anchor) {
              event.preventDefault()
              try {
                // CommonMark deliberately neutralizes custom schemes in DOM
                // hrefs. Read the original mark and allow only our material route.
                const position = view.posAtDOM(anchor, 0)
                const mark = view.state.doc.nodeAt(position)?.marks.find(mark => mark.type.name === 'link')
                const href = mark?.attrs.href ?? anchor.getAttribute('href')
                if (!href) { setSelectedLink(null); return true }
                const url = new URL(href, window.location.href)
                setSelectedLink(['http:', 'https:'].includes(url.protocol) || (url.protocol === 'bandal:' && url.hostname === 'material') ? url.href : null)
              } catch { setSelectedLink(null) }
              return true
            }
            setSelectedLink(null)
            return false
          }
        }
      },
      view: () => ({
        update: (view, previous) => {
          if (disposed || applying.current || !document.current || previous.doc.eq(view.state.doc)) return
          const markdown = ctx.get(serializerCtx)(view.state.doc)
          if (markdown === lastMarkdown.current) return
          lastMarkdown.current = markdown
          const sequence = ++changeSequence
          setStatus('반영 중…')
          // No debounce: closing a tab immediately after typing cannot lose a
          // pending edit. The native repository controls durable write batching.
          void send({ version: 1, type: 'change', materialID: document.current.materialID, markdown })
            .then(connected => { if (!disposed && sequence === changeSequence) { setStatus(connected ? '자동 저장' : '미리보기 · 저장되지 않음'); setError('') } })
            .catch((cause: unknown) => {
              if (!disposed && sequence === changeSequence) {
                setStatus('저장 확인 필요')
                setError(cause instanceof Error && cause.message.includes('저장 한도') ? cause.message : '변경 내용을 앱에 전달하지 못했어요. 이 탭을 닫지 말고 내용을 복사해 주세요.')
              }
            })
        }
      })
    }))
    const instance = Editor.make().config(ctx => {
      ctx.set(rootCtx, container.current!)
      ctx.set(defaultValueCtx, '')
    }).use(commonmark).use(gfm).use(history).use(reportChange)
    void instance.create().then(() => {
      if (disposed) { void instance.destroy(); return }
      editor.current = instance
      setReady(true)
      if (pending) load(pending)
      void send({ version: 1, type: 'ready' }).then(connected => {
        if (!connected && !disposed && !pending) {
          load({ version: 1, materialID: 'preview', markdown: '# 반달 필기\n\n내용을 선택해서 서식을 바꾸거나 바로 입력하세요.\n\n- [ ] 오늘의 학습 정리\n' })
          setStatus('미리보기 · 저장되지 않음')
        }
      }).catch(() => setError('앱과 연결하지 못했어요.'))
    }).catch((cause: unknown) => {
      if (disposed) return
      setStatus('편집기를 열 수 없음')
      setError(cause instanceof Error ? cause.message : '편집기를 불러오지 못했어요.')
      void send({ version: 1, type: 'error' }).catch(() => {})
    })
    return () => { disposed = true; editor.current = null; void instance.destroy() }
  }, [])

  const run = (command: Parameters<Editor['action']>[0]) => {
    editor.current?.action(command)
    editor.current?.action(ctx => ctx.get(editorViewCtx).focus())
  }
  const actions = [
    { label: '실행 취소', text: '↶', command: callCommand(undoCommand.key) },
    { label: '다시 실행', text: '↷', command: callCommand(redoCommand.key) },
    { label: '제목', text: 'H1', command: callCommand(wrapInHeadingCommand.key, 1) },
    { label: '소제목', text: 'H2', command: callCommand(wrapInHeadingCommand.key, 2) },
    { label: '굵게', text: 'B', command: callCommand(toggleStrongCommand.key) },
    { label: '기울임', text: 'I', command: callCommand(toggleEmphasisCommand.key) },
    { label: '취소선', text: 'S̶', command: callCommand(toggleStrikethroughCommand.key) },
    { label: '목록', text: '≡', command: callCommand(wrapInBulletListCommand.key) },
    { label: '인용', text: '❝', command: callCommand(wrapInBlockquoteCommand.key) },
    { label: '코드 블록', text: '</>', command: callCommand(createCodeBlockCommand.key) },
    { label: '표 삽입', text: '▦', command: callCommand(insertTableCommand.key, { row: 3, col: 3 }) }
  ]
  return <main>
    <div className="toolbar" role="toolbar" aria-label="필기 서식">
      {actions.map(action => <button key={action.label} type="button" aria-label={action.label} title={action.label} disabled={!ready}
        onPointerDown={event => event.preventDefault()} onClick={() => run(action.command)}>{action.text}</button>)}
    </div>
    {selectedLink && <div className="document-status" role="group" aria-label="선택한 링크">
      <a href={selectedLink} style={{ display: 'inline-flex', minHeight: 44, alignItems: 'center' }}>링크 열기</a>
      <button type="button" onClick={() => setSelectedLink(null)} style={{ marginLeft: 16, minHeight: 44 }}>닫기</button>
    </div>}
    <div className="document-status" role="status">{status}</div>
    {error && <div className="error" role="alert">{error}</div>}
    <div ref={container} className="editor" aria-label="마크다운 필기" />
  </main>
}

createRoot(document.getElementById('root')!).render(<App />)
