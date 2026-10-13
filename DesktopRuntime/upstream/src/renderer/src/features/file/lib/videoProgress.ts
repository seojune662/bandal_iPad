import type { MediaProgress } from '../../../../../shared/types/mediaProgress'

export const VIDEO_PROGRESS_MEMORY_CAPACITY = 20
export const VIDEO_PROGRESS_INTERVAL_MS = 5_000
export const VIDEO_COMPLETE_THRESHOLD_SEC = 5
export const VIDEO_PLAYBACK_RATES = [0.5, 0.75, 1, 1.25, 1.5, 2] as const

export type VideoPlaybackRate = (typeof VIDEO_PLAYBACK_RATES)[number]

export type VideoProgressSnapshot = Pick<
  MediaProgress,
  'positionSec' | 'durationSec' | 'playbackRate'
>

export interface VideoProgressMemory {
  get(courseId: string, relPath: string): VideoProgressSnapshot | null
  set(
    courseId: string,
    relPath: string,
    progress: VideoProgressSnapshot
  ): void
  size(): number
  keys(): string[]
}

export interface VideoSaveTiming {
  lastMemoryWriteAtMs: number | null
  ipcDueAtMs: number | null
}

export interface VideoTimeUpdatePlan {
  timing: VideoSaveTiming
  writeMemory: boolean
}

export interface VideoResumeRequest {
  positionSec: number
  playbackRate: number
}

interface VideoFlushTriggers {
  windowTarget: EventTarget
  documentTarget: EventTarget
  visibilityState: () => DocumentVisibilityState
  flush: () => void
}

export const videoProgressKey = (courseId: string, relPath: string): string =>
  `${courseId}\u0000${relPath}`

const suspendedProgress = new Set<string>()
const pendingResumes = new Map<string, VideoResumeRequest>()
const resumeListeners = new Map<string, Set<() => void>>()

/** PiP가 파일을 소유하는 동안 원래 탭의 저장을 멈춘다. */
export function suspendProgress(key: string): void {
  suspendedProgress.add(key)
}

export function resumeProgress(key: string): void {
  suspendedProgress.delete(key)
}

export function isProgressSuspended(key: string): boolean {
  return suspendedProgress.has(key)
}

/** PiP에서 돌아온 위치를 열린 뷰어나 다음에 열릴 뷰어에 한 번 전달한다. */
export function requestVideoResume(
  courseId: string,
  relPath: string,
  request: VideoResumeRequest
): void {
  const key = videoProgressKey(courseId, relPath)
  pendingResumes.set(key, request)
  resumeProgress(key)
  for (const listener of resumeListeners.get(key) ?? []) listener()
}

export function takeVideoResume(key: string): VideoResumeRequest | null {
  const request = pendingResumes.get(key) ?? null
  pendingResumes.delete(key)
  return request
}

export function onVideoResume(key: string, listener: () => void): () => void {
  const listeners = resumeListeners.get(key) ?? new Set<() => void>()
  listeners.add(listener)
  resumeListeners.set(key, listeners)
  return () => {
    listeners.delete(listener)
    if (listeners.size === 0) resumeListeners.delete(key)
  }
}

/** Creates an isolated session LRU. Exported so its eviction behavior is testable. */
export function createVideoProgressMemory(
  capacity: number = VIDEO_PROGRESS_MEMORY_CAPACITY
): VideoProgressMemory {
  const entries = new Map<string, VideoProgressSnapshot>()

  return {
    get(courseId, relPath) {
      const key = videoProgressKey(courseId, relPath)
      const progress = entries.get(key)
      if (progress === undefined) return null
      entries.delete(key)
      entries.set(key, progress)
      return progress
    },
    set(courseId, relPath, progress) {
      const key = videoProgressKey(courseId, relPath)
      entries.delete(key)
      entries.set(key, progress)
      while (entries.size > capacity) {
        const oldest = entries.keys().next()
        if (oldest.done === true) break
        entries.delete(oldest.value)
      }
    },
    size: () => entries.size,
    keys: () => [...entries.keys()]
  }
}

export function createVideoSaveTiming(): VideoSaveTiming {
  return { lastMemoryWriteAtMs: null, ipcDueAtMs: null }
}

export function planVideoDebouncedSave(
  current: VideoSaveTiming,
  nowMs: number,
  delayMs: number = VIDEO_PROGRESS_INTERVAL_MS
): VideoSaveTiming {
  return { ...current, ipcDueAtMs: nowMs + delayMs }
}

/**
 * Pure timing transition for a media timeupdate: memory writes are throttled,
 * while every event moves the IPC deadline so persistence is debounced.
 */
export function planVideoTimeUpdate(
  current: VideoSaveTiming,
  nowMs: number,
  intervalMs: number = VIDEO_PROGRESS_INTERVAL_MS
): VideoTimeUpdatePlan {
  const writeMemory =
    current.lastMemoryWriteAtMs === null ||
    nowMs < current.lastMemoryWriteAtMs ||
    nowMs - current.lastMemoryWriteAtMs >= intervalMs

  return {
    timing: planVideoDebouncedSave(
      {
        lastMemoryWriteAtMs: writeMemory
          ? nowMs
          : current.lastMemoryWriteAtMs,
        ipcDueAtMs: current.ipcDueAtMs
      },
      nowMs,
      intervalMs
    ),
    writeMemory
  }
}

export function isVideoIpcSaveDue(
  ipcDueAtMs: number | null,
  nowMs: number
): boolean {
  return ipcDueAtMs !== null && nowMs >= ipcDueAtMs
}

export function isVideoComplete(
  positionSec: number,
  durationSec: number | null,
  thresholdSec: number = VIDEO_COMPLETE_THRESHOLD_SEC
): boolean {
  if (
    !Number.isFinite(positionSec) ||
    durationSec === null ||
    !Number.isFinite(durationSec) ||
    durationSec <= 0
  ) {
    return false
  }

  const position = Math.max(0, Math.min(positionSec, durationSec))
  return durationSec - position <= thresholdSec
}

export function positionForVideoRestore(
  positionSec: number,
  durationSec: number | null
): number {
  if (!Number.isFinite(positionSec) || positionSec <= 0) return 0
  if (isVideoComplete(positionSec, durationSec)) return 0
  if (durationSec === null || !Number.isFinite(durationSec)) return positionSec
  return Math.min(positionSec, Math.max(0, durationSec))
}

export function playbackRateForVideoRestore(
  playbackRate: number
): VideoPlaybackRate {
  return VIDEO_PLAYBACK_RATES.find((rate) => rate === playbackRate) ?? 1
}

/** Registers the final best-effort flush points shared by every video tab. */
export function registerVideoProgressFlushTriggers(
  triggers: VideoFlushTriggers
): () => void {
  const handleFlush = (): void => triggers.flush()
  const handleVisibilityChange = (): void => {
    if (triggers.visibilityState() === 'hidden') triggers.flush()
  }

  triggers.windowTarget.addEventListener('beforeunload', handleFlush)
  triggers.windowTarget.addEventListener('blur', handleFlush)
  triggers.documentTarget.addEventListener(
    'visibilitychange',
    handleVisibilityChange
  )

  return () => {
    triggers.windowTarget.removeEventListener('beforeunload', handleFlush)
    triggers.windowTarget.removeEventListener('blur', handleFlush)
    triggers.documentTarget.removeEventListener(
      'visibilitychange',
      handleVisibilityChange
    )
  }
}

/** Shared per-window instance: survives tab unmounts, but not an app restart. */
export const videoProgressMemory: VideoProgressMemory =
  createVideoProgressMemory()
