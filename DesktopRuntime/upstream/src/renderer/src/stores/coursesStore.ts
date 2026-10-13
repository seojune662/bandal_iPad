import { create } from 'zustand'
import { immer } from 'zustand/middleware/immer'
import type {
  AddCourseFromFolderInput,
  Course,
  CourseFolderResult,
  CourseGroup,
  CreateCourseInput,
  PickedFolder
} from '../../../shared/types/course'
import { folderProblemMessage } from '../features/courses/folderMessages'
import { invoke } from '../lib/ipc'
import type { ImmerStore } from './immerStore'
import { ensureSettingsLoaded, settingsSnapshot } from './settingsSnapshot'
import { closeResourceTabs, useWorkspaceStore } from './workspaceStore'

interface CoursesState {
  courses: Course[]
  /** 과목 그룹(학기) — 사이드바 섹션. loadCourses 가 함께 채운다. */
  groups: CourseGroup[]
  selectedCourseId: string | null
  isLoading: boolean
  pendingCourseId: string | null
  error: string | null
  loadCourses: () => Promise<void>
  selectCourse: (courseId: string | null, options?: { preserveSurface?: boolean }) => void
  createGroup: (name: string) => Promise<CourseGroup>
  renameGroup: (groupId: string, name: string) => Promise<CourseGroup>
  /** 그룹만 지운다 — 멤버 과목은 그룹 해제될 뿐 삭제되지 않는다. */
  deleteGroup: (groupId: string) => Promise<void>
  /** 한 번의 드래그 = 소속 + 위치 원자 반영. 서버가 준 목록으로 교체한다. */
  organizeCourse: (
    courseId: string,
    groupId: string | null,
    beforeCourseId: string | null
  ) => Promise<void>
  createCourse: (input: CreateCourseInput) => Promise<Course>
  /** Opens the native folder picker; resolves to null when cancelled. */
  pickFolder: () => Promise<PickedFolder | null>
  /** Registers an existing folder as a course (or focuses the duplicate). */
  addCourseFromFolder: (input: AddCourseFromFolderInput) => Promise<CourseFolderResult>
  /** Repoints a 연결 끊김 course at another folder. */
  relinkCourse: (courseId: string, folderPath: string) => Promise<CourseFolderResult>
  renameCourse: (courseId: string, name: string) => Promise<Course>
  setCourseColor: (courseId: string, color: string) => Promise<Course>
  archiveCourse: (courseId: string, archived: boolean) => Promise<void>
  deleteCourse: (courseId: string) => Promise<void>
  clearError: () => void
}

let loadSequence = 0

/**
 * [R3] 마지막 활성 과목을 settings 로 저장하는 디바운스. 과목을 빠르게
 * 넘겨볼 때 settings:set 이 연타되지 않게 하고, 스냅샷과 같은 값이면
 * 아예 쓰지 않아 settings:changed 왕복 루프를 막는다.
 */
const LAST_COURSE_PERSIST_DEBOUNCE_MS = 800
let lastCoursePersistTimer: ReturnType<typeof setTimeout> | null = null
let pendingLastCourseId: string | null = null

function sendLastActiveCourse(courseId: string): void {
  // 브로드캐스트가 스냅샷을 갱신하므로, 그 사이 같은 값이 되었으면 무시.
  if (settingsSnapshot().lastActiveCourseId === courseId) return
  void invoke('settings:set', { lastActiveCourseId: courseId }).catch(
    (error: unknown) => {
      console.error('[Bandal] 마지막 과목을 저장하지 못했습니다.', error)
    }
  )
}

function persistLastActiveCourse(courseId: string): void {
  if (lastCoursePersistTimer !== null) clearTimeout(lastCoursePersistTimer)
  if (settingsSnapshot().lastActiveCourseId === courseId) {
    lastCoursePersistTimer = null
    pendingLastCourseId = null
    return
  }
  pendingLastCourseId = courseId
  lastCoursePersistTimer = setTimeout(() => {
    lastCoursePersistTimer = null
    pendingLastCourseId = null
    sendLastActiveCourse(courseId)
  }, LAST_COURSE_PERSIST_DEBOUNCE_MS)
}

