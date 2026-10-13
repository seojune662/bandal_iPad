import { posix } from 'node:path'
import { ValidationError } from '../../../db/errors'
import { backupMaterial, materialEditTargetId } from '../documentBackup'
import {
  applySheetEdits,
  parseDocxReplacements,
  parseSheetEditRequest,
  prepareDocxTextEdit,
  type DocxReplaceScope
} from '../documentEdit'
import {
  cancelled,
  optionalInteger,
  optionalString,
  stringField,
  type ToolContext,
  type ToolHandlerMap
} from './context'

export function noteTools(ctx: ToolContext) {
  const {
    deps,
    currentTurn,
    reserve,
    release,
    approve,
    record,
    courseFolder,
    assertCoursePath,
    assertChildPath
  } = ctx

  return {
    create_note(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const dirRelPath = stringField(input, 'dirRelPath')
      const title = stringField(input, 'title', { nonEmpty: true })
      const markdown = optionalString(input, 'markdown')
      assertCoursePath(courseId, dirRelPath, true)
      assertChildPath(courseId, dirRelPath, `${title}.md`)

      reserve('files', 1)
      let note
      try {
        note = deps.notesRepo.create({ courseId, dirRelPath, title })
        if (markdown !== undefined) {
          deps.notesRepo.write({ ...note, markdown })
        }
      } catch (error) {
        release('files', 1)
        throw error
      }
      record(context, courseId, 'create_note', 'note', note.relPath, `필기 «${note.relPath}»`, true)
      return note
    },

    async overwrite_note(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const relPath = stringField(input, 'relPath', { nonEmpty: true })
      const markdown = stringField(input, 'markdown')
      const requestedMtime = optionalInteger(input, 'expectedMtime', 0)
      assertCoursePath(courseId, relPath)
      const before = deps.notesRepo.read({ courseId, relPath })
      if (!await approve(
        context,
        'overwrite_note',
        `필기 «${relPath}»의 전체 내용을 덮어씁니다.`,
        [relPath, `${Buffer.byteLength(markdown, 'utf8')} bytes`]
      )) return cancelled('overwrite_note')
      const result = deps.notesRepo.write({
        courseId,
        relPath,
        markdown,
        expectedMtime: requestedMtime ?? before.mtime
      })
      record(context, courseId, 'overwrite_note', 'note', relPath, `필기 «${relPath}»`, false)
      return { courseId, relPath, ...result }
    },

    async edit_sheet(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const relPath = stringField(input, 'relPath', { nonEmpty: true })
      const sheetName = optionalString(input, 'sheet')
      const request = parseSheetEditRequest(input)
      const ext = posix.extname(relPath).toLowerCase()
      if (ext === '.xls') {
        throw new ValidationError(
          '.xls 는 편집할 수 없습니다 — 이 도구는 .xlsx 형식만 저장할 수 있습니다. 먼저 .xlsx 로 변환해 주세요.'
        )
      }
      if (ext !== '.xlsx') {
        throw new ValidationError('edit_sheet 는 .xlsx 파일만 편집합니다')
      }
      const absPath = assertCoursePath(courseId, relPath)

      const parts: string[] = []
      if (request.edits.length > 0) parts.push(`셀 ${request.edits.length}개 수정`)
      if (request.appendRows.length > 0) parts.push(`행 ${request.appendRows.length}개 추가`)
      if (!await approve(
        context,
        'edit_sheet',
        `스프레드시트 «${relPath}»에서 ${parts.join(', ')}을(를) 합니다.`,
        [relPath, sheetName === undefined ? '첫 번째 시트' : `시트 «${sheetName}»`, ...parts]
      )) return cancelled('edit_sheet')

      // 확인 뒤·쓰기 전 백업. 이후 실패해도 원본은 백업에 남는다.
      const backup = backupMaterial(courseFolder(courseId), absPath)
      const result = await applySheetEdits({ absPath, sheetName, request })
      record(
        context,
        courseId,
        'edit_sheet',
        'material-edit',
        materialEditTargetId(relPath, backup.backupAbs),
        `자료 «${relPath}» 편집`,
        true
      )
      return { relPath, ...result, backup: backup.backupName }
    },

    async edit_docx_text(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const relPath = stringField(input, 'relPath', { nonEmpty: true })
      const scope = (optionalString(input, 'scope') ?? 'all') as DocxReplaceScope
      if (scope !== 'first' && scope !== 'all') {
        throw new ValidationError('scope must be "first" or "all"')
      }
      const replacements = parseDocxReplacements(input)
      if (posix.extname(relPath).toLowerCase() !== '.docx') {
        throw new ValidationError('edit_docx_text 는 .docx 파일만 편집합니다')
      }
      const absPath = assertCoursePath(courseId, relPath)

      // 먼저 결과를 계산만 한다 — 일치가 0이면 확인·백업·쓰기 모두 생략.
      const prepared = await prepareDocxTextEdit({ absPath, replacements, scope })
      if (prepared.total === 0) {
        return {
          relPath,
          replaced: prepared.replaced,
          totalReplacements: 0,
          message:
            '일치하는 텍스트가 없어 아무것도 바꾸지 않았습니다. 문구가 run 중간에서 서식이 바뀌면 매칭되지 않으니, read_material 로 정확한 문구를 확인해 보세요.'
        }
      }
      if (!await approve(
        context,
        'edit_docx_text',
        `문서 «${relPath}»에서 텍스트 ${prepared.total}곳을 바꿉니다.`,
        [
          relPath,
          ...prepared.replaced
            .filter((item) => item.count > 0)
            .map((item) => `«${item.find}» ${item.count}곳`)
        ]
      )) return cancelled('edit_docx_text')

      const backup = backupMaterial(courseFolder(courseId), absPath)
      await prepared.write()
      record(
        context,
        courseId,
        'edit_docx_text',
        'material-edit',
        materialEditTargetId(relPath, backup.backupAbs),
        `자료 «${relPath}» 편집`,
        true
      )
      return {
        relPath,
        replaced: prepared.replaced,
        totalReplacements: prepared.total,
        backup: backup.backupName
      }
    }
  } satisfies Partial<ToolHandlerMap>
}
