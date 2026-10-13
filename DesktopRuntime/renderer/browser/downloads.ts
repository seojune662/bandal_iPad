import type { BrowserDownloadUpdate } from '../../upstream/src/shared/ipc/events'
import { showToast } from '../../upstream/src/renderer/src/app/toast'
import { browserRequest } from './BrowserSiteControls'

type Download = BrowserDownloadUpdate & { finishedAt: number | null }
type State = { downloads: Download[]; activeCount: number }
export function restoreDownloads(set: (state: Partial<State>) => void, get: () => State): void {
  void browserRequest('browser:downloadsSnapshot', {}).then(value => {
    const current = get().downloads
    const updates = value as BrowserDownloadUpdate[]
    const downloads = [...current, ...updates.filter(item => !current.some(existing => existing.id === item.id))
      .map(item => ({ ...item, finishedAt: item.state === 'progressing' ? null : Date.now() }))]
    set({ downloads, activeCount: downloads.filter(item => item.state === 'progressing').length })
  }).catch(() => showToast('다운로드 기록을 불러오지 못했어요.', 'danger'))
}
export function dismissNativeDownload(id: string): void {
  void browserRequest('browser:dismissDownload', { id }).catch(() => showToast('다운로드 기록을 지우지 못했어요.', 'danger'))
}
