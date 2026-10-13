/** [M18] Per-file video resume state. */
export interface MediaProgress {
  courseId: string
  relPath: string
  /** Last watched position, seconds. */
  positionSec: number
  /** Known media duration at save time; null before metadata loads. */
  durationSec: number | null
  /** Chosen playback speed (persists with the file). */
  playbackRate: number
  updatedAt: string
}
