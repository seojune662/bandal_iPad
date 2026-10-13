import {
  Editor,
  defaultValueCtx,
  editorViewOptionsCtx,
  nodeViewCtx,
  rootAttrsCtx,
  rootCtx
} from '@milkdown/core'
import type { MilkdownPlugin } from '@milkdown/ctx'
import { commonmark } from '@milkdown/preset-commonmark'
import { gfm } from '@milkdown/preset-gfm'
import { Milkdown, MilkdownProvider, useEditor } from '@milkdown/react'
import { useEffect, useState } from 'react'
import { loadNotePrismPlugins } from './noteEditorPlugins'
import { createNoteImageView } from './noteImagePlugin'
import type { QuizMarkdownSections } from './quizMarkdown'

function ReadonlyMarkdown({
  courseId,
  markdown,
  label
}: {
  courseId: string
  markdown: string
  label: string
}): JSX.Element {
  const [prismPlugins, setPrismPlugins] = useState<MilkdownPlugin[] | null>(
    null
  )

  useEffect(() => {
    let active = true
    void loadNotePrismPlugins()
      .then((plugins) => {
        if (active) setPrismPlugins(plugins)
      })
      .catch((error: unknown) => {
        console.error('[Bandal] 코드 하이라이터를 불러오지 못했습니다.', error)
        if (active) setPrismPlugins([])
      })
    return () => {
      active = false
    }
  }, [])

  const { loading } = useEditor(
    (root) => {
      if (prismPlugins === null) return undefined
      const editor = Editor.make().config((context) => {
        context.set(rootCtx, root)
        context.set(defaultValueCtx, markdown)
        context.set(rootAttrsCtx, { 'aria-label': label })
        context.update(nodeViewCtx, (views) => [
          ...views.filter(([name]) => name !== 'image'),
          ['image', createNoteImageView(courseId)] as [
            string,
            ReturnType<typeof createNoteImageView>
          ]
        ])
        context.set(editorViewOptionsCtx, {
          editable: () => false,
          attributes: {
            'aria-label': label,
            'aria-readonly': 'true'
          }
        })
      })

      return prismPlugins.reduce(
        (instance, plugin) => instance.use(plugin),
        editor.use(commonmark).use(gfm)
      )
    },
    [courseId, label, markdown, prismPlugins]
  )

  return (
    <div className="note-quiz-markdown" aria-busy={loading}>
      {loading && <div className="note-editor-loading">미리보기 준비 중…</div>}
      <Milkdown />
    </div>
  )
}

export function QuizPreview({
  courseId,
  sections
}: {
  courseId: string
  sections: QuizMarkdownSections
}): JSX.Element {
  const [answersRevealed, setAnswersRevealed] = useState(false)

  useEffect(() => {
    setAnswersRevealed(false)
  }, [sections.answerMarkdown])

  return (
    <div className="note-quiz-preview">
      <div className="note-quiz-preview__banner" role="status">
        <div>
          <strong>퀴즈 풀이 모드</strong>
          <span>
            {answersRevealed
              ? '정답과 해설을 확인하고 있습니다.'
              : '정답과 해설은 풀이 후까지 숨겨집니다.'}
          </span>
        </div>
        {answersRevealed && (
          <button
            type="button"
            className="note-action"
            onClick={() => setAnswersRevealed(false)}
          >
            정답 다시 숨기기
          </button>
        )}
      </div>

      <div className="note-quiz-preview__scroll">
        <MilkdownProvider>
          <ReadonlyMarkdown
            courseId={courseId}
            markdown={sections.questionMarkdown}
            label="퀴즈 문제"
          />
        </MilkdownProvider>

        {answersRevealed ? (
          <section className="note-quiz-preview__answers" aria-label="퀴즈 정답과 해설">
            <MilkdownProvider>
              <ReadonlyMarkdown
                courseId={courseId}
                markdown={sections.answerMarkdown}
                label="퀴즈 정답과 해설"
              />
            </MilkdownProvider>
          </section>
        ) : (
          <section className="note-quiz-preview__gate" aria-label="숨긴 정답과 해설">
            <div>
              <strong>정답과 해설</strong>
              <span>문제를 다 풀었다면 표시하세요.</span>
            </div>
            <button
              type="button"
              className="note-action note-action--primary"
              onClick={() => setAnswersRevealed(true)}
            >
              정답과 해설 보기
            </button>
          </section>
        )}
      </div>
    </div>
  )
}
