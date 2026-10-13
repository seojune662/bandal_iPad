import { posix } from 'node:path'
import { ValidationError } from '../../../db/errors'
import {
  DEFAULT_EXTRACT_MAX_CHARS,
  extractMaterialText
} from '../../materials/textExtract'
import {
  cancelled,
  optionalInteger,
  optionalString,
  stringField,
  type ToolContext,
  type ToolHandlerMap
} from './context'

export function materialTools(ctx: ToolContext) {
  const {
    deps,
    currentTurn,
    reserve,
    release,
    approve,
    record,
    assertCoursePath,
    assertChildPath
  } = ctx

  return {
    list_materials(input) {
      return deps.materialsRepo.tree(
        stringField(input, 'courseId', { nonEmpty: true })
      )
    },

    async read_material(input) {
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const relPath = stringField(input, 'relPath', { nonEmpty: true })
      // 상한을 걸어 한 호출이 세션 문맥을 통째로 삼키지 못하게 한다.
      const maxChars = Math.min(
        optionalInteger(input, 'maxChars', 1) ?? DEFAULT_EXTRACT_MAX_CHARS,
        200_000
      )
      const absPath = assertCoursePath(courseId, relPath)
      const ext = posix.extname(relPath)
      const text = await extractMaterialText(absPath, ext, maxChars)
      if (text === null) {
        return {
          relPath,
          supported: false,
          message:
            ext.toLowerCase() === '.pdf'
              ? 'PDF 는 read_material 대신 파일을 직접 읽으세요.'
              : `지원하지 않는 형식(${ext === '' ? '확장자 없음' : ext})입니다. 텍스트, 마크다운, .docx, .xlsx/.xls 만 읽을 수 있습니다.`
        }
      }
      return { relPath, supported: true, text }
    },

    write_file(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const dirRelPath = stringField(input, 'dirRelPath')
      const fileName = stringField(input, 'fileName', { nonEmpty: true })
      const encoding = optionalString(input, 'encoding') ?? 'utf8'
      if (encoding !== 'utf8' && encoding !== 'base64') {
        throw new ValidationError('encoding must be "utf8" or "base64"')
      }
      const data = stringField(input, 'data')
      assertChildPath(courseId, dirRelPath, fileName)

      reserve('files', 1)
      let result
      try {
        result = deps.materialsRepo.writeFile({
          courseId,
          dirRelPath,
          fileName,
          encoding,
          data
        })
      } catch (error) {
        release('files', 1)
        throw error
      }
      record(context, courseId, 'write_file', 'material', result.relPath, `자료 «${result.relPath}»`, true)
      return result
    },

    create_folder(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const dirRelPath = stringField(input, 'dirRelPath')
      const name = stringField(input, 'name', { nonEmpty: true })
      assertChildPath(courseId, dirRelPath, name)

      reserve('files', 1)
      let result
      try {
        result = deps.materialsRepo.createFolder({ courseId, dirRelPath, name })
      } catch (error) {
        release('files', 1)
        throw error
      }
      record(context, courseId, 'create_folder', 'material', result.relPath, `폴더 «${result.relPath}»`, true)
      return result
    },

    async rename_material(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const relPath = stringField(input, 'relPath', { nonEmpty: true })
      const newName = stringField(input, 'newName', { nonEmpty: true })
      assertCoursePath(courseId, relPath)
      const parentRelPath = posix.dirname(relPath)
      assertChildPath(courseId, parentRelPath === '.' ? '' : parentRelPath, newName)
      if (!await approve(
        context,
        'rename_material',
        `자료 «${relPath}»의 이름을 «${newName}»(으)로 바꿉니다.`,
        [relPath, newName]
      )) return cancelled('rename_material')
      const result = await deps.materialsRepo.rename({ courseId, relPath, newName })
      record(context, courseId, 'rename_material', 'material', result.relPath, `자료 «${result.relPath}»`, false)
      return result
    },

    async delete_material(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const relPath = stringField(input, 'relPath', { nonEmpty: true })
      assertCoursePath(courseId, relPath)
      if (!await approve(
        context,
        'delete_material',
        `자료 «${relPath}»을(를) 휴지통으로 보냅니다.`,
        [relPath]
      )) return cancelled('delete_material')
      const result = await deps.materialsRepo.softDelete({ courseId, relPath })
      record(context, courseId, 'delete_material', 'material', relPath, `자료 «${relPath}»`, false)
      return result
    },

    async move_material(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const fromRelPath = stringField(input, 'fromRelPath', { nonEmpty: true })
      const toDirRelPath = stringField(input, 'toDirRelPath')
      assertCoursePath(courseId, fromRelPath)
      assertCoursePath(courseId, toDirRelPath, true)
      if (!await approve(
        context,
        'move_material',
        `자료 «${fromRelPath}»을(를) «${toDirRelPath || '과목 루트'}»로 옮깁니다.`,
        [fromRelPath, toDirRelPath || '과목 루트']
      )) return cancelled('move_material')
      const result = await deps.materialsRepo.move({ courseId, fromRelPath, toDirRelPath })
      record(context, courseId, 'move_material', 'material', result.relPath, `자료 «${result.relPath}»`, false)
      return result
    },

    duplicate_material(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const relPath = stringField(input, 'relPath', { nonEmpty: true })
      assertCoursePath(courseId, relPath)
      reserve('files', 1)
      let result
      try {
        result = deps.materialsRepo.duplicate({ courseId, relPath })
      } catch (error) {
        release('files', 1)
        throw error
      }
      record(context, courseId, 'duplicate_material', 'material', result.relPath, `자료 «${result.relPath}»`, true)
      return result
    }
  } satisfies Partial<ToolHandlerMap>
}
