import { useCoursesStore } from './coursesStore'
import { create } from 'zustand'
import { immer } from 'zustand/middleware/immer'
import type {
  MaterialNode,
  MaterialSearchHit
} from '../../../shared/types/materials'
import { invoke } from '../lib/ipc'
import type { ImmerStore } from './immerStore'

interface MaterialsState {
  activeCourseId: string | null
  tree: MaterialNode[]
  searchResults: MaterialSearchHit[]
  expandedPaths: Record<string, boolean>
  isLoading: boolean
  isSearching: boolean
  error: string | null
  /** `silent` refreshes in place (watcher pushes) without the skeleton. */
  loadTree: (courseId: string, options?: { silent?: boolean; refreshOnly?: boolean }) => Promise<void>
  search: (courseId: string, query: string) => Promise<void>
  clearSearch: () => void
  clear: () => void
  toggleFolder: (relPath: string) => void
}

const courseTrees = new Map<string, { tree: MaterialNode[]; expandedPaths: Record<string, boolean> }>()
let activeCacheKey: string | null = null
let treeSequence = 0
let searchSequence = 0

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : '자료를 불러오지 못했습니다.'
}

export const useMaterialsStore: ImmerStore<MaterialsState> = create<MaterialsState>()(
  immer((set, get) => ({
    activeCourseId: null,
    tree: [],
    searchResults: [],
    expandedPaths: {},
    isLoading: false,
    isSearching: false,
    error: null,

    loadTree: async (courseId, options = {}) => {
      // Background mutations may finish after the user has selected a different
      // course. Invalidate the old cache without changing the visible scope.
      if (options.refreshOnly && get().activeCourseId !== courseId) {
        for (const key of courseTrees.keys()) if (key.startsWith(`${courseId}:`)) courseTrees.delete(key)
        return
      }
      const sequence = ++treeSequence
      const cacheKey = `${courseId}:${useCoursesStore.getState().courses.find(course => course.id === courseId)?.folderPath ?? ''}`
      const previous = get()
      if (activeCacheKey !== null) courseTrees.set(activeCacheKey, { tree: previous.tree, expandedPaths: previous.expandedPaths })
      const cached = courseTrees.get(cacheKey)
      if (get().activeCourseId !== courseId || activeCacheKey !== cacheKey) {
        activeCacheKey = cacheKey
        searchSequence += 1
        set((state) => {
          state.activeCourseId = courseId
          state.tree = cached?.tree ?? []
          state.searchResults = []
          state.isSearching = false
          state.expandedPaths = cached?.expandedPaths ?? {}
        })
      }
      set((state) => {
        state.isLoading = options.silent !== true && cached === undefined
        state.error = null
      })

      try {
        if (cached === undefined) {
          // The snapshot is only a startup optimization. A missing/corrupt cache
          // must not prevent a live scan from recovering the materials list.
          const snapshot = await invoke('materials:snapshot', { courseId }).catch(() => ({ tree: null }))
          if (sequence !== treeSequence || get().activeCourseId !== courseId) return
          if (snapshot.tree !== null) set(state => { state.tree = snapshot.tree!; state.isLoading = false })
        }
        const tree = await invoke('materials:tree', { courseId })
        if (sequence !== treeSequence || get().activeCourseId !== courseId) return
        set((state) => {
          state.tree = tree
          state.isLoading = false
        })
        courseTrees.set(cacheKey, { tree, expandedPaths: get().expandedPaths })
        if (courseTrees.size > 16) courseTrees.delete(courseTrees.keys().next().value!)
      } catch (error) {
        if (sequence !== treeSequence || get().activeCourseId !== courseId) return
        set((state) => {
          state.isLoading = false
          state.error = errorMessage(error)
        })
      }
    },

    search: async (courseId, query) => {
      if (get().activeCourseId !== courseId) return
      const normalizedQuery = query.trim()
      if (normalizedQuery.length === 0) {
        get().clearSearch()
        return
      }

      const sequence = ++searchSequence
      set((state) => {
        state.isSearching = true
        state.error = null
      })
      try {
        const results = await invoke('materials:search', {
          courseId,
          query: normalizedQuery
        })
        if (sequence !== searchSequence || get().activeCourseId !== courseId) return
        set((state) => {
          state.searchResults = results
          state.isSearching = false
        })
      } catch (error) {
        if (sequence !== searchSequence || get().activeCourseId !== courseId) return
        set((state) => {
          state.searchResults = []
          state.isSearching = false
          state.error = errorMessage(error)
        })
      }
    },

    clearSearch: () => {
      searchSequence += 1
      set((state) => {
        state.searchResults = []
        state.isSearching = false
      })
    },

    clear: () => {
      treeSequence += 1
      searchSequence += 1
      if (activeCacheKey !== null) {
        const previous = get()
        courseTrees.set(activeCacheKey, { tree: previous.tree, expandedPaths: previous.expandedPaths })
        activeCacheKey = null
      }
      set((state) => {
        state.activeCourseId = null
        state.tree = []
        state.searchResults = []
        state.expandedPaths = {}
        state.isLoading = false
        state.isSearching = false
        state.error = null
      })
    },

    toggleFolder: (relPath) => {
      set((state) => {
        state.expandedPaths[relPath] = !state.expandedPaths[relPath]
      })
    }
  }))
)
