/**
 * Turns electron-updater failures into something a student can act on.
 *
 * Split out from index.ts so it can be tested without pulling in `electron`
 * and `electron-updater`, both of which only load inside a real Electron
 * process.
 */

/**
 * True for the failures that mean "no network right now".
 *
 * These are not errors worth a red toast: a laptop in a lecture hall is
 * offline half the time, and the 6-hour background check would otherwise nag
 * on every wake. The caller folds these into the `idle` phase.
 */
/**
 * True when the build simply has no update feed wired in.
 *
 * electron-builder writes `app-update.yml` into Resources only for real
 * targets with a `publish` config — a `--dir` build, or an app someone copied
 * out of the bundle, has none. That is "updates don't apply here", not a
 * failure, so the UI hides itself instead of showing a red toast on a loop.
 */
export function isNoFeed(message: string): boolean {
  return /app-update\.yml/i.test(message)
}

export function isOfflineish(message: string): boolean {
  return /ERR_INTERNET_DISCONNECTED|ERR_NAME_NOT_RESOLVED|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|ECONNRESET|ECONNREFUSED|net::/i.test(
    message
  )
}

export function describeError(message: string): string {
  if (isOfflineish(message)) {
    return '네트워크에 연결할 수 없어 업데이트를 확인하지 못했습니다.'
  }
  if (/code signature|Could not get code signature/i.test(message)) {
    // Squirrel.Mac refuses to swap in an update whose signature does not match
    // the running app. Almost always a locally-built or re-zipped copy, which
    // no amount of retrying will fix — so send them to a fresh download.
    return '앱 서명을 확인할 수 없어 업데이트할 수 없습니다. 홈페이지에서 최신 버전을 내려받아 주세요.'
  }
  if (/404|Cannot find|No published versions|latest-mac\.yml|latest\.yml/i.test(message)) {
    return '아직 게시된 릴리스가 없습니다.'
  }
  if (/ENOSPC|no space left/i.test(message)) {
    return '저장 공간이 부족해 업데이트를 내려받지 못했습니다.'
  }
  if (/EACCES|EPERM|permission denied/i.test(message)) {
    return '권한이 없어 업데이트를 설치하지 못했습니다. 앱을 다시 실행한 뒤 시도해 주세요.'
  }
  return `업데이트 중 문제가 발생했습니다: ${message}`
}
