/**
 * 부팅 실패를 사용자에게 보이게 만든다.
 *
 * 이전에는 `initDatabase()`가 던지면 `whenReady().then(...)` 체인이 거부되면서
 * `createMainWindow()`가 아예 호출되지 않았다. 결과는 독 아이콘만 뜨고 창도
 * 메시지도 영영 없는 상태 — 사용자 입장에서는 앱이 그냥 죽은 것처럼 보인다.
 * 디스크가 가득 찼거나 DB가 손상됐거나 userData가 잠긴 경우 실제로 재현된다.
 *
 * 창을 띄울 수 없는 시점이라 렌더러 UI 대신 네이티브 다이얼로그를 쓴다.
 */

import { app, dialog, shell } from 'electron'
import { join } from 'node:path'

function describe(error: unknown): string {
  if (error instanceof Error) {
    return error.message
  }
  return String(error)
}

/**
 * 치명적 부팅 오류를 알리고 앱을 종료한다.
 *
 * `showMessageBoxSync`를 쓰는 이유: 이 시점에는 이벤트 루프를 계속 돌릴 이유가
 * 없고, 비동기 다이얼로그는 곧바로 이어지는 `app.quit()`에 잡아먹힌다.
 */
export function reportFatalStartupError(stage: string, error: unknown): void {
  const dataDir = app.getPath('userData')
  const detail = [
    `단계: ${stage}`,
    `원인: ${describe(error)}`,
    '',
    `데이터 위치: ${dataDir}`,
    '',
    '디스크 여유 공간이 부족하거나 데이터 파일이 손상됐을 때 발생해요.',
    '공간을 확보한 뒤 다시 실행해 보세요. 그래도 안 되면 위 폴더의',
    'bandal.db 파일을 다른 곳으로 옮기면 새로 만들어져요.',
    '(과목 자료와 필기는 이 폴더가 아니라 각 과목 폴더에 있으니 사라지지 않아요.)'
  ].join('\n')

  // 콘솔에도 남긴다 — 터미널에서 실행 중이면 스택까지 보인다.
  console.error(`[startup] ${stage} 실패`, error)

  const choice = dialog.showMessageBoxSync({
    type: 'error',
    title: '반달을 시작하지 못했어요',
    message: '반달을 시작하지 못했어요',
    detail,
    buttons: ['데이터 폴더 열기', '종료'],
    defaultId: 1,
    cancelId: 1,
    noLink: true
  })

  if (choice === 0) {
    // 폴더 자체가 없을 수도 있으므로 실패를 삼키지 않고 상위 폴더로 폴백한다.
    void shell.openPath(dataDir).then((message) => {
      if (message !== '') {
        void shell.openPath(join(dataDir, '..'))
      }
    })
  }

  app.exit(1)
}
