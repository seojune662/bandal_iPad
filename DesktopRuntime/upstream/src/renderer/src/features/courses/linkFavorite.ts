import type { CreateFavoriteInput } from '../../../../shared/types/favorite'
import { looksLikeUrl, normalizeUrl } from '../workspace/tabIdentity'

/** Builds the browser descriptor stored by the existing favorites IPC. */
export function buildLinkFavoriteInput(
  courseId: string | null,
  urlInput: string,
  labelInput: string,
  tabId: string
): CreateFavoriteInput {
  const label = labelInput.trim()
  if (!looksLikeUrl(urlInput)) {
    throw new Error('올바른 http(s) 주소를 입력해 주세요.')
  }
  if (label.length === 0) {
    throw new Error('링크 이름을 입력해 주세요.')
  }
  if (tabId.trim().length === 0) {
    throw new Error('링크 탭 식별자가 필요합니다.')
  }

  return {
    courseId,
    label,
    descriptor: {
      kind: 'browser',
      payload: {
        tabId,
        initialUrl: normalizeUrl(urlInput)
      }
    }
  }
}
