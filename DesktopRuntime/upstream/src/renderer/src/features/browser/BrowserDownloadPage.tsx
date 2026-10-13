import { invoke } from '../../lib/ipc'
import { showToast } from '../../app/toast'
import { useCoursesStore } from '../../stores/coursesStore'
import { useDownloads } from './downloadsStore'
import { BrowserIcon } from './browserIcons'

/** Directly opening a download URL has no document to display. */
export function BrowserDownloadPage({ id }: { id: string }): JSX.Element {
  const download = useDownloads((state) => state.downloads.find((item) => item.id === id))
  const course = useCoursesStore((state) => state.courses.find((item) => item.id === download?.courseId))
  const action = (action: 'open' | 'reveal' | 'saveAs' | 'retry'): void => {
    void invoke('browser:downloadFile', { id, action }).catch(() => {
      showToast('파일을 처리하지 못했어요. 저장 위치를 확인해 주세요.', 'danger')
    })
  }
  const title = !download ? '다운로드' : download.state === 'completed' ? '다운로드 완료'
    : download.state === 'cancelled' ? '다운로드 취소' : download.state === 'interrupted' ? '다운로드를 확인해 주세요' : '파일을 다운로드하고 있어요'
  return <div className="browser-error" role="status">
    <BrowserIcon name="download" />
    <h2 className="browser-error__title">{title}</h2>
    <p>{download?.fileName}</p>
    {download && <p className="browser-error__detail">
      {download.failureReason ?? (course ? `${course.name} · 과목 자료` : '다운로드 폴더')}
      {download.state === 'progressing' && ` · ${Math.round(download.receivedBytes / 1024)}KB${download.totalBytes > 0 ? ` / ${Math.round(download.totalBytes / 1024)}KB` : ''}`}
    </p>}
    {(download?.state === 'completed' || download?.recoverable) && <div className="browser-error__actions">
      {download.state === 'completed' && <button className="browser-error__action" onClick={() => action('open')}>파일 열기</button>}
      <button className="browser-error__action" onClick={() => action('reveal')}>폴더 보기</button>
      <button className="browser-error__action" onClick={() => action('saveAs')}>다른 위치에 저장</button>
      {download.recoverable && <button className="browser-error__action" onClick={() => action('retry')}>다시 저장</button>}
    </div>}
  </div>
}
