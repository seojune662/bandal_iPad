import type { Settings } from '../../../shared/types/settings'

export type NotificationKind =
  | 'deadline'
  | 'agentComplete'
  | 'download'
  | 'plugin'

export interface NotifyInput {
  kind: NotificationKind
  title: string
  body: string
  courseId?: string | null
  onClick?: () => void
}

export type NotifyResult =
  | 'sent'
  | 'disabled'
  | 'suppressed'
  | 'unsupported'

export interface Notifier {
  notify(input: NotifyInput): NotifyResult
  test(): { ok: boolean; reason: 'unsupported' | null }
}

export interface NotifierDeps {
  getSettings: () => Settings
  isSupported: () => boolean
  isAppFocused: () => boolean
  show: (
    opts: { title: string; body: string; silent: boolean },
    onClick?: () => void
  ) => void
}

function isKindEnabled(
  kind: NotificationKind,
  settings: Settings['notifications']
): boolean {
  if (kind === 'deadline') return settings.deadlines
  if (kind === 'agentComplete') return settings.agentComplete
  if (kind === 'download') return settings.downloads
  return settings.pluginNotices
}

export function createNotifier(deps: NotifierDeps): Notifier {
  return {
    notify(input) {
      if (!deps.isSupported()) return 'unsupported'
      const settings = deps.getSettings()
      const notifications = settings.notifications
      if (!notifications.enabled || !isKindEnabled(input.kind, notifications)) {
        return 'disabled'
      }
      const activeCourse =
        input.courseId === null || input.courseId === undefined ||
        input.courseId === settings.lastActiveCourseId
      if (
        notifications.suppressWhileFocused &&
        deps.isAppFocused() &&
        activeCourse
      ) {
        return 'suppressed'
      }
      deps.show(
        {
          title: input.title,
          body: input.body,
          silent: !notifications.sound
        },
        input.onClick
      )
      return 'sent'
    },
    test() {
      if (!deps.isSupported()) return { ok: false, reason: 'unsupported' }
      deps.show({
        title: '반달 알림',
        body: '테스트 알림이 도착했어요',
        silent: false
      })
      return { ok: true, reason: null }
    }
  }
}
