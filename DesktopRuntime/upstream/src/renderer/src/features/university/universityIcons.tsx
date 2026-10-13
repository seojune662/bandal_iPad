/**
 * Icons for university shortcuts. Same 24-grid / stroke conventions as
 * `app/icons.tsx`; kept local because these names only mean something inside
 * the 학교 바로가기 surface.
 */

import type { SVGProps } from 'react'
import type { ServiceKind } from '../../../../shared/types/university'

const STROKE = {
  fill: 'none',
  stroke: 'currentColor',
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
  strokeWidth: 1.75
}

const KIND_PATHS: Record<ServiceKind, JSX.Element> = {
  portal: (
    <>
      <rect x="3.5" y="5" width="17" height="14" rx="2" />
      <path d="M3.5 9.5h17M8 14h4" />
    </>
  ),
  lms: (
    <>
      <path d="M2.5 9 12 4.5 21.5 9 12 13.5z" />
      <path d="M6.5 11v4.5c0 1.4 2.5 2.5 5.5 2.5s5.5-1.1 5.5-2.5V11" />
    </>
  ),
  registration: (
    <>
      <rect x="3.5" y="5" width="17" height="15" rx="2" />
      <path d="M3.5 9.5h17M8 3.5v3M16 3.5v3M9 14.5l2 2 4-4" />
    </>
  ),
  library: (
    <>
      <path d="M4 5.5A1.5 1.5 0 0 1 5.5 4H11v16H5.5A1.5 1.5 0 0 1 4 18.5z" />
      <path d="M20 5.5A1.5 1.5 0 0 0 18.5 4H13v16h5.5a1.5 1.5 0 0 0 1.5-1.5z" />
    </>
  ),
  mail: (
    <>
      <rect x="3" y="5.5" width="18" height="13" rx="2" />
      <path d="m3.5 7 8.5 6 8.5-6" />
    </>
  ),
  homepage: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M3.5 12h17M12 3.5c2.2 2.4 3.3 5.3 3.3 8.5s-1.1 6.1-3.3 8.5c-2.2-2.4-3.3-5.3-3.3-8.5S9.8 5.9 12 3.5" />
    </>
  ),
  community: (
    // Two overlapping speech bubbles — the back one only draws its visible edge.
    <>
      <path d="M3.5 5.5h10A1.5 1.5 0 0 1 15 7v5a1.5 1.5 0 0 1-1.5 1.5H8l-3.5 3v-3h-1A1.5 1.5 0 0 1 2 12V7a1.5 1.5 0 0 1 1.5-1.5z" />
      <path d="M15 9.5h4.5A1.5 1.5 0 0 1 21 11v5a1.5 1.5 0 0 1-1.5 1.5h-1v3l-3.5-3H10A1.5 1.5 0 0 1 8.5 16v-2.5" />
    </>
  ),
  other: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 8v4.5l3 1.8" />
    </>
  )
}

export function ServiceKindIcon({
  kind,
  ...props
}: SVGProps<SVGSVGElement> & { kind: ServiceKind }): JSX.Element {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" width="1em" height="1em" {...props}>
      <g {...STROKE}>{KIND_PATHS[kind]}</g>
    </svg>
  )
}

/** "Leaves the app" marker — shown on every `opensExternally` shortcut. */
export function ExternalIcon(props: SVGProps<SVGSVGElement>): JSX.Element {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" width="1em" height="1em" {...props}>
      <g {...STROKE}>
        <path d="M14 4.5h5.5V10M19.5 4.5 11 13" />
        <path d="M18 14.5v4a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6h4" />
      </g>
    </svg>
  )
}
