/**
 * Single source of truth for "which permission does this API method need".
 * The broker enforces it; tests assert every method is listed (the
 * `satisfies Record<…>` makes forgetting a compile error).
 */

import {
  PLUGIN_NET_PERMISSION_PREFIX,
  PLUGIN_PERMISSIONS,
  type PluginPermission,
  type PluginStaticPermission
} from '../types/plugin'
import type { PluginApiMethod } from '../types/pluginRpc'

/** `'net'` means "checked against the `net:<host>` grants with the URL". */
export const PLUGIN_API_PERMISSIONS = {
  'courses.list': 'courses.read',
  'courses.current': 'courses.read',
  'notes.list': 'notes.read',
  'notes.read': 'notes.read',
  'notes.write': 'notes.write',
  'notes.create': 'notes.write',
  'materials.list': 'materials.read',
  'materials.readText': 'materials.read',
  'notices.show': 'notices',
  'settings.get': 'settings',
  'settings.set': 'settings',
  'panel.post': 'panel',
  'panel.open': 'panel',
  'panel.close': 'panel',
  'net.fetch': 'net',
  'editor.getSelection': 'editor.read',
  'editor.replaceSelection': 'editor.write'
} as const satisfies Record<PluginApiMethod, PluginStaticPermission | 'net'>

const STATIC_PERMISSIONS = new Set<string>(PLUGIN_PERMISSIONS)

export function isStaticPermission(
  value: string
): value is PluginStaticPermission {
  return STATIC_PERMISSIONS.has(value)
}

/** Hostname granted by a `net:<host>` permission, or null. */
export function netPermissionHost(permission: string): string | null {
  if (!permission.startsWith(PLUGIN_NET_PERMISSION_PREFIX)) return null
  const host = permission.slice(PLUGIN_NET_PERMISSION_PREFIX.length)
  return host.length === 0 ? null : host
}

/**
 * Whether `granted` covers `method`. For `net.fetch` pass the request URL;
 * only exact-hostname https grants match (no wildcards, no ports, no http).
 */
export function isMethodAllowed(
  granted: readonly PluginPermission[],
  method: PluginApiMethod,
  url?: string
): boolean {
  const required = PLUGIN_API_PERMISSIONS[method]
  if (required !== 'net') return granted.includes(required)
  if (url === undefined) return false
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return false
  }
  if (parsed.protocol !== 'https:' || parsed.port !== '') return false
  const host = parsed.hostname.toLowerCase()
  return granted.some((permission) => netPermissionHost(permission) === host)
}

const DESCRIPTIONS_KO: Record<PluginStaticPermission, string> = {
  'courses.read': '과목 목록과 현재 과목 읽기',
  'notes.read': '노트 내용 읽기',
  'notes.write': '노트 만들기·수정하기',
  'materials.read': '자료 목록과 텍스트 파일 읽기',
  commands: '명령 등록(메뉴·단축키)',
  panel: '패널 탭 열기·메시지 주고받기',
  notices: '알림(토스트) 표시',
  settings: '플러그인 자체 설정 저장',
  'editor.read': '활성 필기와 선택 영역 읽기',
  'editor.write': '활성 필기의 선택 텍스트 수정',
  menus: '필기·자료 문맥 메뉴 추가',
  themes: '앱 테마 등록',
  events: '노트 저장·과목 변경 이벤트 받기'
}

const DESCRIPTIONS_EN: Record<PluginStaticPermission, string> = {
  'courses.read': 'Read the course list and the current course',
  'notes.read': 'Read note contents',
  'notes.write': 'Create and edit notes',
  'materials.read': 'Read the materials tree and text files',
  commands: 'Register commands (menus, shortcuts)',
  panel: 'Open a panel tab and exchange messages with it',
  notices: 'Show notifications (toasts)',
  settings: 'Store its own settings',
  'editor.read': 'Read the active note and selection',
  'editor.write': 'Edit the selected text in the active note',
  menus: 'Add editor and material context menus',
  themes: 'Register app themes',
  events: 'Receive note-saved and course-changed events'
}

export function describePermission(
  permission: PluginPermission,
  locale: 'ko-KR' | 'en-US' = 'ko-KR'
): string {
  const host = netPermissionHost(permission)
  if (host !== null) {
    return locale === 'ko-KR'
      ? `${host} 에 HTTPS 요청 보내기`
      : `Send HTTPS requests to ${host}`
  }
  const table = locale === 'ko-KR' ? DESCRIPTIONS_KO : DESCRIPTIONS_EN
  return table[permission as PluginStaticPermission] ?? permission
}
