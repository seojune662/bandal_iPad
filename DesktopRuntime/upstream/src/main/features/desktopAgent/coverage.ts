import type { DesktopToolName } from '../agentTools/schemas'

export const DESKTOP_CAPABILITIES: readonly { id: string; what: string }[] = [
  { id: 'screenshot', what: '화면을 이미지로 본다' },
  { id: 'list-windows', what: '열린 창과 디스플레이를 본다' },
  { id: 'frontmost', what: '맨 앞의 앱과 창을 확인한다' },
  { id: 'read-clipboard', what: '복사해 둔 텍스트를 읽는다' },
  { id: 'read-text', what: '화면의 글자를 추출해 읽는다' },
  { id: 'browser-url', what: '브라우저의 현재 주소를 읽는다' },
  { id: 'click', what: '화면의 항목을 누른다' },
  { id: 'type', what: '입력칸에 글을 쓴다' },
  { id: 'press-key', what: '키보드 키를 누른다' },
  { id: 'scroll', what: '화면을 스크롤한다' },
  { id: 'drag', what: '화면의 항목을 끌어 놓는다' },
  { id: 'focus-app', what: '다른 앱을 앞으로 가져온다' },
  { id: 'open-app', what: '앱을 실행한다' },
  { id: 'write-clipboard', what: '클립보드에 내용을 쓴다' },
  { id: 'file-dialog', what: '파일 선택 창을 다룬다' }
]

export const AGENT_DESKTOP_TOOLS: Record<string, DesktopToolName> = {
  screenshot: 'desktop_screenshot',
  'list-windows': 'desktop_windows',
  frontmost: 'desktop_frontmost',
  'read-clipboard': 'desktop_clipboard_read'
}

export const NOT_FOR_AGENT_DESKTOP: Record<string, string> = {
  'read-text':
    '2단계에서 화면 OCR의 정확도와 민감 정보 마스킹 기준을 먼저 검증한 뒤 제공한다.',
  'browser-url':
    '2단계에서 앱별 접근성 API의 주소 노출 범위와 브라우저 호환성을 정한 뒤 제공한다.',
  click:
    '2단계 조작 기능이다. 잘못 누르면 제출이나 구매로 이어질 수 있어 행동 정책이 먼저 필요하다.',
  type:
    '2단계 조작 기능이다. 비밀번호 칸과 외부 전송을 구조적으로 차단하는 정책이 먼저 필요하다.',
  'press-key':
    '2단계 조작 기능이다. 단축키 하나가 저장·제출·삭제를 일으킬 수 있어 허용 키 설계가 필요하다.',
  scroll:
    '2단계 조작 기능이다. 읽기 전용 표면의 안정성을 확인한 뒤 좌표와 포커스 규칙을 설계한다.',
  drag:
    '2단계 조작 기능이다. 파일 이동이나 삭제로 이어질 수 있어 대상 검증과 되돌리기가 필요하다.',
  'focus-app':
    '2단계 조작 기능이다. 학생이 작업 중인 앱의 포커스를 빼앗지 않도록 명시적인 인계가 필요하다.',
  'open-app':
    '2단계 조작 기능이다. 임의 실행을 막을 앱 허용 목록과 학생 확인 흐름이 먼저 필요하다.',
  'write-clipboard':
    '2단계 쓰기 기능이다. 학생의 기존 클립보드를 덮어쓰므로 복원과 매번 확인하는 흐름이 필요하다.',
  'file-dialog':
    '2단계 조작 기능이다. 파일 선택은 외부 전송으로 이어지므로 경로 제한과 별도 확인이 필요하다.'
}
