/**
 * [R4] 문서 편집 전 백업 계층.
 *
 * edit_sheet / edit_docx_text 는 기존 파일을 제자리에서 고치므로, 쓰기 전에
 * 원본을 `<과목 폴더>/.bandal/backups/` 아래로 복사해 둔다. `.bandal` 은
 * 숨김 디렉터리라 자료 트리 스캔과 watcher 모두 건너뛴다 — 백업이 자료
 * 목록을 오염시키지 않는다. 되돌리기(journal undo)는 이 백업을 원래 경로로
 * 다시 복사하는 것으로 구현된다.
 */

import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  unlinkSync
} from 'node:fs'
import { basename, join } from 'node:path'
import { assertRealInside, resolveInsideReal } from '../../db/validate'

/** 과목 폴더 기준 백업 디렉터리. 숨김이라 자료 스캔에 잡히지 않는다. */
export const MATERIAL_BACKUP_DIR_SEGMENTS = ['.bandal', 'backups'] as const

/** 과목당 보관하는 최대 백업 수. 넘치면 가장 오래된 것부터 지운다. */
export const MATERIAL_BACKUP_KEEP = 20

/** targetId 한 칸에 두 값을 싣는 구분자 — shape 타깃과 같은 관례. */
const TARGET_ID_SEPARATOR = '\u0000'

export interface MaterialBackup {
  /** 복사된 백업 파일의 절대 경로. journal targetId 에 실린다. */
  backupAbs: string
  /** `<ISO-ts>-<원본 이름>` 형태의 백업 파일 이름. */
  backupName: string
}

/** 이름의 ISO 타임스탬프 접두사 덕분에 사전순 = 시간순이다. */
function pruneBackups(courseFolder: string, dir: string, keep: number): void {
  const names = readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && !entry.name.startsWith('.'))
    .map((entry) => entry.name)
    .sort()
  const excess = names.length - keep
  for (const name of names.slice(0, Math.max(0, excess))) {
    try {
      const backupAbs = join(dir, name)
      assertRealInside(courseFolder, backupAbs)
      unlinkSync(backupAbs)
    } catch (error) {
      // 지우기 실패는 백업 자체를 막을 이유가 아니다 — 로그만 남긴다.
      console.error(`[agentTools] backup prune failed for "${name}"`, error)
    }
  }
}

/**
 * 편집 직전의 원본을 백업하고 백업 위치를 돌려준다.
 * 같은 밀리초에 같은 파일을 두 번 백업해도 이름이 겹치지 않게 번호를 붙인다.
 */
export function backupMaterial(
  courseFolder: string,
  sourceAbs: string,
  keep: number = MATERIAL_BACKUP_KEEP
): MaterialBackup {
  assertRealInside(courseFolder, sourceAbs)
  const dir = resolveInsideReal(
    courseFolder,
    MATERIAL_BACKUP_DIR_SEGMENTS.join('/')
  )
  assertRealInside(courseFolder, dir)
  mkdirSync(dir, { recursive: true })
  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  const base = basename(sourceAbs)
  let backupName = `${stamp}-${base}`
  let backupAbs = join(dir, backupName)
  for (let n = 2; existsSync(backupAbs); n += 1) {
    backupName = `${stamp}-${n}-${base}`
    backupAbs = join(dir, backupName)
  }
  assertRealInside(courseFolder, sourceAbs)
  assertRealInside(courseFolder, backupAbs)
  copyFileSync(sourceAbs, backupAbs)
  pruneBackups(courseFolder, dir, keep)
  return { backupAbs, backupName }
}

/**
 * journal 의 targetId 한 칸에 편집 대상과 백업 위치를 함께 싣는다.
 * relPath 는 resolveInsideReal 이 널 바이트를 거부하므로 구분자와 충돌하지
 * 않고, 백업 절대 경로에도 널 바이트는 올 수 없다.
 */
export function materialEditTargetId(
  relPath: string,
  backupAbs: string
): string {
  return `${relPath}${TARGET_ID_SEPARATOR}${backupAbs}`
}

export function parseMaterialEditTargetId(
  targetId: string
): { relPath: string; backupAbs: string } | null {
  const separator = targetId.indexOf(TARGET_ID_SEPARATOR)
  if (separator <= 0 || separator === targetId.length - 1) return null
  return {
    relPath: targetId.slice(0, separator),
    backupAbs: targetId.slice(separator + 1)
  }
}

/**
 * 백업을 원래 상대 경로 위로 다시 복사해 편집을 되돌린다.
 * 파일이 그 사이 이동/개명됐어도 원래 경로에 복원한다(계획된 동작).
 * 백업이 pruning 으로 사라졌으면 조용히 성공한 척하지 않고 던진다 —
 * journal.undoTurn 이 실패로 집계해 로그에 남긴다.
 */
export function restoreMaterialBackup(input: {
  courseFolder: string
  relPath: string
  backupAbs: string
}): void {
  if (!existsSync(input.backupAbs)) {
    throw new Error(
      `백업 파일이 없어 «${input.relPath}» 을(를) 되돌릴 수 없습니다`
    )
  }
  assertRealInside(input.courseFolder, input.backupAbs)
  const targetAbs = resolveInsideReal(input.courseFolder, input.relPath)
  assertRealInside(input.courseFolder, input.backupAbs)
  assertRealInside(input.courseFolder, targetAbs)
  copyFileSync(input.backupAbs, targetAbs)
}
