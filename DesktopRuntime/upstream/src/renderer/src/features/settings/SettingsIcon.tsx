import type { ReactNode } from 'react'

export type IconName =
  | 'account'
  | 'general'
  | 'appearance'
  | 'widgets'
  | 'tabs'
  | 'ai'
  | 'assistant'
  | 'advanced'
  | 'calendar'
  | 'browser'
  | 'checklist'
  | 'courses'
  | 'experimental'
  | 'mcp'
  | 'notifications'
  | 'packs'
  | 'permissions'
  | 'privacy'
  | 'shortcuts'
  | 'usage'
  | 'university'
  | 'about'
  | 'arrow-left'
  | 'check'
  | 'folder'
  | 'search'
  | 'sparkles'

export function Icon({ name, size = 18 }: { name: IconName; size?: number }): JSX.Element {
  const paths: Record<IconName, ReactNode> = {
    calendar: <><rect x="3" y="5" width="18" height="16" rx="2" /><path d="M16 3v4M8 3v4M3 11h18M8 15h2M14 15h2" /></>,
    tabs: <><rect x="3" y="5" width="18" height="15" rx="2" /><path d="M3 10h18M9 5v5M15 5v5" /></>,
    account: (
      <>
        <circle cx="12" cy="8" r="3.5" />
        <path d="M5 20c0-3.5 3.1-5.5 7-5.5s7 2 7 5.5" />
      </>
    ),
    'arrow-left': (
      <>
        <path d="m15 18-6-6 6-6" />
        <path d="M9 12h11" />
      </>
    ),
    university: (
      <>
        <path d="M2.5 9 12 4.5 21.5 9 12 13.5z" />
        <path d="M6.5 11v4.5c0 1.4 2.5 2.5 5.5 2.5s5.5-1.1 5.5-2.5V11" />
      </>
    ),
    search: (
      <>
        <circle cx="11" cy="11" r="7" />
        <path d="m20 20-4-4" />
      </>
    ),
    general: (
      <>
        <path d="M4 6h16" />
        <path d="M4 12h16" />
        <path d="M4 18h16" />
        <circle cx="9" cy="6" r="1.7" />
        <circle cx="15" cy="12" r="1.7" />
        <circle cx="7" cy="18" r="1.7" />
      </>
    ),
    appearance: (
      <>
        <circle cx="12" cy="12" r="8" />
        <path d="M12 4a8 8 0 0 0 0 16Z" />
      </>
    ),
    widgets: (
      <>
        <rect x="3.5" y="3.5" width="7" height="7" rx="1.5" />
        <rect x="13.5" y="3.5" width="7" height="7" rx="1.5" />
        <rect x="3.5" y="13.5" width="7" height="7" rx="1.5" />
        <rect x="13.5" y="13.5" width="7" height="7" rx="1.5" />
      </>
    ),
    ai: (
      <>
        <path d="M12 3 9.8 8.8 4 11l5.8 2.2L12 19l2.2-5.8L20 11l-5.8-2.2Z" />
      </>
    ),
    assistant: (
      <>
        <circle cx="11" cy="12" r="7" />
        <circle cx="16.5" cy="7.5" r="1.5" />
      </>
    ),
    advanced: (
      <>
        <path d="M14.7 6.3a4 4 0 0 0-5 5L3.5 17.5a2.1 2.1 0 0 0 3 3l6.2-6.2a4 4 0 0 0 5-5l-2.5 2.5-3-3Z" />
      </>
    ),
    browser: (
      <>
        <circle cx="12" cy="12" r="9" />
        <path d="M3 12h18M12 3c2.2 2.5 3.3 5.5 3.3 9S14.2 18.5 12 21c-2.2-2.5-3.3-5.5-3.3-9S9.8 5.5 12 3Z" />
      </>
    ),
    checklist: (
      <>
        <circle cx="12" cy="12" r="9" />
        <path d="m8 12 2.5 2.5L16 9" />
      </>
    ),
    courses: (
      <>
        <path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v16H6.5A2.5 2.5 0 0 0 4 21.5Z" />
        <path d="M4 5.5v16" />
        <path d="M8 7h8" />
      </>
    ),
    about: (
      <>
        <circle cx="12" cy="12" r="9" />
        <path d="M12 11v6" />
        <path d="M12 7h.01" />
      </>
    ),
    experimental: (
      <>
        <path d="M9 3h6M10 3v5l-5 9a2.5 2.5 0 0 0 2.2 3.7h9.6A2.5 2.5 0 0 0 19 17l-5-9V3" />
        <path d="M7.5 15h9" />
      </>
    ),
    mcp: (
      <>
        <path d="M8 3v5M16 3v5M6 8h12v2a6 6 0 0 1-6 6v5" />
      </>
    ),
    notifications: (
      <>
        <path d="M18 9a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9" />
        <path d="M10 21h4" />
      </>
    ),
    packs: (
      <>
        <path d="M8.5 3H5a2 2 0 0 0-2 2v3.5a2.5 2.5 0 1 1 0 5V19a2 2 0 0 0 2 2h5.5a2.5 2.5 0 1 1 5 0H19a2 2 0 0 0 2-2v-5.5a2.5 2.5 0 1 1 0-5V5a2 2 0 0 0-2-2h-5.5a2.5 2.5 0 1 1-5 0Z" />
      </>
    ),
    permissions: (
      <>
        <path d="M12 3 20 6v5c0 5-3.4 8.5-8 10-4.6-1.5-8-5-8-10V6Z" />
        <path d="m9 12 2 2 4-4" />
      </>
    ),
    privacy: (
      <>
        <rect x="5" y="10" width="14" height="11" rx="2" />
        <path d="M8 10V7a4 4 0 0 1 8 0v3M12 14v3" />
      </>
    ),
    shortcuts: (
      <>
        <rect x="3" y="5" width="18" height="14" rx="2" />
        <path d="M7 9h.01M11 9h.01M15 9h.01M18 9h.01M7 13h.01M11 13h.01M15 13h3M7 16h10" />
      </>
    ),
    usage: (
      <>
        <path d="M4 20V10h4v10M10 20V4h4v16M16 20v-7h4v7" />
        <path d="M3 20h18" />
      </>
    ),
    check: <path d="m5 12 4 4L19 6" />,
    folder: (
      <>
        <path d="M3 6.5h6l2 2h10v10.5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" />
        <path d="M3 9h18" />
      </>
    ),
    sparkles: (
      <>
        <path d="m12 3 1.2 3.8L17 8l-3.8 1.2L12 13l-1.2-3.8L7 8l3.8-1.2Z" />
        <path d="m18 14 .7 2.3L21 17l-2.3.7L18 20l-.7-2.3L15 17l2.3-.7Z" />
        <path d="M5 15h.01" />
      </>
    )
  }

  return (
    <svg
      className="icon"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.75"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {paths[name]}
    </svg>
  )
}
