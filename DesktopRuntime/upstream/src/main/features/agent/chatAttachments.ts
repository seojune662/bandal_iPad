import { copyFile, mkdir, rm, stat } from 'node:fs/promises'
import { constants } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { basename, isAbsolute, join } from 'node:path'
import { assertRealInside } from '../../db/validate'

export async function importChatAttachments(folder: string, paths: string[]): Promise<{ name: string; relPath: string }[]> {
  if (!Array.isArray(paths) || paths.length > 20) throw new Error('파일은 한 번에 20개까지 첨부할 수 있어요.')
  if (paths.length === 0) return []
  if (!(await stat(folder)).isDirectory()) throw new Error('과목 폴더를 찾을 수 없어요.')
  for (const path of paths) {
    if (typeof path !== 'string' || !isAbsolute(path)) throw new Error('올바른 파일을 선택해 주세요.')
    const info = await stat(path)
    if (!info.isFile() || info.size > 64 * 1024 * 1024) throw new Error(`${basename(path)}: 파일은 64MB까지 첨부할 수 있어요.`)
  }
  const relDir = `첨부/${randomUUID()}`
  assertRealInside(folder, join(folder, '첨부'))
  await mkdir(join(folder, relDir), { recursive: true })
  const result: { name: string; relPath: string }[] = []
  try {
    for (const path of paths) {
      const name = basename(path), relPath = `${relDir}/${result.length + 1}-${name}`
      const target = join(folder, relPath)
      assertRealInside(folder, target)
      await copyFile(path, target, constants.COPYFILE_EXCL)
      if ((await stat(target)).size > 64 * 1024 * 1024) throw new Error('첨부 파일 크기가 제한을 초과했어요.')
      result.push({ name, relPath })
    }
    return result
  } catch (error) { await rm(join(folder, relDir), { recursive: true, force: true }); throw error }
}
