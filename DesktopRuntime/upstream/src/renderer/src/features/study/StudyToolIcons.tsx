import type { StudyToolId } from '../../../../shared/types/study'

interface StudyToolIconProps {
  tool: StudyToolId
}

const iconProps = {
  'aria-hidden': true,
  fill: 'none',
  focusable: false,
  stroke: 'currentColor',
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
  strokeWidth: 1.75,
  viewBox: '0 0 24 24',
  // An SVG with only a viewBox has no intrinsic size and stretches to fill its
  // container: in the materials context menu that turned the sparkle into a
  // full-width blob covering the menu. Matches the shared `Icon` component.
  width: '1em',
  height: '1em'
}

export function StudyToolIcon({ tool }: StudyToolIconProps): JSX.Element {
  switch (tool) {
    case 'summary':
      return (
        <svg {...iconProps}>
          <path d="M6 3.75h9l3 3v13.5H6z" />
          <path d="M15 3.75v3h3M9 11h6M9 14.5h6M9 18h4" />
        </svg>
      )
    case 'quiz':
      return (
        <svg {...iconProps}>
          <circle cx="12" cy="12" r="8.25" />
          <path d="M9.75 9.25a2.45 2.45 0 0 1 4.75.8c0 1.8-2.5 2.05-2.5 3.7M12 17.25h.01" />
        </svg>
      )
    case 'flashcards':
      return (
        <svg {...iconProps}>
          <rect x="5.25" y="6.5" width="13.5" height="11" rx="1.5" />
          <path d="M8.25 6.5V4.25h8.5v2.25M8.5 11h7M8.5 14h4.5" />
        </svg>
      )
    case 'mindmap':
      return (
        <svg {...iconProps}>
          <circle cx="12" cy="6" r="2.25" />
          <circle cx="6" cy="17.5" r="2.25" />
          <circle cx="18" cy="17.5" r="2.25" />
          <path d="M10.95 8l-3.9 7.5M13.05 8l3.9 7.5M8.25 17.5h7.5" />
        </svg>
      )
    case 'structured-notes':
      return (
        <svg {...iconProps}>
          <rect x="4.5" y="4.5" width="15" height="15" rx="1.75" />
          <path d="M9 4.5v15M9 10h10.5M12.5 7.25H16M12.5 13.25H17M12.5 16.5H15" />
        </svg>
      )
    case 'exam-predictions':
      return (
        <svg {...iconProps}>
          <path d="M8 5.5H5.5v14h13v-14H16" />
          <path d="M9 3.75h6v3.5H9zM8.5 11.5l1.5 1.5 2.5-3M8.5 16h6.5" />
        </svg>
      )
    case 'explain':
      return (
        <svg {...iconProps}>
          <path d="M4.25 5.25h15.5v11H11l-4.75 3v-3h-2z" />
          <path d="M8 9h8M8 12.5h5" />
        </svg>
      )
  }
}

export function StudyToolsIcon(): JSX.Element {
  return (
    <svg {...iconProps}>
      <path d="m12 3 1.25 3.75L17 8l-3.75 1.25L12 13l-1.25-3.75L7 8l3.75-1.25z" />
      <path d="m18 13 .75 2.25L21 16l-2.25.75L18 19l-.75-2.25L15 16l2.25-.75zM5.5 14v5M3 16.5h5" />
    </svg>
  )
}
