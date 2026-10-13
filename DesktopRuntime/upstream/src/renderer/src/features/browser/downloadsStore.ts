/**
 * Browser downloads, as the renderer sees them.
 *
 * Main does the filing (see `main/features/browser/downloads.ts`); this store
 * mirrors progress so the toolbar and direct-download page can show it.
 */

import { create } from 'zustand'
import type { BrowserDownloadUpdate } from '../../../../shared/ipc/events'
import { invoke, onPush } from '../../lib/ipc'
import { useBrowserGuests } from './browserGuestsStore'
import { tabIdForWebContents } from './guestActions'
import { showToast, showToastWithAction } from '../../app/toast'
import { convertPresentationToPdf } from '../file/pptx/presentationJobs'

/** Finished downloads linger this long so the student can click through. */
const RECENT_TTL_MS = 24 * 60 * 60_000

export interface BrowserDownload extends BrowserDownloadUpdate {
  finishedAt: number | null
}

interface DownloadsState {
  /** Newest first. */
  downloads: BrowserDownload[]
  activeCount: number
  init: () => void
  dismiss: (id: string) => void
}

let initialized = false
const downloadFolderNotices = new Set<string>()

export const useDownloads = create<DownloadsState>()((set, get) => ({
  downloads: [],
  activeCount: 0,

  init: () => {
    if (initialized) return
    initialized = true
    onPush('browser:download', (update) => {
      const tabId = update.webContentsId === null ? null : tabIdForWebContents(update.webContentsId)
      if (tabId !== null) {
        const guests = useBrowserGuests.getState()
        if (guests.nav[tabId] && !guests.nav[tabId]?.hasDocument) {
          guests.updateNav(tabId, { loading: false })
          guests.setOverlay(tabId, { kind: 'download', downloadId: update.id })
        }
      }
      const previous = get().downloads
      const finished = update.state !== 'progressing'
      const next: BrowserDownload = {
        ...update,
        finishedAt: finished ? Date.now() : null
      }
      const merged = [
        next,
        ...previous.filter(
          (item) =>
            item.id !== update.id &&
            // Drop stale finished rows rather than growing forever.
            (item.finishedAt === null ||
              Date.now() - item.finishedAt < RECENT_TTL_MS)
        )
      ]
      set({
        downloads: merged,
        activeCount: merged.filter((item) => item.state === 'progressing')
          .length
      })

      if (update.state === 'completed' || update.state === 'interrupted') {
        downloadFolderNotices.delete(update.id)
      }

      if (update.state === 'completed' && previous.some((item) => item.id === update.id && item.state === 'completed')) return
      if (update.state === 'completed' && update.courseId !== null && update.relPath !== null && /\.pptx?$/i.test(update.relPath)) {
        const { courseId, relPath } = update
        showToastWithAction('프레젠테이션을 저장했어요. PDF 사본도 만들까요?', {
          label: 'PDF로 변환', run: () => { void convertPresentationToPdf({ courseId, relPath }) }
        })
      } else if (update.state === 'completed' && update.relPath !== null) {
        showToastWithAction(`${update.fileName}을(를) ${update.courseId ? '자료에' : '다운로드 폴더에'} 저장했어요.`, {
          label: '폴더 보기',
          run: () => { void invoke('browser:downloadFile', { id: update.id, action: 'reveal' }) }
        })
      } else if (update.state === 'interrupted') {
        showToast(
          update.failureReason === null
            ? `${update.fileName}을(를) 받지 못했어요.`
            : `${update.fileName}을(를) 저장하지 못했어요.`,
          'danger'
        )
      } else if (update.state === 'progressing' && update.courseId === null) {
        // Never silently drop it: say where it went instead.
        if (!downloadFolderNotices.has(update.id)) {
          downloadFolderNotices.add(update.id)
          showToast(`${update.fileName}은(는) 다운로드 폴더에 저장됩니다.`)
        }
      }
    })
  },

  dismiss: (id) => {
    const remaining = get().downloads.filter((item) => item.id !== id)
    set({
      downloads: remaining,
      activeCount: remaining.filter((item) => item.state === 'progressing')
        .length
    })
  }
}))
