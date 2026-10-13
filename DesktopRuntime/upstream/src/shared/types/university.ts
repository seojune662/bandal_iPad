/**
 * University service presets (docs/university-sites.md §6).
 *
 * The preset catalog is a static, app-versioned module (NOT a DB table) —
 * URLs rot, and shipping fixes with the app is simpler than migrating rows.
 * Anything the *user* creates (custom school, custom service, per-course
 * link) lives in settings / SQLite and always wins over a preset.
 *
 * Repo conventions: string-literal unions instead of `enum`, `interface` for
 * object shapes, every field JSON-serializable (presets travel through IPC
 * and settings.json unchanged).
 */

/** What a shortcut is, semantically. Drives sidebar grouping + icon. */
export type ServiceKind =
  | 'portal' // 학사정보시스템 / 포털
  | 'lms' // LMS / 강의지원
  | 'library' // 도서관
  | 'mail' // 웹메일
  | 'registration' // 수강신청
  | 'homepage' // 학교 홈페이지
  | 'community' // 에브리타임 같은 캠퍼스 커뮤니티
  | 'other' // 비교과, 증명발급, 식단 …

export const SERVICE_KINDS: readonly ServiceKind[] = [
  'portal',
  'lms',
  'registration',
  'library',
  'mail',
  'homepage',
  'community',
  'other'
]

/** LMS vendor — decides how a pasted course URL is parsed. */
export type LmsPlatform =
  | 'canvas' // includes Xinics LearningX (Canvas core)
  | 'moodle' // includes Coursemos / 유비온 / OKlass distributions
  | 'ilos' // Korean domestic LMS, `.acl` endpoints
  | 'blackboard'
  | 'unknown'

/** How confident we are that `url` is correct and current. */
export type VerificationLevel = 'verified' | 'partial' | 'unverified'

/**
 * Why a service refuses to work inside the embedded browser. Three classes
 * exist (docs/university-sites.md §5.2); the reason drives the tooltip copy.
 */
export type ExternalReason =
  /** Google / Microsoft reject embedded webviews (`disallowed_useragent`). */
  | 'federated-login'
  /** UA sniffing that fails closed on anything it cannot classify. */
  | 'ua-sniffing'
  /** ActiveX / NPAPI / keyboard-security agents — structurally impossible. */
  | 'native-plugin'

export interface UniversityService {
  /** Stable, university-scoped. Never renamed — settings reference it. */
  id: string // 'snu.etl'
  kind: ServiceKind
  /** 한글 표시명 — sidebar label. Keep it short (≤ 8자). */
  label: string
  labelEn?: string
  url: string
  /**
   * True when the site cannot work in the embedded browser (Google/Microsoft
   * login, UA sniffing, native security plugins). Opens in the system browser.
   */
  opensExternally?: boolean
  /** Set whenever `opensExternally` is true — drives the tooltip. */
  externalReason?: ExternalReason
  /** Hidden behind 더보기 by default (legacy systems, niche services). */
  secondary?: boolean
  verification: VerificationLevel
  /** Free-form caveat surfaced in settings, not in the sidebar. */
  note?: string
}

/** How to recognise and build a per-course deep link for this school. */
export interface CourseLinkSpec {
  platform: LmsPlatform
  /** `{id}` is substituted. */
  template: string // 'https://myetl.snu.ac.kr/courses/{id}'
  /**
   * Anchored regex source with exactly one capture group = the course id.
   * Used to validate + normalise a URL the student pasted.
   */
  idPattern: string // '^https://myetl\\.snu\\.ac\\.kr/courses/(\\d+)'
  /** 한글 안내 shown in the "과목 링크 추가" dialog. */
  hint: string
  /** false → show a "베타" badge (e.g. iLOS KJKEY). */
  reliable: boolean
}

export interface University {
  /** Stable slug. Never change — persisted in settings. */
  id: string // 'snu'
  nameKo: string
  nameEn: string
  /** Onboarding search terms: '서울대', 'SNU', 'seoul national'. */
  aliases: readonly string[]
  /** Used for custom-entry dedupe and course-link host hints. */
  domain: string // 'snu.ac.kr'
  services: readonly UniversityService[]
  courseLink?: CourseLinkSpec
  /** ISO date of last URL verification — surfaced in settings as "확인일". */
  verifiedAt: string
}

/**
 * User settings layered on top of the preset catalog. Anything here always
 * wins: an app update may fix a preset URL but must never clobber a link the
 * student edited themselves (docs/university-sites.md §7.3-16).
 */
export interface UniversitySettings {
  /** Preset id, or `custom:<uuid>`. null = 아직 학교 안 고름. */
  universityId: string | null
  /** Definition for a school the catalog does not know (id starts `custom:`). */
  customUniversity: University | null
  /** Preset service ids the user hid. */
  hiddenServiceIds: readonly string[]
  /** User-added services. Rendered after presets, within the same kind group. */
  customServices: readonly UniversityService[]
  /** Per-service override of the embedded/external decision. */
  openExternallyOverrides: Readonly<Record<string, boolean>>
  /**
   * Full sidebar order by service id (presets, common and custom alike).
   * Unknown ids are ignored; ids not listed here follow, in catalog order.
   * Empty = catalog order.
   */
  serviceOrder: readonly string[]
  /**
   * Per-service override of the 더보기 tier: true = behind 더보기,
   * false = always visible. Mirrors `openExternallyOverrides`.
   */
  secondaryOverrides: Readonly<Record<string, boolean>>
}

export const DEFAULT_UNIVERSITY_SETTINGS: UniversitySettings = {
  universityId: null,
  customUniversity: null,
  hiddenServiceIds: [],
  customServices: [],
  openExternallyOverrides: {},
  serviceOrder: [],
  secondaryOverrides: {}
}

/** What the 직접 추가 flow collects — only the name is required. */
export interface CustomUniversityInput {
  nameKo: string
  /** Optional; a pasted course URL is enough to infer the host + platform. */
  courseUrl?: string
}
