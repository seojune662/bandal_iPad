import type { SVGProps } from 'react'

export type IconName =
  | 'user'
  | 'archive'
  | 'chevronLeft'
  | 'chevronRight'
  | 'file'
  | 'fileImage'
  | 'filePdf'
  | 'fileText'
  | 'folder'
  | 'folderOpen'
  | 'folderPlus'
  | 'graph'
  | 'help'
  | 'layoutLeft'
  | 'layoutRight'
  | 'link'
  | 'pencil'
  | 'plus'
  | 'puzzle'
  | 'refresh'
  | 'search'
  | 'settings'
  | 'trash'
  | 'x'

interface IconProps extends SVGProps<SVGSVGElement> {
  name: IconName
}

export function Icon({ name, ...props }: IconProps): JSX.Element {
  const common = {
    fill: 'none',
    stroke: 'currentColor',
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
    strokeWidth: 1.75
  }

  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      width="1em"
      height="1em"
      {...props}
    >
      <g {...common}>{paths[name]}</g>
    </svg>
  )
}

const paths: Record<IconName, JSX.Element> = {
  user: (<>
    <circle cx="12" cy="8" r="3.5" />
    <path d="M5 21v-2a7 7 0 0 1 14 0v2" />
  </>),
  archive: (
    <>
      <path d="M4 7.5h16v11a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 18.5z" />
      <path d="M3 4h18v3.5H3zM9 12h6" />
    </>
  ),
  chevronLeft: <path d="m15 18-6-6 6-6" />,
  chevronRight: <path d="m9 18 6-6-6-6" />,
  file: (
    <>
      <path d="M6.5 3.5h7L18 8v12.5H6.5z" />
      <path d="M13.5 3.5V8H18" />
    </>
  ),
  fileImage: (
    <>
      <path d="M6.5 3.5h7L18 8v12.5H6.5z" />
      <path d="M13.5 3.5V8H18M8.5 17l2.5-2.5 1.8 1.8 1.5-1.5 1.7 2.2" />
      <circle cx="10" cy="11" r="1" />
    </>
  ),
  filePdf: (
    <>
      <path d="M6.5 3.5h7L18 8v12.5H6.5z" />
      <path d="M13.5 3.5V8H18M8.5 16h1.25a1.25 1.25 0 0 0 0-2.5H8.5V18M12.5 13.5V18h1a2 2 0 0 0 2-2.25v0a2 2 0 0 0-2-2.25z" />
    </>
  ),
  fileText: (
    <>
      <path d="M6.5 3.5h7L18 8v12.5H6.5z" />
      <path d="M13.5 3.5V8H18M9 12h6M9 15h6M9 18h4" />
    </>
  ),
  folder: <path d="M3.5 6.5h6l2-2h3l2 2h4v12.5h-17z" />,
  folderOpen: <path d="M3.5 7h6l2-2h3l2 2h4l-2 11.5h-17z" />,
  folderPlus: (
    <>
      <path d="M3.5 6.5h6l2-2h3l2 2h4v12.5h-17z" />
      <path d="M12 9.5v6M9 12.5h6" />
    </>
  ),
  graph: (
    <>
      <circle cx="6" cy="6" r="2.6" />
      <circle cx="18" cy="9.5" r="2.6" />
      <circle cx="10.5" cy="18" r="2.6" />
      <path d="M8.5 6.8 15.5 8.9M6.9 8.4l2.7 7.2M16.2 11.5l-4 4.6" />
    </>
  ),
  help: (
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="M9.6 9a2.5 2.5 0 1 1 4 2c-1 .7-1.6 1.2-1.6 2.5M12 17h.01" />
    </>
  ),
  layoutLeft: (
    <>
      <rect x="3.5" y="4" width="17" height="16" rx="2" />
      <path d="M9 4v16" />
    </>
  ),
  layoutRight: (
    <>
      <rect x="3.5" y="4" width="17" height="16" rx="2" />
      <path d="M15 4v16" />
    </>
  ),
  link: (
    <>
      <path d="M10.5 13.5a4 4 0 0 0 5.7 0l2.6-2.6a4 4 0 0 0-5.7-5.7l-1.3 1.3" />
      <path d="M13.5 10.5a4 4 0 0 0-5.7 0l-2.6 2.6a4 4 0 0 0 5.7 5.7l1.3-1.3" />
    </>
  ),
  pencil: (
    <>
      <path d="m4 20 4.2-1 10.7-10.7-3.2-3.2L5 15.8z" />
      <path d="m13.8 7 3.2 3.2" />
    </>
  ),
  plus: <path d="M12 5v14M5 12h14" />,
  puzzle: (
    <path d="M4 4h6v3a2 2 0 1 0 4 0V4h6v6h-3a2 2 0 1 0 0 4h3v6h-6v-3a2 2 0 1 0-4 0v3H4v-6h3a2 2 0 1 0 0-4H4z" />
  ),
  refresh: (
    <>
      <path d="M20 7v5h-5" />
      <path d="M18.4 16A8 8 0 1 1 20 12" />
    </>
  ),
  search: (
    <>
      <circle cx="10.5" cy="10.5" r="6.5" />
      <path d="m15.5 15.5 4.5 4.5" />
    </>
  ),
  settings: (
    <>
      <circle cx="12" cy="12" r="3" />
      <path d="M19 13.5v-3l-2-.7-.6-1.5.9-1.9-2.1-2.1-1.9.9-1.5-.6L11 3H8l-.7 2.2-1.5.6-1.9-.9-2.1 2.1.9 1.9-.6 1.5L0 11v3l2.1.7.6 1.5-.9 1.9 2.1 2.1 1.9-.9 1.5.6L8 22h3l.7-2.1 1.5-.6 1.9.9 2.1-2.1-.9-1.9.6-1.5z" transform="translate(1 -1) scale(.92)" />
    </>
  ),
  trash: (
    <>
      <path d="M5 7h14M9 7V4h6v3M7 7l1 13h8l1-13M10 11v5M14 11v5" />
    </>
  ),
  x: <path d="m6 6 12 12M18 6 6 18" />
}
