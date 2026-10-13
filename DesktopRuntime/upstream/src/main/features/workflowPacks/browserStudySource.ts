import { ValidationError } from '../../db/errors'
import type { BrowsingContext } from '../browser/browsingContext'
import type { GuestWebContents } from '../browserAgent/guestRegistry'

/** A renderer URL is usable only while its actual native tab has that owner. */
export function assertLiveStudyBrowserSource(
  input: { courseId: string; relPath: string | null; browserTabUrl?: string; browserTabId?: string },
  guest: Pick<GuestWebContents, 'id' | 'getURL' | 'isDestroyed'> | null,
  owner: BrowsingContext | undefined
): void {
  if (input.browserTabUrl === undefined && input.browserTabId === undefined) return
  if (input.relPath !== null || !input.browserTabUrl || !input.browserTabId) throw new ValidationError('브라우저 원문과 파일 대상은 함께 지정할 수 없습니다.')
  if (!guest || guest.isDestroyed() || owner?.courseId !== input.courseId || owner.tabId !== input.browserTabId || guest.getURL() !== input.browserTabUrl) {
    throw new ValidationError('브라우저 원문이 닫혔거나 이동했어요. 해당 과목의 열린 글을 다시 선택해 주세요.')
  }
}
