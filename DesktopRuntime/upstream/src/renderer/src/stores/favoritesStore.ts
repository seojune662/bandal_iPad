import { create } from 'zustand'
import type {
  CreateFavoriteInput,
  Favorite,
  RenameFavoriteInput
} from '../../../shared/types/favorite'
import { invoke } from '../lib/ipc'

const GLOBAL_SCOPE_KEY = '\u0000global'

export function favoriteScopeKey(courseId: string | null): string {
  return courseId ?? GLOBAL_SCOPE_KEY
}

interface FavoritesStore {
  /** Scope key → ordered favorites. Missing means that scope has not loaded. */
  byCourse: Record<string, Favorite[] | undefined>
  loadingByCourse: Record<string, boolean | undefined>
  error: string | null
  errorScopeKey: string | null
  load: (courseId: string | null) => Promise<void>
  add: (input: CreateFavoriteInput) => Promise<Favorite>
  rename: (input: RenameFavoriteInput) => Promise<Favorite>
  remove: (id: string) => Promise<void>
  /** Reorders the complete loaded list containing these ids. */
  reorder: (ids: string[]) => Promise<void>
  clearError: () => void
}

let loadSequence = 0
const latestLoadByScope = new Map<string, number>()
const latestRenameById = new Map<string, number>()
const latestReorderByScope = new Map<string, number>()

function invalidateLoad(key: string): void { latestLoadByScope.set(key, ++loadSequence) }

function messageFor(error: unknown, fallback: string): string {
  return error instanceof Error && error.message.trim().length > 0
    ? error.message
    : fallback
}

function scopeContaining(
  byCourse: FavoritesStore['byCourse'],
  id: string
): { key: string; favorites: Favorite[]; favorite: Favorite } | null {
  for (const [key, favorites] of Object.entries(byCourse)) {
    const favorite = favorites?.find((item) => item.id === id)
    if (favorites !== undefined && favorite !== undefined) {
      return { key, favorites, favorite }
    }
  }
  return null
}

