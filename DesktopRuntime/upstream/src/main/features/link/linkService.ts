import { basename } from 'node:path'
import type {
  SendHighlightToNoteInput,
  SendHighlightToNoteResult,
  SendWebClipToNoteInput
} from '../../../shared/types/link'
import type { NoteContent } from '../../../shared/types/note'
import { ConflictError, NotFoundError, ValidationError } from '../../db/errors'
import type { NotesRepo } from '../notes'
import { createMaterialLink, parseMaterialLink } from './materialLink'

export interface LinkServiceDeps {
  notes: Pick<NotesRepo, 'read' | 'write' | 'create'>
  getCourseFolder: (courseId: string) => string
}

export interface LinkService {
  sendWebClipToNote(
    input: SendWebClipToNoteInput
  ): SendHighlightToNoteResult
  sendHighlightToNote(
    input: SendHighlightToNoteInput
  ): SendHighlightToNoteResult
}

const LINK_URL_PATTERN = /bandal:\/\/material\/?\?[^\s)>]+/g
const LINK_LABEL_QUOTE_LIMIT = 80

function safeNoteTitle(title: string): string {
  const safe = title
    .trim()
    .replace(/[/\\:*?"<>|]/g, '')
    .replace(/\s+/g, ' ')
    .replace(/^\.+/, '')
    .slice(0, 120)
    .trim()
  return safe.length > 0 ? safe : '학습노트'
}

/** Pure default-title rule; exported so the filename rule stays assertable. */
export function defaultStudyNoteTitle(courseFolder: string): string {
  const folderName = basename(courseFolder).trim()
  const courseName = folderName.length > 0 ? folderName : '과목'
  return safeNoteTitle(`${courseName} 학습노트`)
}

function quoteLabel(quote: string): string {
  const oneLine = quote.replace(/\s+/g, ' ').trim()
  const shortened =
    oneLine.length <= LINK_LABEL_QUOTE_LIMIT
      ? oneLine
      : `${oneLine.slice(0, LINK_LABEL_QUOTE_LIMIT - 1).trimEnd()}…`
  return shortened.replace(/([\\\[\]])/g, '\\$1')
}

/** Pure markdown rendering for one appended highlight entry. */
export function highlightMarkdown(input: SendHighlightToNoteInput): string {
  const href = createMaterialLink({
    relPath: input.relPath,
    page: input.page,
    annotationId: input.annotationId
  })
  const quote = input.quote
    .replace(/\r\n?/g, '\n')
    .trim()
    .split('\n')
    .map((line) => (line.length > 0 ? `> ${line}` : '>'))
    .join('\n')
  const comment = input.comment?.trim() ?? ''
  const source = `[${input.page}쪽 "${quoteLabel(input.quote)}"](${href})`
  return [quote, comment, source].filter((part) => part.length > 0).join('\n\n')
}

/**
 * Renders a web clip. The source is a plain markdown link, so the note keeps
 * working outside Bandal — unlike a `bandal://material?…` href, an https URL
 * resolves for anyone.
 */
export function webClipMarkdown(input: SendWebClipToNoteInput): string {
  const quote = input.quote
    .replace(/\r\n?/g, '\n')
    .trim()
    .split('\n')
    .map((line) => (line.length > 0 ? `> ${line}` : '>'))
    .join('\n')
  const comment = input.comment?.trim() ?? ''
  const label = input.title.trim() === '' ? hostLabel(input.url) : input.title.trim()
  const source = `[${label}](${input.url})`
  return [quote, comment, source].filter((part) => part.length > 0).join('\n\n')
}

function hostLabel(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./i, '')
  } catch {
    return url
  }
}

/** Pure duplicate check based on the annotation id embedded in link URLs. */
export function hasAnnotationLink(
  markdown: string,
  annotationId: string
): boolean {
  for (const match of markdown.matchAll(LINK_URL_PATTERN)) {
    const parsed = parseMaterialLink(match[0])
    if (parsed?.annotationId === annotationId) return true
  }
  return false
}

/** Pure append operation which preserves every existing byte as a prefix. */
export function appendMarkdown(markdown: string, block: string): string {
  if (markdown.length === 0) return `${block}\n`
  const separator = markdown.endsWith('\n\n')
    ? ''
    : markdown.endsWith('\n')
      ? '\n'
      : '\n\n'
  return `${markdown}${separator}${block}\n`
}

