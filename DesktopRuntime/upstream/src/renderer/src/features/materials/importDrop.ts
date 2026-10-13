/**
 * [M5] Finder drag & drop import, shared by the materials sidebar and the
 * workspace watermark. Resolves dropped Files to absolute paths through the
 * preload bridge (webUtils.getPathForFile), runs `materials:import` and
 * reports the outcome as toasts. The folder watcher refreshes the tree, but
 * an immediate silent reload keeps the UI snappy.
 */

import { showToast } from '../../app/toast'
import { invoke, pathForFile } from '../../lib/ipc'
import { useCoursesStore } from '../../stores/coursesStore'
import { useMaterialsStore } from '../../stores/materialsStore'
import { urlFromDataTransfer } from '../browser/urlDrop'
import { getMaterialFileDrag } from './materialFileDrag'
import { MATERIAL_MOVE_MIME } from './materialMoveDrag'

type DropClassification =
  | { kind: 'move' }
  | { kind: 'url'; url: string; fileName?: string }
  | { kind: 'files' }
  | { kind: 'unsupported' }

export function classifyDrop(
  types: readonly string[],
  getData: (type: string) => string,
  files: readonly File[]
): DropClassification {
  const typeSet = new Set(types)
  if (typeSet.has(MATERIAL_MOVE_MIME)) return { kind: 'move' }

  const urlDrop = urlFromDataTransfer(types, getData)
  if (urlDrop !== null) return { kind: 'url', ...urlDrop }
  if (files.length > 0) return { kind: 'files' }
  return { kind: 'unsupported' }
}

export function reportUnsupportedDrop(types: readonly string[]): void {
  showToast(
    `이 항목은 아직 받을 수 없어요 · 형식: ${types.join(', ')}`,
    'danger'
  )
  console.warn('[materials] unsupported drop', types)
}

/** True when the drag payload contains OS files (vs. in-app HTML5 dnd). */
export function isFileDrag(dataTransfer: DataTransfer | null): boolean {
  return dataTransfer !== null && [...dataTransfer.types].includes('Files')
}

function fileName(path: string): string {
  const segments = path.split('/')
  return segments[segments.length - 1] ?? path
}

export async function importMaterialPaths(
  courseId: string,
  paths: readonly string[],
  dirRelPath?: string
): Promise<string[]> {
  if (paths.length === 0) {
    showToast('가져올 수 있는 파일이 없어요', 'danger')
    return []
  }

  try {
    const result = await invoke('materials:import', {
      courseId,
      paths: [...paths],
      // '' 또는 생략 = 과목 폴더 루트. 폴더 위에 드롭하면 그 폴더로 들어간다.
      ...(dirRelPath !== undefined && dirRelPath !== '' ? { dirRelPath } : {})
    })
    if (result.imported.length > 0) {
      showToast(`${result.imported.length}개 가져옴`)
      await useMaterialsStore.getState().loadTree(courseId, { silent: true, refreshOnly: true })
    }
    if (result.failed.length > 0) {
      const names = result.failed.map((entry) => fileName(entry.path)).join(', ')
      showToast(`${result.failed.length}개 실패: ${names}`, 'danger')
    }
    return result.imported
  } catch (error) {
    showToast(
      error instanceof Error ? error.message : '파일을 가져오지 못했습니다.',
      'danger'
    )
    return []
  }
}

/**
 * 과목 폴더 안의 절대 경로를 posix relPath 로 바꾼다. 밖이면 null.
 *
 * 반드시 NFC 로 정규화해 비교한다: macOS 디스크 경로는 NFD 인데 드롭된
 * 경로는 NFC 로 올 수 있고, 정규형이 갈리면 과목 안 파일을 "밖"으로
 * 오판해 이동(no-op) 대신 가져오기(복사 + "이름 (2)" 개명)로 새 버린다.
 */
export function relPathInsideCourse(
  absPath: string,
  courseFolder: string
): string | null {
  const normalized = absPath.replace(/\\/gu, '/').normalize('NFC')
  const folder = courseFolder
    .replace(/\\/gu, '/')
    .replace(/\/+$/u, '')
    .normalize('NFC')
  if (!normalized.startsWith(`${folder}/`)) return null
  return normalized.slice(folder.length + 1)
}

/**
 * 이 드롭이 "이 사이드바에서 방금 끌기 시작한 그 자료"인지 판별한다.
 * 끌었다가 마음을 바꿔 사이드바에 도로 놓는 제스처는 이동/가져오기가 아니라
 * 취소다. files 가 비어 있으면(합성 이벤트) 모듈 드래그 상태를 신뢰한다.
 */
export function isSelfMaterialDrop(
  courseId: string,
  files: readonly File[]
): boolean {
  const drag = getMaterialFileDrag()
  if (drag === null || drag.courseId !== courseId) return false
  if (files.length === 0) return true

  const courseFolder = useCoursesStore
    .getState()
    .courses.find((course) => course.id === courseId)?.folderPath
  if (courseFolder === undefined) return false
  const first = files[0]
  if (first === undefined) return false
  const rel = relPathInsideCourse(pathForFile(first), courseFolder)
  return (
    rel !== null &&
    rel.toLowerCase() === drag.relPath.normalize('NFC').toLowerCase()
  )
}

export async function importDroppedFiles(
  courseId: string,
  files: readonly File[],
  dirRelPath?: string
): Promise<string[]> {
  const paths = files.map(pathForFile).filter((path) => path.length > 0)

  // 자료 행의 네이티브 드래그가 우리 패널로 돌아온 경우: 경로가 이 과목
  // 폴더 안이면 복사(가져오기)가 아니라 이동이다. Finder 파일만 가져온다.
  const courseFolder = useCoursesStore
    .getState()
    .courses.find((course) => course.id === courseId)?.folderPath
  const toImport: string[] = []
  const toMove: string[] = []
  for (const path of paths) {
    const rel =
      courseFolder === undefined
        ? null
        : relPathInsideCourse(path, courseFolder)
    if (rel === null) toImport.push(path)
    else toMove.push(rel)
  }

  const moved: string[] = []
  for (const fromRelPath of toMove) {
    try {
      const { relPath } = await invoke('materials:move', {
        courseId,
        fromRelPath,
        toDirRelPath: dirRelPath ?? ''
      })
      moved.push(relPath)
    } catch (error) {
      showToast(
        error instanceof Error ? error.message : '이동하지 못했습니다.',
        'danger'
      )
    }
  }
  if (moved.length > 0) {
    showToast(moved.length === 1 ? '이동했어요.' : `${moved.length}개 이동했어요.`)
    await useMaterialsStore.getState().loadTree(courseId, { silent: true, refreshOnly: true })
  }

  if (toImport.length === 0) return moved
  const imported = await importMaterialPaths(courseId, toImport, dirRelPath)
  return [...moved, ...imported]
}
