export interface QuizMarkdownSections {
  questionMarkdown: string
  answerMarkdown: string
  answerHeading: string
}

const ANSWER_HEADING = /^정답(?:\s*(?:과|및|&|·)\s*해설)?$/
const FENCE = /^ {0,3}(`{3,}|~{3,})/
const ATX_HEADING = /^ {0,3}(#{1,6})[\t ]+(.+?)[\t ]*$/

function headingText(line: string): string | null {
  const match = ATX_HEADING.exec(line)
  if (match === null) return null

  // A closing ATX marker is only syntax when whitespace separates it from
  // the title. This keeps a literal title such as "정답#" intact.
  return (match[2] ?? '').replace(/[\t ]+#+[\t ]*$/, '').trim()
}

/**
 * Finds the answer section produced by the AI quiz recipe without changing
 * any byte of the source markdown. Headings inside fenced code blocks are
 * deliberately ignored.
 */
export function splitQuizMarkdown(markdown: string): QuizMarkdownSections | null {
  let offset = 0
  let fence: { marker: '`' | '~'; length: number } | null = null

  for (const lineWithEnding of markdown.matchAll(/.*(?:\r\n|\n|$)/g)) {
    const rawLine = lineWithEnding[0]
    if (rawLine.length === 0) break
    const line = rawLine.replace(/\r?\n$/, '')
    const fenceMatch = FENCE.exec(line)

    if (fence !== null) {
      if (fenceMatch !== null) {
        const run = fenceMatch[1] ?? ''
        if (run[0] === fence.marker && run.length >= fence.length) fence = null
      }
      offset += rawLine.length
      continue
    }

    if (fenceMatch !== null) {
      const run = fenceMatch[1] ?? ''
      fence = { marker: run[0] as '`' | '~', length: run.length }
      offset += rawLine.length
      continue
    }

    const title = headingText(line)
    if (title !== null && ANSWER_HEADING.test(title)) {
      return {
        questionMarkdown: markdown.slice(0, offset),
        answerMarkdown: markdown.slice(offset),
        answerHeading: title
      }
    }

    offset += rawLine.length
  }

  return null
}
