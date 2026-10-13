import { replaceNoteTitle } from '../../../shared/noteTitle'
/**
 * Notes repository. Notes are plain .md files inside the course folder; the
 * production rename delegates to the material journal for filesystem/DB recovery.
 * Every relPath goes through the path-traversal guard.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, statSync } from 'node:fs'
import { dirname, extname, join } from 'node:path'
import { posix } from 'node:path'
import type {
  CreateNoteInput,
  NoteContent,
  NoteRef,
  WriteNoteInput
} from '../../../shared/types/note'
import { ConflictError, NotFoundError, ValidationError } from '../../db/errors'
import {
  assertRealInside,
  requireId,
  requireNonEmptyString,
  resolveInside,
  resolveInsideReal
} from '../../db/validate'
import { writeFileAtomic } from '../../lib/atomicWrite'
import { retryWindowsFileOperation } from '../../lib/retryWindowsFileOperation'

export interface NotesRepo {
  read(input: NoteRef): NoteContent
  write(input: WriteNoteInput): { mtime: number }
  create(input: CreateNoteInput): NoteRef
  /**
   * 제목과 파일명을 한 트랜잭션으로 맞춘다: 제목을 정리(sanitize)하고,
   * 충돌은 -2/-3 접미로 풀고, 파일명을 바꾼 뒤 문서의 첫 H1을 최종
   * 이름으로 원자적으로 고쳐 쓴다. 앱에서는 H1·링크·원본 본문을 먼저
   * 복구 기록에 저장하며, 종료/실패 후 새 경로에서 이어 완료한다.
   */
  rename(input: { courseId: string; relPath: string; newName: string }): Promise<{
    relPath: string
    mtime: number
    title: string
    markdown: string
  }>
}

export interface NotesRepoDeps {
  /** Absolute course folder for a live course id (throws otherwise). */
  getCourseFolder: (courseId: string) => string
  onPathChanged?: (change: { courseId: string; fromRelPath: string; toRelPath: string; isDirectory: false }) => void
  onCreated?: (note: NoteRef) => void
  /** Production delegates to the material journal; file-only embedders may omit it. */
  renameWithMarkdown?: (input: { courseId: string; fromRelPath: string; toRelPath: string; before: string; after: string }) => Promise<void>
  assertPathAvailable?: (courseId: string, relPath?: string) => void
}