function validateWebClip(input: SendWebClipToNoteInput): void {
  for (const [field, value] of [
    ['courseId', input.courseId],
    ['url', input.url],
    ['quote', input.quote]
  ] as const) {
    if (typeof value !== 'string' || value.trim().length === 0) {
      throw new ValidationError(`${field} must be a non-empty string`)
    }
  }
  // A clip must be a real page, not a local file or a script URL smuggled in
  // from a hostile page's selection API.
  let protocol: string
  try {
    protocol = new URL(input.url).protocol
  } catch {
    throw new ValidationError('url must be absolute')
  }
  if (protocol !== 'http:' && protocol !== 'https:') {
    throw new ValidationError('url must be http(s)')
  }
}

function validateInput(input: SendHighlightToNoteInput): void {
  if (!Number.isSafeInteger(input.page) || input.page < 1) {
    throw new ValidationError('page must be a positive integer')
  }
  if (typeof input.relPath !== 'string' || input.relPath.length === 0) {
    throw new ValidationError('relPath must be a non-empty string')
  }
  if (typeof input.quote !== 'string' || input.quote.trim().length === 0) {
    throw new ValidationError('quote must be a non-empty string')
  }
  if (
    typeof input.annotationId !== 'string' ||
    input.annotationId.trim().length === 0
  ) {
    throw new ValidationError('annotationId must be a non-empty string')
  }
  if (input.comment !== null && typeof input.comment !== 'string') {
    throw new ValidationError('comment must be a string or null')
  }
}

export function createLinkService(deps: LinkServiceDeps): LinkService {
  function defaultNote(courseId: string): {
    note: NoteContent
    created: boolean
  } {
    const title = defaultStudyNoteTitle(deps.getCourseFolder(courseId))
    const expectedRelPath = `${title}.md`
    try {
      return {
        note: deps.notes.read({ courseId, relPath: expectedRelPath }),
        created: false
      }
    } catch (error) {
      if (!(error instanceof NotFoundError)) throw error
    }

    // create() owns sanitizing and the numeric suffix collision rule. The
    // second read also gives us the mtime used for a non-destructive write.
    const createdRef = deps.notes.create({ courseId, dirRelPath: '', title })
    return { note: deps.notes.read(createdRef), created: true }
  }

  return {
    sendWebClipToNote(input) {
      validateWebClip(input)
      const { courseId, url, quote } = input
      const target =
        input.noteRelPath === undefined
          ? defaultNote(courseId)
          : {
              note: deps.notes.read({
                courseId,
                relPath: input.noteRelPath
              }),
              created: false
            }

      const block = webClipMarkdown({ ...input, courseId, url, quote })
      // Same quote from the same page twice is almost always a double-click,
      // not a second thought.
      if (target.note.markdown.includes(block)) {
        return { relPath: target.note.relPath, created: target.created }
      }

      try {
        deps.notes.write({
          courseId,
          relPath: target.note.relPath,
          markdown: appendMarkdown(target.note.markdown, block),
          expectedMtime: target.note.mtime
        })
      } catch (error) {
        if (!(error instanceof ConflictError)) throw error

        // One concurrent edit is recoverable: rebase the clip on the latest
        // note body and make one final optimistic write. A second conflict is
        // deliberately allowed to propagate to the caller.
        const latest = deps.notes.read({
          courseId,
          relPath: target.note.relPath
        })
        if (!latest.markdown.includes(block)) {
          deps.notes.write({
            courseId,
            relPath: latest.relPath,
            markdown: appendMarkdown(latest.markdown, block),
            expectedMtime: latest.mtime
          })
        }
      }
      return { relPath: target.note.relPath, created: target.created }
    },

    sendHighlightToNote(input) {
      validateInput(input)
      const target =
        input.noteRelPath === undefined
          ? defaultNote(input.courseId)
          : {
              note: deps.notes.read({
                courseId: input.courseId,
                relPath: input.noteRelPath
              }),
              created: false
            }

      if (hasAnnotationLink(target.note.markdown, input.annotationId)) {
        return { relPath: target.note.relPath, created: target.created }
      }

      deps.notes.write({
        courseId: input.courseId,
        relPath: target.note.relPath,
        markdown: appendMarkdown(target.note.markdown, highlightMarkdown(input)),
        expectedMtime: target.note.mtime
      })
      return { relPath: target.note.relPath, created: target.created }
    }
  }
}
