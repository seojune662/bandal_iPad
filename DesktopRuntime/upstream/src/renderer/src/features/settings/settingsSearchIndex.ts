import {
  SETTINGS_CATEGORIES,
  type SettingsCategoryId
} from '../../../../shared/settingsCategories'
import type { Locale } from '../../i18n'
import { enUS } from '../../i18n/messages/en-US'
import { koKR } from '../../i18n/messages/ko-KR'
import type { PluginManifest } from '../../../../shared/types/plugin'

interface SettingsSearchRow {
  category: SettingsCategoryId
  ko: string
  en: string
}

export interface SettingsSearchResult {
  category: SettingsCategoryId
  matches: string[]
}

export const SETTINGS_SEARCH_ROWS = [
  { category: 'calendar', ko: 'Apple 캘린더 · iCloud · 일정 보기 · 과제 보내기', en: 'Apple Calendar, iCloud, events and export assignments' },
  { category: 'tabs', ko: '녹음 모델 · 마이크 · 자막 · 재생 속도', en: 'Recording models, microphone, captions and playback speed' },
  { category: 'tabs', ko: '마크다운 · 브라우저 · AI · 화이트보드 · 학업 보드', en: 'Markdown, browser, AI, whiteboard and study board' },
  { category: 'ai', ko: 'AI 엔진', en: 'AI engine' },
  { category: 'ai', ko: 'Gemini', en: 'Gemini' },
  { category: 'ai', ko: '모델', en: 'Model' },
  { category: 'assistant', ko: '화면 도우미', en: 'Screen assistant' },
  { category: 'account', ko: '로그인', en: 'Sign in' },
  { category: 'account', ko: '프로필', en: 'Profile' },
  { category: 'account', ko: '닉네임', en: 'Nickname' },
  { category: 'general', ko: '언어', en: 'Language' },
  { category: 'general', ko: '탭 열기', en: 'Open tabs' },
  { category: 'general', ko: '마지막 과목 복원', en: 'Restore last course' },
  { category: 'general', ko: '온보딩', en: 'Onboarding' },
  { category: 'packs', ko: 'MCP 서버', en: 'MCP servers' },
  { category: 'packs', ko: '서버 연결', en: 'Server connections' },
  { category: 'university', ko: '학교', en: 'University' },
  { category: 'university', ko: '즐겨찾기 서비스', en: 'Favorite services' },
  { category: 'packs', ko: '플러그인', en: 'Plugins' },
  { category: 'packs', ko: '워크플로 팩', en: 'Workflow packs' },
  { category: 'packs', ko: '카탈로그', en: 'Catalog' },
  { category: 'packs', ko: '소스', en: 'Sources' },
  { category: 'packs', ko: '개발자 센터', en: 'Developer center' },
  { category: 'packs', ko: '로컬 개발', en: 'Local development' },
  { category: 'packs', ko: '설치됨', en: 'Installed' },
  { category: 'browser', ko: '에이전트 브라우저 사용', en: 'Agent browser access' },
  { category: 'browser', ko: '홈페이지', en: 'Home page' },
  { category: 'browser', ko: '검색 엔진', en: 'Search engine' },
  { category: 'browser', ko: '기본 줌', en: 'Default zoom' },
  { category: 'browser', ko: '링크 열기', en: 'Open links' },
  { category: 'browser', ko: '브라우징 데이터', en: 'Browsing data' },
  { category: 'appearance', ko: '테마', en: 'Theme' },
  { category: 'appearance', ko: '팔레트', en: 'Palette' },
  { category: 'appearance', ko: '글자 크기', en: 'Text size' },
  { category: 'appearance', ko: '밀도', en: 'Density' },
  { category: 'notifications', ko: '알림 켜기', en: 'Enable notifications' },
  { category: 'notifications', ko: '마감 알림', en: 'Deadline reminders' },
  { category: 'notifications', ko: 'AI 응답 완료', en: 'AI response complete' },
  { category: 'notifications', ko: '다운로드', en: 'Downloads' },
  { category: 'notifications', ko: '소리', en: 'Sound' },
  { category: 'notifications', ko: '포커스 중 억제', en: 'Suppress while focused' },
  { category: 'shortcuts', ko: '단축키', en: 'Keyboard shortcuts' },
  { category: 'shortcuts', ko: '웹뷰 우선권', en: 'Webview priority' },
  { category: 'usage', ko: '사용 통계', en: 'Stats & usage' },
  { category: 'usage', ko: '토큰', en: 'Tokens' },
  { category: 'usage', ko: 'AI 작업 시간', en: 'AI work time' },
  { category: 'usage', ko: '제공자별 사용량', en: 'Usage by provider' },
  { category: 'permissions', ko: '시스템 권한', en: 'System permissions' },
  { category: 'permissions', ko: '화면 읽기', en: 'Screen reading' },
  { category: 'permissions', ko: '손쉬운 사용', en: 'Accessibility' },
  { category: 'privacy', ko: '개인정보·진단', en: 'Privacy & diagnostics' },
  { category: 'privacy', ko: '진단 파일', en: 'Diagnostics file' },
  { category: 'privacy', ko: '피드백', en: 'Feedback' },
  { category: 'advanced', ko: '데이터 폴더', en: 'Data folder' },
  { category: 'advanced', ko: '로그 폴더', en: 'Log folder' },
  { category: 'advanced', ko: '캐시 비우기', en: 'Clear cache' },
  { category: 'advanced', ko: '설정 초기화', en: 'Reset settings' },
  { category: 'experimental', ko: '확장 런타임', en: 'Extension runtime' },
  { category: 'courses', ko: '과목 보관', en: 'Archive courses' },
  { category: 'courses', ko: '보관된 과목', en: 'Archived courses' },
  { category: 'about', ko: '버전', en: 'Version' },
  { category: 'about', ko: '업데이트', en: 'Updates' }
] as const satisfies readonly SettingsSearchRow[]

function normalized(value: string, locale: Locale): string {
  return value.toLocaleLowerCase(locale)
}

export function searchSettings(
  query: string,
  locale: Locale,
  plugins: readonly PluginManifest[] = []
): SettingsSearchResult[] {
  const needle = normalized(query.trim(), locale)
  if (needle.length === 0) {
    return SETTINGS_CATEGORIES.map(({ id }) => ({ category: id, matches: [] }))
  }

  const messages: Readonly<Record<string, string>> =
    locale === 'ko-KR' ? koKR : enUS
  return SETTINGS_CATEGORIES.flatMap(({ id }) => {
    const rows: SettingsSearchRow[] = SETTINGS_SEARCH_ROWS.filter((row) => row.category === id)
    if (id === 'packs') for (const plugin of plugins) {
      rows.push({ category: id, ko: plugin.name, en: plugin.name })
      for (const field of plugin.contributes.settings ?? []) rows.push({ category: id, ko: field.title, en: field.title })
    }
    const matches = [...new Set(rows
      .map((row) => (locale === 'ko-KR' ? row.ko : row.en))
      .filter((label) => normalized(label, locale).includes(needle)))]
    const categoryText = ['label', 'description', 'keywords']
      .map((field) => messages[`settings.category.${id}.${field}`] ?? '')
      .join(' ')

    return matches.length > 0 || normalized(categoryText, locale).includes(needle)
      ? [{ category: id, matches }]
      : []
  })
}