/** Strips path separators and other filesystem-hostile chars from a title. */
function sanitizeTitle(title: string): string {
  const cleaned = title
    .trim()
    .replace(/[/\\:*?"<>|]/g, '')
    .replace(/\s+/g, ' ')
    .replace(/^\.+/, '')
    .slice(0, 120)
    .trim()
  if (cleaned.length === 0) {
    throw new ValidationError('title has no filesystem-safe characters')
  }
  return cleaned
}

function assertMarkdownPath(relPath: string): void {
  if (extname(relPath).toLowerCase() !== '.md') {
    throw new ValidationError(`notes must be .md files (got "${relPath}")`)
  }
}

/** IPC keeps a number token, but preserves the filesystem's sub-ms precision. */
function mtimeToken(abs: string): number {
  return Number(statSync(abs, { bigint: true }).mtimeNs) / 1e6
}

export function createNotesRepo(deps: NotesRepoDeps): NotesRepo {
  const { getCourseFolder } = deps

  function notifyPathChanged(courseId: string, fromRelPath: string, toRelPath: string): boolean {
    if (deps.onPathChanged === undefined) return false
    try {
      deps.onPathChanged({ courseId, fromRelPath, toRelPath, isDirectory: false })
      return true
    } catch (error) {
      console.warn(`[notes] path-change hook failed for "${fromRelPath}" -> "${toRelPath}"`, error)
      return false
    }
  }

  /**
   * The course folder is an arbitrary path that may be gone (moved, deleted,
   * unmounted). Refuse rather than silently re-creating it under a stale
   * path — the UI offers 다시 연결 for that case.
   */
  function requireFolder(courseId: string): string {
    const folder = getCourseFolder(courseId)
    if (!existsSync(folder)) {
      throw new NotFoundError('course folder', folder)
    }
    return folder
  }

  function resolveNote(
    courseId: string,
    relPath: string
  ): { abs: string; folder: string } {
    const id = requireId(courseId, 'courseId')
    const folder = requireFolder(id)
    const rel = requireNonEmptyString(relPath, 'relPath')
    assertMarkdownPath(rel)
    deps.assertPathAvailable?.(id, rel)
    return { abs: resolveInsideReal(folder, rel), folder }
  }

  return {
    read(input) {
      const { abs } = resolveNote(input.courseId, input.relPath)
      if (!existsSync(abs) || !statSync(abs).isFile()) {
        throw new NotFoundError('note', input.relPath)
      }
      const markdown = readFileSync(abs, 'utf8')
      const mtime = mtimeToken(abs)
      return { courseId: input.courseId, relPath: input.relPath, markdown, mtime }
    },

    write(input) {
      const { abs, folder } = resolveNote(input.courseId, input.relPath)
      if (typeof input.markdown !== 'string') {
        throw new ValidationError('markdown must be a string')
      }
      if (input.expectedMtime !== undefined && existsSync(abs)) {
        const currentMtime = mtimeToken(abs)
        if (currentMtime !== input.expectedMtime) {
          throw new ConflictError(
            `"${input.relPath}" changed on disk (expected mtime ${input.expectedMtime}, found ${currentMtime})`
          )
        }
      }
      const parent = dirname(abs)
      assertRealInside(folder, parent)
      mkdirSync(parent, { recursive: true })
      assertRealInside(folder, abs)
      const existed = existsSync(abs)
      writeFileAtomic(abs, input.markdown)
      if (!existed) deps.onCreated?.({ courseId: input.courseId, relPath: input.relPath })
      return { mtime: mtimeToken(abs) }
    },

    create(input) {
      const id = requireId(input.courseId, 'courseId')
      const folder = requireFolder(id)
      if (typeof input.dirRelPath !== 'string') {
        throw new ValidationError('dirRelPath must be a string')
      }
      deps.assertPathAvailable?.(id)
      const dirAbs = resolveInside(folder, input.dirRelPath, { allowRoot: true })
      const title = sanitizeTitle(requireNonEmptyString(input.title, 'title'))

      assertRealInside(folder, dirAbs)
      mkdirSync(dirAbs, { recursive: true })
      let fileName = `${title}.md`
      for (let n = 2; existsSync(join(dirAbs, fileName)); n += 1) {
        if (n > 1000) {
          throw new ValidationError(`could not find a free name for "${title}"`)
        }
        fileName = `${title}-${n}.md`
      }
      const abs = join(dirAbs, fileName)
      assertRealInside(folder, abs)
      writeFileAtomic(abs, `# ${title}\n`)

      const relPath =
        input.dirRelPath === '' ? fileName : posix.join(input.dirRelPath, fileName)
      deps.onCreated?.({ courseId: id, relPath })
      return { courseId: id, relPath }
    },

    async rename(input) {
      const { abs, folder } = resolveNote(input.courseId, input.relPath)
      if (!existsSync(abs)) throw new NotFoundError('note', input.relPath)
      if (deps.renameWithMarkdown) {
        const stem = sanitizeTitle(requireNonEmptyString(input.newName, 'newName').replace(/\.md$/iu, ''))
        const directory = dirname(abs)
        let fileName = `${stem}.md`
        for (let suffix = 2; existsSync(join(directory, fileName)) && join(directory, fileName) !== abs; suffix++) {
          if (suffix > 1000) throw new ValidationError(`could not find a free name for "${stem}"`)
          fileName = `${stem}-${suffix}.md`
        }
        const title = fileName.replace(/\.md$/u, ''), parent = posix.dirname(input.relPath)
        const relPath = parent === '.' ? fileName : posix.join(parent, fileName), before = readFileSync(abs, 'utf8')
        await deps.renameWithMarkdown({ courseId: input.courseId, fromRelPath: input.relPath, toRelPath: relPath, before, after: replaceNoteTitle(before, title) })
        const finalPath = resolveInsideReal(requireFolder(input.courseId), relPath)
        return { relPath, mtime: mtimeToken(finalPath), title, markdown: readFileSync(finalPath, 'utf8') }
      }
      const originalIdentity = statSync(abs, { bigint: true })
      let committed = false
      // Keep filename + H1 replacement synchronous as one transaction. When a
      // Windows lock rejects its atomic write, restore the original filename
      // before yielding so main-thread callers see a consistent note.
      return retryWindowsFileOperation(() => {
        if (getCourseFolder(input.courseId) !== folder) {
          throw new ValidationError('과목 폴더가 변경되었습니다. 자료 목록을 새로고침하고 다시 시도하세요.')
        }
        assertRealInside(folder, abs)
        if (!existsSync(abs)) {
          throw new NotFoundError('note', input.relPath)
        }
        const current = statSync(abs, { bigint: true })
        if (current.dev !== originalIdentity.dev || current.ino !== originalIdentity.ino ||
            current.mtimeNs !== originalIdentity.mtimeNs || current.size !== originalIdentity.size) {
          throw new ConflictError(`"${input.relPath}" changed on disk while waiting to rename`)
        }
        // 호출자가 .md 를 붙여 보내도 관대하게 받아 준다(사이드바 인라인
        // 편집기는 확장자까지 통째로 편집한다).
        const requested = requireNonEmptyString(input.newName, 'newName')
        const stem = sanitizeTitle(requested.replace(/\.md$/iu, ''))

        const dirAbs = dirname(abs)
        let fileName = `${stem}.md`
        for (
          let n = 2;
          existsSync(join(dirAbs, fileName)) && join(dirAbs, fileName) !== abs;
          n += 1
        ) {
          if (n > 1000) {
            throw new ValidationError(`could not find a free name for "${stem}"`)
          }
          fileName = `${stem}-${n}.md`
        }
        const finalStem = fileName.replace(/\.md$/u, '')

        // 새 파일명에 맞출 H1 내용을 먼저 계산하되, 파일명 변경 전에는
        // 원본을 건드리지 않는다.
        const original = readFileSync(abs, 'utf8')
        const updated = replaceNoteTitle(original, finalStem)
        const nextAbs = join(dirAbs, fileName)
        let renamed = false
        if (nextAbs !== abs) {
          assertRealInside(folder, abs)
          assertRealInside(folder, nextAbs)
          renameSync(abs, nextAbs)
          renamed = true
        }

        try {
          if (updated !== original) {
            assertRealInside(folder, nextAbs)
            writeFileAtomic(nextAbs, updated, { retryWindowsLocks: false })
          }
        } catch (error) {
          if (renamed) {
            try {
              assertRealInside(folder, nextAbs)
              assertRealInside(folder, abs)
              renameSync(nextAbs, abs)
            } catch (rollbackError) {
              throw new AggregateError(
                [error, rollbackError],
                `failed to update the note heading and restore "${input.relPath}"`
              )
            }
          }
          throw error
        }
        const dirRel = posix.dirname(input.relPath)
        const relPath =
          dirRel === '.' ? fileName : posix.join(dirRel, fileName)
        committed = true
        const hookCompleted = renamed && notifyPathChanged(
          requireId(input.courseId, 'courseId'),
          input.relPath,
          relPath
        )
        // A successful repoint hook may atomically rewrite links in this same
        // note. Return the bytes now on disk so the renderer cannot immediately
        // save the pre-repoint body back over them.
        const finalMarkdown = hookCompleted ? readFileSync(nextAbs, 'utf8') : updated
        return {
          relPath,
          mtime: mtimeToken(nextAbs),
          title: finalStem,
          markdown: finalMarkdown
        }
      }, {
        // A failed rollback is an AggregateError, never a retryable filesystem
        // error. Once committed, hook/read errors must not replay the rename.
        shouldRetry: () => !committed
      })
    }
  }
}
