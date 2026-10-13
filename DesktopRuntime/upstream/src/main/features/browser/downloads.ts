/**
 * Browser downloads land in the course folder, not `~/Downloads`.
 *
 * Getting a lecture PDF out of the school LMS and next to the rest of the
 * course is the weekly action this whole embedded browser exists for, and
 * Chromium's default otherwise sends it somewhere else entirely.
 *
 * ## Why stage in temp and adopt afterwards
 *
 * `item.setSavePath()` has to be called synchronously inside the handler, so
 * the destination is chosen before a single byte arrives. Pointing it straight
 * at the course folder would mean:
 *   - the materials watcher sees a growing partial file and puts it in the tree
 *   - a cancelled or interrupted download leaves a corrupt "lecture PDF" there
 *   - name-collision handling would have to run before we know the real name
 *
 * So Chromium streams into a private staging dir and, only on `completed`,
 * `materialsRepo.adoptFile` moves it in under the same path guards every other
 * write goes through. The bytes never pass through this process.
 */

import { randomUUID } from 'node:crypto'
import { existsSync, mkdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import type { DownloadItem, Session } from 'electron'
import {
  FALLBACK_FILE_NAME,
  sanitizeFileName
} from './linkDownload'

import type { BrowserDownloadUpdate } from '../../../shared/ipc/events'

export type { BrowserDownloadUpdate }

export interface DownloadsDeps {
  /** Where staged files live. Injected so tests need no Electron. */
  stagingRoot: string
  /**
   * Course to file downloads under, or null when no course is selected — then
   * the download is left to the OS default rather than silently dropped.
   */
  getTargetCourseId: (webContentsId: number | null) => string | null
  resolveCourseFile?: (courseId: string, relPath: string) => string
  onNavigationSettled?: (webContentsId: number | null) => void
  getOwnerWebContentsId?: (webContentsId: number | null) => number | null
  adoptFile: (input: {
    courseId: string
    dirRelPath: string
    fileName: string
    sourcePath: string
  }) => { relPath: string }
  emit: (update: BrowserDownloadUpdate) => void
  onCompleted?: (fileName: string) => void
  /** Progress is throttled to this; `updated` fires per chunk. */
  progressIntervalMs?: number
  now?: () => number
}

const DEFAULT_PROGRESS_INTERVAL_MS = 200

/** `item.getFilename()` is Chromium's already-parsed Content-Disposition. */
export function downloadFileName(raw: string): string {
  const cleaned = sanitizeFileName(raw)
  return cleaned === '' ? FALLBACK_FILE_NAME : cleaned
}

/**
 * The core, free of Electron types beyond the item itself, so the state
 * machine is testable against a fake.
 */
/**
 * Live transfers, so 취소 / 일시중지 can reach them.
 *
 * Chrome puts these on every download row. We had none: the only button was
 * 닫기, which removed the row while the transfer kept running invisibly, and
 * quitting the app was the only way to stop a 2GB video on tethering.
 */
export interface DownloadControls {
  cancel: (id: string) => void
  pause: (id: string) => void
  resume: (id: string) => void
}

type ControllableItem = Pick<
  DownloadItem,
  'cancel' | 'pause' | 'resume' | 'isPaused' | 'canResume'
>

const liveDownloads = new Map<string, ControllableItem>()

export interface DownloadFile {
  path: string
  fileName: string
  retry?: () => void
}
const downloadFiles = new Map<string, DownloadFile>()
/** Only IDs issued by the download handler can access downloaded files. */
export function getDownloadFile(id: string): DownloadFile {
  const file = downloadFiles.get(id)
  if (!file) throw new Error('다운로드한 파일을 찾지 못했어요.')
  return file
}

export const downloadControls: DownloadControls = {
  cancel: (id) => {
    try {
      liveDownloads.get(id)?.cancel()
    } catch {
      // Already finished; the 'done' handler has cleaned up.
    }
  },
  pause: (id) => {
    try {
      liveDownloads.get(id)?.pause()
    } catch {
      // Same.
    }
  },
  resume: (id) => {
    try {
      const item = liveDownloads.get(id)
      if (item !== undefined && item.canResume()) item.resume()
    } catch {
      // Same.
    }
  }
}

export function createDownloadHandler(deps: DownloadsDeps) {
  const interval = deps.progressIntervalMs ?? DEFAULT_PROGRESS_INTERVAL_MS
  const now = deps.now ?? Date.now

  return function handle(
    item: Pick<
      DownloadItem,
      | 'getFilename'
      | 'getTotalBytes'
      | 'getReceivedBytes'
      | 'setSavePath'
      | 'getSavePath'
      | 'isPaused'
      | 'on'
    >,
    webContentsId: number | null
  ): void {
    const id = randomUUID()
    const fileName = downloadFileName(item.getFilename())
    const courseId = deps.getTargetCourseId(webContentsId)
    const ownerId = deps.getOwnerWebContentsId?.(webContentsId) ?? webContentsId
    liveDownloads.set(id, item as unknown as ControllableItem)
    const isPaused = (): boolean => {
      try {
        return typeof item.isPaused === 'function' && item.isPaused()
      } catch {
        return false
      }
    }
    item.on('done', () => liveDownloads.delete(id))
    // Closing a WebContentsView while its response is streaming cancels it.
    item.on('done', () => deps.onNavigationSettled?.(webContentsId))

    // No course selected: let Chromium do its default thing (~/Downloads).
    // Refusing the download outright would be worse.
    //
    // This still has to follow the item to completion. It used to emit one
    // 'progressing' and attach nothing, so the row sat at 0 bytes forever —
    // never completing, never swept by the recent-downloads TTL, and never
    // saying where the file actually landed.
    if (courseId === null) {
      const loose = { id, webContentsId: ownerId, fileName, courseId: null }
      deps.emit({
        ...loose,
        receivedBytes: 0,
        totalBytes: item.getTotalBytes(),
        state: 'progressing',
        paused: false,
        relPath: null,
        failureReason: null
      })
      let looseLastEmit = 0
      item.on('updated', (_event, state) => {
        const at = now()
        if (state === 'progressing' && at - looseLastEmit < interval) return
        looseLastEmit = at
        deps.emit({
          ...loose,
          receivedBytes: item.getReceivedBytes(),
          totalBytes: item.getTotalBytes(),
          state: 'progressing',
          paused: isPaused(),
          relPath: null,
          failureReason: null
        })
      })
      item.on('done', (_event, state) => {
        if (state === 'completed') downloadFiles.set(id, { path: item.getSavePath(), fileName })
        deps.emit({
          ...loose,
          receivedBytes: item.getReceivedBytes(),
          totalBytes: item.getTotalBytes(),
          state:
            state === 'completed'
              ? 'completed'
              : state === 'cancelled'
                ? 'cancelled'
                : 'interrupted',
          paused: false,
          // Not a course-relative path — the absolute one, because the whole
          // point is that the student cannot otherwise find the file.
          relPath: state === 'completed' ? item.getSavePath() : null,
          failureReason:
            state === 'interrupted' ? '연결이 끊겨 파일을 받지 못했어요.' : null
        })
        if (state === 'completed') deps.onCompleted?.(fileName)
      })
      return
    }

    const stagingDir = join(deps.stagingRoot, id)
    mkdirSync(stagingDir, { recursive: true })
    const stagedPath = join(stagingDir, fileName)
    item.setSavePath(stagedPath)

    const base = {
      id,
      webContentsId: ownerId,
      fileName,
      totalBytes: item.getTotalBytes(),
      courseId
    }
    deps.emit({
      ...base,
      receivedBytes: 0,
      state: 'progressing',
      paused: false,
      relPath: null,
      failureReason: null
    })

    let lastEmit = 0
    item.on('updated', (_event, state) => {
      const at = now()
      // `updated` fires per chunk — a 300MB video would flood the renderer.
      if (state === 'progressing' && at - lastEmit < interval) return
      lastEmit = at
      deps.emit({
        ...base,
        receivedBytes: item.getReceivedBytes(),
        totalBytes: item.getTotalBytes(),
        state: 'progressing',
        paused: isPaused(),
        relPath: null,
        failureReason: null
      })
    })

    item.on('done', (_event, state) => {
      if (state !== 'completed') {
        cleanStaging(stagingDir)
        deps.emit({
          ...base,
          receivedBytes: item.getReceivedBytes(),
          state: state === 'cancelled' ? 'cancelled' : 'interrupted',
          paused: false,
          relPath: null,
          failureReason: null
        })
        return
      }
      const fileCompleted = (): void => {
        try {
          const { relPath } = deps.adoptFile({
            courseId,
            dirRelPath: '',
            fileName,
            sourcePath: item.getSavePath()
          })
          const path = deps.resolveCourseFile?.(courseId, relPath)
          if (path) downloadFiles.set(id, { path, fileName })
          cleanStaging(stagingDir)
          deps.emit({
            ...base,
            receivedBytes: item.getReceivedBytes(),
            state: 'completed',
            recoverable: false,
            paused: false,
            relPath,
            failureReason: null
          })
          deps.onCompleted?.(fileName)
        } catch (error) {
          downloadFiles.set(id, { path: item.getSavePath(), fileName, retry: fileCompleted })
          // The transfer worked; only filing it failed. Say so rather than
          // reporting a download failure the student cannot act on.
          deps.emit({
            ...base,
            receivedBytes: item.getReceivedBytes(),
            state: 'interrupted',
            recoverable: true,
            paused: false,
            relPath: null,
            failureReason:
              error instanceof Error ? error.message : 'could not file the download'
          })
        }
      }
      fileCompleted()
    })
  }
}

function cleanStaging(dir: string): void {
  try {
    if (existsSync(dir)) rmSync(dir, { recursive: true, force: true })
  } catch {
    // A leftover temp dir is harmless; the OS reclaims it.
  }
}

/** Attach once to each normal/private session during IPC initialization. */
export function attachDownloadHandler(
  browsingSession: Session,
  deps: DownloadsDeps
): void {
  const handle = createDownloadHandler(deps)
  browsingSession.on('will-download', (_event, item, webContents) => {
    handle(item, webContents?.id ?? null)
  })
}
