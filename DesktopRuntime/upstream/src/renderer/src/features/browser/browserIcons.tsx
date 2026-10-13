/**
 * [M3-F] Browser-chrome icons the shared app icon set doesn't carry.
 * Same visual conventions as app/icons.tsx (24 viewBox, 1.75 stroke).
 */

import type { SVGProps } from 'react'

export type BrowserIconName =
  | 'arrowLeft'
  | 'arrowRight'
  | 'home'
  | 'globe'
  | 'lock'
  | 'key'
  | 'insecure'
  | 'download'
  | 'chevronUp'
  | 'chevronDown'
  | 'pip'
  | 'star'
  | 'starFilled'
  | 'private'

interface BrowserIconProps extends SVGProps<SVGSVGElement> {
  name: BrowserIconName
}

const paths: Record<BrowserIconName, JSX.Element> = {
  private: (
    <>
      <path d="M4 10.5h16l-1.6 7H5.6Z" />
      <path d="m8 10.5 1.4-4h5.2l1.4 4M8.2 17.5a2 2 0 1 0 0 .1M15.8 17.5a2 2 0 1 0 0 .1" />
    </>
  ),
  arrowLeft: <path d="M19 12H5m6-6-6 6 6 6" />,
  home: (
    <>
      <path d="m3.5 11.2 8.5-7 8.5 7" />
      <path d="M5.5 9.7v10h13v-10M9.5 19.7v-6h5v6" />
    </>
  ),
  star: (
    <path d="m12 3.8 2.6 5.3 5.8.8-4.2 4.1 1 5.8-5.2-2.7-5.2 2.7 1-5.8-4.2-4.1 5.8-.8Z" />
  ),
  starFilled: (
    <path
      fill="currentColor"
      d="m12 3.8 2.6 5.3 5.8.8-4.2 4.1 1 5.8-5.2-2.7-5.2 2.7 1-5.8-4.2-4.1 5.8-.8Z"
    />
  ),
  chevronUp: <path d="m6 14.5 6-6 6 6" />,
  chevronDown: <path d="m6 9.5 6 6 6-6" />,
  download: (
    <path d="M12 3.5v11m0 0 4.5-4.5M12 14.5 7.5 10M4.5 17v2a1.5 1.5 0 0 0 1.5 1.5h12a1.5 1.5 0 0 0 1.5-1.5v-2" />
  ),
  pip: (
    <>
      <rect x="3.5" y="5" width="17" height="14" rx="2" />
      <rect x="11.5" y="11" width="6" height="5" rx="1" />
    </>
  ),
  arrowRight: <path d="M5 12h14m-6-6 6 6-6 6" />,
  globe: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M3.5 12h17M12 3.5c2.4 2.3 3.6 5.2 3.6 8.5s-1.2 6.2-3.6 8.5c-2.4-2.3-3.6-5.2-3.6-8.5s1.2-6.2 3.6-8.5Z" />
    </>
  ),
  // A struck-through lock, the shape Chrome and Safari both settled on for
  // "this connection is not private".
  insecure: (
    <>
      <rect x="5" y="11" width="14" height="9" rx="2" />
      <path d="M8 11V8a4 4 0 0 1 6.9-2.7" />
      <path d="m4 4 16 16" />
    </>
  ),
  lock: (
    <>
      <rect x="5.5" y="10" width="13" height="10" rx="2" />
      <path d="M8.5 10V7.5a3.5 3.5 0 0 1 7 0V10" />
    </>
  ),
  key: (
    <>
      <circle cx="8" cy="12" r="4" />
      <path d="M12 12h8m-3 0v3m-3-3v2" />
    </>
  )
}

export function BrowserIcon({ name, ...props }: BrowserIconProps): JSX.Element {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      width="1em"
      height="1em"
      {...props}
    >
      <g
        fill="none"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth={1.75}
      >
        {paths[name]}
      </g>
    </svg>
  )
}
