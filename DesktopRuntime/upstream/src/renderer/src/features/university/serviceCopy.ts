/**
 * Korean copy for university shortcuts (pure — no React, no IPC).
 *
 * Tone: 앱 본체는 해요체 (docs/STYLEGUIDE.md §7). Every string that explains
 * *why* something leaves the app has to answer the student's real question —
 * "왜 여기서 안 열려요?" — in one line, without blaming them or the school.
 */

import type { ExternalReason } from '../../../../shared/types/university'

/** Tooltip on a shortcut that opens in the system browser. */
export function externalReasonMessage(reason: ExternalReason | undefined): string {
  switch (reason) {
    case 'federated-login':
      return '이 사이트는 앱 안에서 로그인이 막혀 있어 기본 브라우저로 열려요.'
    case 'ua-sniffing':
      return '이 사이트는 앱 안의 브라우저를 알아보지 못해서 기본 브라우저로 열려요.'
    case 'native-plugin':
      return '이 사이트는 따로 설치하는 보안 프로그램이 필요해서 기본 브라우저로 열려요.'
    default:
      return '이 사이트는 앱 안에서 열리지 않아 기본 브라우저로 열려요.'
  }
}