/**
 * 과목 전환 직후 바로 종료하면 800ms 디바운스가 아직 안 터진 상태 —
 * beforeunload 에서 호출해 마지막 전환을 잃지 않는다.
 */
export function flushLastActiveCoursePersist(): void {
  if (pendingLastCourseId === null) return
  if (lastCoursePersistTimer !== null) {
    clearTimeout(lastCoursePersistTimer)
    lastCoursePersistTimer = null
  }
  const courseId = pendingLastCourseId
  pendingLastCourseId = null
  sendLastActiveCourse(courseId)
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : '요청을 처리하지 못했습니다.'
}

function nextSelection(courses: Course[], removedId: string): string | null {
  const removedIndex = courses.findIndex((course) => course.id === removedId)
  const remaining = courses.filter((course) => course.id !== removedId)
  if (remaining.length === 0) return null
  const nextIndex = Math.min(Math.max(removedIndex, 0), remaining.length - 1)
  return remaining[nextIndex]?.id ?? null
}

export const useCoursesStore: ImmerStore<CoursesState> = create<CoursesState>()(
  immer((set, get) => ({
    courses: [],
    groups: [],
    selectedCourseId: null,
    isLoading: false,
    pendingCourseId: null,
    error: null,

    loadCourses: async () => {
      const sequence = ++loadSequence
      set((state) => {
        state.isLoading = true
        state.error = null
      })

      try {
        // 그룹 목록은 과목 목록과 항상 짝으로 그려지므로 병렬로 함께 당긴다.
        // [R3] settings 도 함께 — 부팅 경로에서 마지막 과목 복원에 쓰이고,
        // 이후 workspaceStore.openTab 의 동기 스냅샷 읽기도 데워 둔다.
        const [courses, groups, settings] = await Promise.all([
          invoke('courses:list', {}),
          invoke('courseGroups:list', {}),
          // 복원은 부가 기능 — settings 로드 실패가 과목 목록까지 막으면 안 된다.
          ensureSettingsLoaded().catch(() => null)
        ])
        if (sequence !== loadSequence) return
        set((state) => {
          state.courses = courses
          state.groups = groups
          state.isLoading = false
        })
        const selectionStillExists = courses.some(
          (course) => course.id === get().selectedCourseId
        )
        if (!selectionStillExists) {
          // [R3] 부팅(또는 선택 과목 소멸) 시: 설정이 켜져 있고 기록된
          // 과목이 아직 살아 있으면 그 과목을, 아니면 첫 과목을 고른다.
          const remembered =
            settings !== null &&
            settings.restoreLastCourse &&
            settings.lastActiveCourseId !== null &&
            courses.some((course) => course.id === settings.lastActiveCourseId)
              ? settings.lastActiveCourseId
              : null
          get().selectCourse(remembered ?? courses[0]?.id ?? null, { preserveSurface: useWorkspaceStore.getState().surface !== 'course' })
        }
        // [Gap B] 부팅에서 고른 과목도 영속 — 안 그러면 과목을 한 번도
        // 전환하지 않은 사용자는 lastActiveCourseId 가 영영 비어 있다.
        const bootSelection = get().selectedCourseId
        if (bootSelection !== null) persistLastActiveCourse(bootSelection)
      } catch (error) {
        if (sequence !== loadSequence) return
        set((state) => {
          state.isLoading = false
          state.error = errorMessage(error)
        })
      }
    },

    createGroup: async (name) => {
      set((state) => {
        state.error = null
      })
      try {
        const created = await invoke('courseGroups:create', { name })
        set((state) => {
          state.groups = state.groups.filter((group) => group.id !== created.id)
          state.groups.push(created)
          state.groups.sort((a, b) => a.sortOrder - b.sortOrder)
        })
        return created
      } catch (error) {
        set((state) => {
          state.error = errorMessage(error)
        })
        throw error
      }
    },

    renameGroup: async (groupId, name) => {
      set((state) => {
        state.error = null
      })
      try {
        const renamed = await invoke('courseGroups:rename', { groupId, name })
        set((state) => {
          const index = state.groups.findIndex((group) => group.id === groupId)
          if (index !== -1) state.groups[index] = renamed
        })
        return renamed
      } catch (error) {
        set((state) => {
          state.error = errorMessage(error)
        })
        throw error
      }
    },

    deleteGroup: async (groupId) => {
      set((state) => {
        state.error = null
      })
      try {
        await invoke('courseGroups:delete', { groupId })
        set((state) => {
          state.groups = state.groups.filter((group) => group.id !== groupId)
          // 서버와 같은 규칙: 멤버 과목은 그룹만 잃고 그대로 남는다.
          for (const course of state.courses) {
            if (course.groupId === groupId) course.groupId = null
          }
        })
      } catch (error) {
        set((state) => {
          state.error = errorMessage(error)
        })
        throw error
      }
    },

    organizeCourse: async (courseId, groupId, beforeCourseId) => {
      set((state) => {
        state.error = null
      })
      try {
        const courses = await invoke('courses:organize', {
          courseId,
          groupId,
          beforeCourseId
        })
        // 정렬과 소속은 서버가 원자적으로 확정한다 — 돌려준 목록으로 교체.
        set((state) => {
          state.courses = courses
        })
      } catch (error) {
        set((state) => {
          state.error = errorMessage(error)
        })
        throw error
      }
    },

    selectCourse: (courseId, options) => {
      if (
        courseId !== null &&
        !get().courses.some((course) => course.id === courseId)
      ) {
        return
      }
      set((state) => {
        state.selectedCourseId = courseId
      })
      if (options?.preserveSurface) useWorkspaceStore.getState().setActiveCourse(courseId)
      else useWorkspaceStore.getState().showCourseWorkspace(courseId)
      // [R3] 다음 부팅의 복원용. 값이 같으면 쓰지 않는다(디바운스 내부 처리).
      if (courseId !== null) persistLastActiveCourse(courseId)
    },

    createCourse: async (input) => {
      set((state) => {
        state.error = null
      })
      try {
        const created = await invoke('courses:create', input)
        set((state) => {
          state.courses = state.courses.filter((course) => course.id !== created.id)
          state.courses.push(created)
          state.courses.sort((a, b) => a.sortOrder - b.sortOrder)
        })
        get().selectCourse(created.id)
        return created
      } catch (error) {
        set((state) => {
          state.error = errorMessage(error)
        })
        throw error
      }
    },

    pickFolder: async () => {
      set((state) => {
        state.error = null
      })
      try {
        return await invoke('courses:pickFolder', {})
      } catch (error) {
        set((state) => {
          state.error = errorMessage(error)
        })
        throw error
      }
    },

    addCourseFromFolder: async (input) => {
      set((state) => {
        state.error = null
      })
      try {
        const result = await invoke('courses:addFromFolder', input)
        if (result.status === 'failed') {
          set((state) => {
            state.error = folderProblemMessage(result.reason)
          })
          return result
        }
        const course = result.course
        set((state) => {
          const index = state.courses.findIndex((item) => item.id === course.id)
          if (index === -1) {
            state.courses.push(course)
          } else {
            state.courses[index] = course
          }
          state.courses.sort((a, b) => a.sortOrder - b.sortOrder)
        })
        get().selectCourse(course.id)
        return result
      } catch (error) {
        set((state) => {
          state.error = errorMessage(error)
        })
        throw error
      }
    },

    relinkCourse: async (courseId, folderPath) => {
      set((state) => {
        state.pendingCourseId = courseId
        state.error = null
      })
      try {
        const result = await invoke('courses:relink', { courseId, folderPath })
        set((state) => {
          state.pendingCourseId = null
          if (result.status === 'failed') {
            state.error = folderProblemMessage(result.reason)
            return
          }
          const course = result.course
          const index = state.courses.findIndex((item) => item.id === course.id)
          if (index === -1) {
            state.courses.push(course)
            state.courses.sort((a, b) => a.sortOrder - b.sortOrder)
          } else {
            state.courses[index] = course
          }
          if (result.status === 'duplicate') {
            state.error = '그 폴더는 이미 다른 과목이 쓰고 있어요.'
          }
        })
        if (result.status !== 'failed') get().selectCourse(result.course.id)
        return result
      } catch (error) {
        set((state) => {
          state.pendingCourseId = null
          state.error = errorMessage(error)
        })
        throw error
      }
    },

    renameCourse: async (courseId, name) => {
      set((state) => {
        state.pendingCourseId = courseId
        state.error = null
      })
      try {
        const renamed = await invoke('courses:rename', { courseId, name })
        set((state) => {
          const index = state.courses.findIndex((course) => course.id === courseId)
          if (index !== -1) state.courses[index] = renamed
          state.pendingCourseId = null
        })
        return renamed
      } catch (error) {
        set((state) => {
          state.pendingCourseId = null
          state.error = errorMessage(error)
        })
        throw error
      }
    },

    setCourseColor: async (courseId, color) => {
      set((state) => {
        state.pendingCourseId = courseId
        state.error = null
      })
      try {
        const updated = await invoke('courses:setColor', { courseId, color })
        set((state) => {
          const index = state.courses.findIndex((course) => course.id === courseId)
          if (index !== -1) state.courses[index] = updated
          state.pendingCourseId = null
        })
        return updated
      } catch (error) {
        set((state) => {
          state.pendingCourseId = null
          state.error = errorMessage(error)
        })
        throw error
      }
    },

    archiveCourse: async (courseId, archived) => {
      set((state) => {
        state.pendingCourseId = courseId
        state.error = null
      })
      try {
        const updated = await invoke('courses:archive', { courseId, archived })
        const courses = get().courses
        if (archived) {
          // The course row is gone from active listings; a queued layout save
          // for it would be stale. Its agent session was disposed in main.
          useWorkspaceStore.getState().discardPendingSave(courseId)
        }
        set((state) => {
          if (archived) {
            state.courses = state.courses.filter((course) => course.id !== courseId)
          } else {
            const index = state.courses.findIndex((course) => course.id === courseId)
            if (index === -1) state.courses.push(updated)
            else state.courses[index] = updated
            state.courses.sort((a, b) => a.sortOrder - b.sortOrder)
          }
          state.pendingCourseId = null
        })
        if (archived && get().selectedCourseId === courseId) {
          get().selectCourse(nextSelection(courses, courseId))
        }
      } catch (error) {
        set((state) => {
          state.pendingCourseId = null
          state.error = errorMessage(error)
        })
        throw error
      }
    },

    deleteCourse: async (courseId) => {
      set((state) => {
        state.pendingCourseId = courseId
        state.error = null
      })
      try {
        await invoke('courses:delete', { courseId })
        const courses = get().courses
        // Saving a layout for a deleted course would throw in main; the
        // workspace swaps to the next course via the selection change below.
        useWorkspaceStore.getState().discardPendingSave(courseId)
        closeResourceTabs(descriptor => 'courseId' in descriptor.payload && descriptor.payload.courseId === courseId)
        set((state) => {
          state.courses = state.courses.filter((course) => course.id !== courseId)
          state.pendingCourseId = null
        })
        if (get().selectedCourseId === courseId) {
          get().selectCourse(nextSelection(courses, courseId))
        }
      } catch (error) {
        set((state) => {
          state.pendingCourseId = null
          state.error = errorMessage(error)
        })
        throw error
      }
    },

    clearError: () => {
      set((state) => {
        state.error = null
      })
    }
  }))
)
