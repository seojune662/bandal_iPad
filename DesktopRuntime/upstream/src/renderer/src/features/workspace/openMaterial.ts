/**
 * Glue for the materials sidebar: clicking a file opens it as a
 * workspace tab (pdf/md/images) or reveals it in Finder (other files).
 * Kept here (not in the materials feature)
 * so the sidebar only needs a one-line call.
 */

import type { TabDescriptor } from '../../../../shared/tabs'
import type { MaterialKind } from '../../../../shared/types/materials'
import { showToast } from '../../app/toast'
import { invoke } from '../../lib/ipc'
import { useMaterialsStore } from '../../stores/materialsStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { useCoursesStore } from '../../stores/coursesStore'
import { descriptorFor } from './tabIdentity'
import { isViewableFile } from '../file/fileFormats'

interface OpenMaterialOptions {
  newInstance?: boolean
}

export const MATERIAL_OPEN_DEDUPE_MS = 5 * 60 * 1000

const materialOpenRecordedAt = new Map<string, number>()
let latestOpenRequest = 0

/** Pure duplicate decision used by the renderer-side activity throttle. */
export function shouldRecordMaterialOpen(
  lastRecordedAt: number | undefined,
  now: number,
  dedupeMs = MATERIAL_OPEN_DEDUPE_MS
): boolean {
  return (
    lastRecordedAt === undefined ||
    now < lastRecordedAt ||
    now - lastRecordedAt >= dedupeMs
  )
}

function recordMaterialOpened(courseId: string, relPath: string): void {
  const key = `${courseId}\u0000${relPath}`
  const now = Date.now()
  if (!shouldRecordMaterialOpen(materialOpenRecordedAt.get(key), now)) return
  materialOpenRecordedAt.set(key, now)

  void invoke('activity:record', {
    courseId,
    kind: 'material-opened',
    relPath,
    summary: `${relPath}을(를) 열었습니다.`
  }).catch(() => {})
}

export function openMaterialInWorkspace(
  kind: MaterialKind,
  relPath: string,
  options?: OpenMaterialOptions
): void {
  const courseId = useMaterialsStore.getState().activeCourseId
  if (courseId === null) return
  openMaterialInCourse(courseId, kind, relPath, options)
}

/**
 * [M6-A] Course-explicit variant for callers that know their course (⌘P
 * quick search) — the materials store's activeCourseId only tracks the
 * sidebar, which may be closed.
 */
export function openMaterialInCourse(
  courseId: string,
  kind: MaterialKind,
  relPath: string,
  options?: OpenMaterialOptions
): void {
  const request = ++latestOpenRequest
  const initialWorkspace = useWorkspaceStore.getState()
  const initialCourse = useCoursesStore.getState().selectedCourseId
  const stillRequested = (): boolean => {
    const current = useWorkspaceStore.getState()
    return request === latestOpenRequest && current.surface === initialWorkspace.surface &&
      current.activeCourseId === initialWorkspace.activeCourseId &&
      current.activePanelId === initialWorkspace.activePanelId &&
      useCoursesStore.getState().selectedCourseId === initialCourse
  }
  const openTab = (descriptor: TabDescriptor): void => {
    const courses = useCoursesStore.getState()
    if (!courses.courses.some(course => course.id === courseId)) {
      showToast('원본 과목을 찾을 수 없어요.', 'danger')
      return
    }
    courses.selectCourse(courseId)
    useWorkspaceStore.getState().showCourseWorkspace(courseId)
    if (options?.newInstance === true) {
      useWorkspaceStore.getState().openTab(descriptor, { newInstance: true })
      return
    }
    useWorkspaceStore.getState().openTab(descriptor)
  }

  if (relPath.toLowerCase().endsWith('.wav')) {
    void invoke('recordings:resolve', { courseId, relPath }).then((recording) => {
      if (!stillRequested()) return
      if (recording) {
        openTab(descriptorFor('recording', {
          courseId, sessionId: recording.id, title: recording.title
        }))
        recordMaterialOpened(courseId, relPath)
      } else {
        void invoke('materials:reveal', { courseId, relPath }).catch(() =>
          showToast('파일을 열지 못했습니다.', 'danger'))
      }
    }).catch(() => { if (stillRequested()) showToast('녹음 파일을 열지 못했습니다.', 'danger') })
    return
  }

  if (kind === 'other' && isViewableFile(relPath)) {
    openTab(descriptorFor('file', { courseId, relPath }))
    recordMaterialOpened(courseId, relPath)
    return
  }
  // 동영상은 범용 파일 탭으로 연다 — FileTab 의 'video' 분기(현재는 자리표시자,
  // VideoTab 워커가 bandal-media 스트리밍 뷰어로 교체)가 렌더링을 맡는다.
  if (kind === 'video') {
    openTab(descriptorFor('file', { courseId, relPath }))
    recordMaterialOpened(courseId, relPath)
    return
  }
  if (kind === 'pdf' || kind === 'note' || kind === 'image') {
    openTab(descriptorFor(kind, { courseId, relPath }))
    recordMaterialOpened(courseId, relPath)
    return
  }
  // Unsupported files are handed off to Finder.
  void invoke('materials:reveal', { courseId, relPath })
    .then(() => recordMaterialOpened(courseId, relPath))
    .catch((error: unknown) => {
      console.error('[Bandal] 파일 위치를 열지 못했습니다.', error)
      showToast('파일 위치를 열지 못했습니다.', 'danger')
    })
}
