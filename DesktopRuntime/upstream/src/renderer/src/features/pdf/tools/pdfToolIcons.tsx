import type { SVGProps } from 'react'

export type PdfToolIconName =
  | 'select'
  | 'pen'
  | 'highlighter'
  | 'eraser'
  | 'text'
  | 'rect'
  | 'ellipse'
  | 'arrow'
  | 'line'
  | 'lineWidth'
  | 'opacity'
  | 'undo'
  | 'redo'
  | 'export'

export interface PdfToolIconProps extends SVGProps<SVGSVGElement> {
  name: PdfToolIconName
}

export function PdfToolIcon({ name, ...props }: PdfToolIconProps): JSX.Element {
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

const paths: Record<PdfToolIconName, JSX.Element> = {
  select: <path d="M5 3.5 19 13l-6.3 1 3.4 6-3.1 1.7-3.4-6.1-4.1 4.6z" />,
  pen: (
    <>
      <path d="m4 20 2.6-7.4 8.2-8.2 4.8 4.8-8.2 8.2z" />
      <path d="m6.6 12.6 4.8 4.8M13 6.2l4.8 4.8M4 20l5.1-5.1m0 0 2.2-2.2" />
    </>
  ),
  highlighter: (
    <>
      <path d="m5 14.5 8.7-9.7 5.5 5-8.7 9.7H5z" />
      <path d="m11.8 6.9 5.5 5M5 14.5l5.5 5M4 21h16" />
    </>
  ),
  eraser: (
    <>
      <path d="m4.2 15.2 8-9.6a1.5 1.5 0 0 1 2.1-.2l5.2 4.3a1.5 1.5 0 0 1 .2 2.1l-6.8 8.1H8.8z" />
      <path d="m9.5 8.8 5.2 4.4M4.2 15.2l5 4.2M8.8 19.9H20" />
    </>
  ),
  text: (
    <>
      <rect x="3.5" y="4" width="17" height="16" rx="1.5" />
      <path d="M8 8h8M12 8v9M9.5 17h5" />
    </>
  ),
  rect: <rect x="4" y="5" width="16" height="14" rx="1" />,
  ellipse: <ellipse cx="12" cy="12" rx="9" ry="7.5" />,
  arrow: <path d="M4 12h16m-6-6 6 6-6 6" />,
  line: <path d="M5 19 19 5" />,
  lineWidth: (
    <>
      <path d="M5 7h14" strokeWidth="1" />
      <path d="M5 12h14" strokeWidth="1.75" />
      <path d="M5 17h14" strokeWidth="2.5" />
    </>
  ),
  opacity: (
    <>
      <path d="M12 3.5S6 10.2 6 14.5a6 6 0 0 0 12 0C18 10.2 12 3.5 12 3.5Z" />
      <path d="M8.2 15h7.6A3.9 3.9 0 0 1 12 18.5 3.9 3.9 0 0 1 8.2 15Z" />
    </>
  ),
  undo: (
    <>
      <path d="M9 8H4V3" />
      <path d="M4.5 8A8 8 0 1 1 6 17.5" />
    </>
  ),
  redo: (
    <>
      <path d="M15 8h5V3" />
      <path d="M19.5 8A8 8 0 1 0 18 17.5" />
    </>
  ),
  export: (
    <>
      <path d="M6.5 3.5h7L18 8v4M13.5 3.5V8H18" />
      <path d="M12 11v8m-3-3 3 3 3-3M7 21h10" />
    </>
  )
}