export const useFavoritesStore = create<FavoritesStore>()((set, get) => ({
  byCourse: {},
  loadingByCourse: {},
  error: null,
  errorScopeKey: null,

  load: async (courseId) => {
    const key = favoriteScopeKey(courseId)
    const sequence = ++loadSequence
    latestLoadByScope.set(key, sequence)
    set((state) => ({
      loadingByCourse: { ...state.loadingByCourse, [key]: true },
      error: null,
      errorScopeKey: key
    }))

    try {
      const favorites = await invoke('favorites:list', { courseId })
      if (latestLoadByScope.get(key) !== sequence) return
      set((state) => ({
        byCourse: { ...state.byCourse, [key]: favorites },
        loadingByCourse: { ...state.loadingByCourse, [key]: false }
      }))
    } catch (error) {
      if (latestLoadByScope.get(key) !== sequence) return
      set((state) => ({
        loadingByCourse: { ...state.loadingByCourse, [key]: false },
        error: messageFor(error, '즐겨찾기를 불러오지 못했어요.'),
        errorScopeKey: key
      }))
    }
  },

  add: async (input) => {
    const errorScopeKey = favoriteScopeKey(input.courseId)
    set({ error: null, errorScopeKey })
    try {
      const created = await invoke('favorites:add', input)
      const key = favoriteScopeKey(created.courseId)
      invalidateLoad(key)
      set((state) => {
        const current = state.byCourse[key]
        if (current === undefined) return state
        return {
          byCourse: {
            ...state.byCourse,
            [key]: [...current.filter(item => item.id !== created.id), created].sort(
              (left, right) => left.sortOrder - right.sortOrder
            )
          }
        }
      })
      if (get().byCourse[key] === undefined) void get().load(created.courseId)
      else set(state => ({ loadingByCourse: { ...state.loadingByCourse, [key]: false } }))
      return created
    } catch (error) {
      set({ error: messageFor(error, '즐겨찾기를 추가하지 못했어요.'), errorScopeKey })
      throw error
    }
  },

  rename: async (input) => {
    const sequence = ++loadSequence
    latestRenameById.set(input.id, sequence)
    const errorScopeKey = scopeContaining(get().byCourse, input.id)?.key ?? null
    set({ error: null, errorScopeKey })
    try {
      const updated = await invoke('favorites:rename', input)
      if (latestRenameById.get(input.id) !== sequence) return updated
      const key = favoriteScopeKey(updated.courseId)
      invalidateLoad(key)
      set((state) => ({
        byCourse: Object.fromEntries(
          Object.entries(state.byCourse).map(([key, favorites]) => [
            key,
            favorites?.map((favorite) =>
              favorite.id === updated.id ? updated : favorite
            )
          ])
        )
      }))
      if (get().byCourse[key] === undefined) void get().load(updated.courseId)
      else set(state => ({ loadingByCourse: { ...state.loadingByCourse, [key]: false } }))
      return updated
    } catch (error) {
      if (latestRenameById.get(input.id) === sequence) set({ error: messageFor(error, '즐겨찾기 이름을 바꾸지 못했어요.'), errorScopeKey })
      throw error
    }
  },

  remove: async (id) => {
    const located = scopeContaining(get().byCourse, id)
    set({ error: null, errorScopeKey: located?.key ?? null })
    if (located !== null) {
      invalidateLoad(located.key)
      set((state) => ({
        byCourse: {
          ...state.byCourse,
          [located.key]: located.favorites.filter((favorite) => favorite.id !== id)
        },
        loadingByCourse: { ...state.loadingByCourse, [located.key]: false }
      }))
    }

    try {
      await invoke('favorites:remove', { id })
      if (located) {
        invalidateLoad(located.key)
        set(state => ({ byCourse: { ...state.byCourse, [located.key]: state.byCourse[located.key]?.filter(item => item.id !== id) }, loadingByCourse: { ...state.loadingByCourse, [located.key]: false } }))
      }
    } catch (error) {
      if (located !== null) {
        set((state) => {
          const current = state.byCourse[located.key] ?? []
          if (current.some(item => item.id === id)) return state
          const restored = [...current]
          restored.splice(Math.min(located.favorites.findIndex(item => item.id === id), restored.length), 0, located.favorite)
          return { byCourse: { ...state.byCourse, [located.key]: restored } }
        })
      }
      set({ error: messageFor(error, '즐겨찾기를 제거하지 못했어요.'), errorScopeKey: located?.key ?? null })
      throw error
    }
  },

  reorder: async (ids) => {
    if (ids.length === 0) return
    const located = scopeContaining(get().byCourse, ids[0] ?? '')
    if (located === null) throw new Error('정렬할 즐겨찾기 목록을 먼저 불러와야 합니다.')
    if (
      ids.length !== located.favorites.length ||
      new Set(ids).size !== ids.length ||
      ids.some((id) => !located.favorites.some((favorite) => favorite.id === id))
    ) {
      throw new Error('즐겨찾기 전체 순서가 필요합니다.')
    }

    const sequence = ++loadSequence
    latestReorderByScope.set(located.key, sequence)
    invalidateLoad(located.key)
    const previous = located.favorites
    const byId = new Map(previous.map((favorite) => [favorite.id, favorite]))
    const reordered = ids.map((id, index) => ({
      ...(byId.get(id) as Favorite),
      sortOrder: index
    }))
    set((state) => ({
      byCourse: { ...state.byCourse, [located.key]: reordered },
      error: null,
      errorScopeKey: located.key,
      loadingByCourse: { ...state.loadingByCourse, [located.key]: false }
    }))

    try {
      await invoke('favorites:reorder', {
        courseId: located.favorite.courseId,
        ids
      })
      if (latestReorderByScope.get(located.key) === sequence) {
        invalidateLoad(located.key)
        set(state => {
          const current = state.byCourse[located.key] ?? []
          const positions = new Map(ids.map((id, index) => [id, index]))
          const ordered = [...current].sort((a, b) => (positions.get(a.id) ?? Infinity) - (positions.get(b.id) ?? Infinity)).map((item, index) => ({ ...item, sortOrder: index }))
          return { byCourse: { ...state.byCourse, [located.key]: ordered }, loadingByCourse: { ...state.loadingByCourse, [located.key]: false } }
        })
      }
    } catch (error) {
      if (latestReorderByScope.get(located.key) === sequence) set((state) => {
        const current = state.byCourse[located.key] ?? []
        const positions = new Map(previous.map((item, index) => [item.id, index]))
        const restored = [...current].sort((a, b) => (positions.get(a.id) ?? Infinity) - (positions.get(b.id) ?? Infinity)).map((item, index) => ({ ...item, sortOrder: index }))
        return { byCourse: { ...state.byCourse, [located.key]: restored }, error: messageFor(error, '즐겨찾기 순서를 저장하지 못했어요.'), errorScopeKey: located.key }
      })
      throw error
    }
  },

  clearError: () => set({ error: null, errorScopeKey: null })
}))

/** Test-only reset, including stale-load guards. */
export function resetFavoritesStoreForTests(): void {
  loadSequence = 0
  latestLoadByScope.clear()
  latestRenameById.clear()
  latestReorderByScope.clear()
  useFavoritesStore.setState({
    byCourse: {},
    loadingByCourse: {},
    error: null,
    errorScopeKey: null
  })
}
