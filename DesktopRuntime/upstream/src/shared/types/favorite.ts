/**
 * Favorites — pinned shortcuts in the left rail.
 *
 * Generalizes the old "링크 추가" (course_links, LMS URLs only): a favorite
 * now stores a whole `TabDescriptor`, so ANY tab — a pdf, a note, a browser
 * URL, the AI tutor, the board — can be pinned and reopened after its tab is
 * closed. The descriptor is the same JSON the dockview layout persists, so
 * opening a favorite is literally `openTab(descriptor)`.
 */

import type { TabDescriptor } from '../tabs'

export interface Favorite {
  id: string
  /** null = pinned app-wide rather than to one course. */
  courseId: string | null
  label: string
  descriptor: TabDescriptor
  sortOrder: number
  createdAt: string
  updatedAt: string
}

export interface CreateFavoriteInput {
  courseId: string | null
  label: string
  descriptor: TabDescriptor
}

export interface RenameFavoriteInput {
  id: string
  label: string
}

/** Full ordering for one course's list, in the order the ids appear. */
export interface ReorderFavoritesInput {
  courseId: string | null
  ids: string[]
}
