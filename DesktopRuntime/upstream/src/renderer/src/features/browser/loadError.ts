/**
 * What to say when a page does not load.
 *
 * Before this, `did-fail-load` only cleared the spinner: the student got a
 * blank rectangle with no indication of whether the site was down, the network
 * was off, or the address was wrong.
 *
 * Certificate failures arrive here as ordinary load errors ON PURPOSE. The app
 * registers no `certificate-error` handler, so Electron fails the load and
 * Chromium's verdict stands — there is no "proceed anyway" to offer, and no
 * code path that could add one. The only way past is the system browser, which
 * has its own vetted interstitial.
 *
 * Codes: https://source.chromium.org/chromium/chromium/src/+/main:net/base/net_error_list.h
 */

/**
 * A guest whose renderer died.
 *
 * Without this the tab became a permanently blank rect showing the PREVIOUS
 * title and URL under a live-looking toolbar: the overlay was null and the
 * anchor rect non-null, so the dead webview element just stayed on top and
 * the only fix was closing the tab.
 */
export interface BrowserCrashOverlay {
  kind: 'crashed'
  url: string
  /** 'killed' when the OS reclaimed it (usually memory pressure). */
  reason: string
}

export interface BrowserLoadErrorOverlay {
  kind: 'error'
  /** Chromium net error code (negative). */
  errorCode: number
  /** Chromium's own description, kept for the details line. */
  errorDescription: string
  /** The URL that failed, for the retry. */
  url: string
}

export type BrowserOverlay = BrowserLoadErrorOverlay | BrowserCrashOverlay | { kind: 'download'; downloadId: string }

export interface LoadErrorCopy {
  title: string
  detail: string
  /** Certificate problems are the one family where retrying is pointless. */
  canRetry: boolean
  /** Offer a handoff to the default browser (it owns the trust decision). */
  offerExternal: boolean
}

/**
 * `-3` (`ERR_ABORTED`) is not a failure. It fires whenever a load is replaced
 * — every `loadURL` over an in-flight navigation, every stop, every link
 * clicked before the previous page settled. Treating it as an error makes the
 * overlay strobe during ordinary browsing.
 */
export const ABORTED_ERROR_CODE = -3

/** Chromium's certificate family. */
function isCertificateError(code: number): boolean {
  return (code <= -200 && code >= -219) || code === -501
}

export function errorCopy(
  errorCode: number,
  host: string
): LoadErrorCopy | null {
  if (errorCode === ABORTED_ERROR_CODE) return null

  if (isCertificateError(errorCode)) {
    return {
      title: '연결이 안전하지 않습니다.',
      detail: `${host}의 인증서를 확인하지 못했습니다.`,
      canRetry: false,
      offerExternal: true
    }
  }

  switch (errorCode) {
    case -105: // ERR_NAME_NOT_RESOLVED
    case -137: // ERR_NAME_RESOLUTION_FAILED
      return {
        title: '주소를 찾지 못했습니다.',
        detail: `${host}에 해당하는 서버가 없습니다.`,
        canRetry: true,
        offerExternal: false
      }
    case -106: // ERR_INTERNET_DISCONNECTED
      return {
        title: '인터넷에 연결되어 있지 않습니다.',
        detail: '네트워크 연결을 확인해 주세요.',
        canRetry: true,
        offerExternal: false
      }
    case -109: // ERR_ADDRESS_UNREACHABLE
    case -118: // ERR_CONNECTION_TIMED_OUT
    case -102: // ERR_CONNECTION_REFUSED
    case -101: // ERR_CONNECTION_RESET
      return {
        title: '서버에 연결하지 못했습니다.',
        detail: `${host}이(가) 응답하지 않습니다.`,
        canRetry: true,
        offerExternal: false
      }
    case -7: // ERR_TIMED_OUT
      return {
        title: '응답 시간이 초과되었습니다.',
        detail: `${host}이(가) 제때 응답하지 않았습니다.`,
        canRetry: true,
        offerExternal: false
      }
    default:
      return {
        title: '페이지를 열지 못했습니다.',
        detail: `${host}에서 문제가 발생했습니다.`,
        canRetry: true,
        offerExternal: true
      }
  }
}
