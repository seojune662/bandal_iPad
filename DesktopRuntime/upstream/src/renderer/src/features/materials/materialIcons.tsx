import type { SVGProps } from 'react'
import type { MaterialKind } from '../../../../shared/types/materials'

/** Shared document silhouettes stay legible without relying on file-type colors. */
export function MaterialFileIcon({ kind, expanded = false }: { kind: MaterialKind | 'dir'; expanded?: boolean }): JSX.Element {
  return <svg className="material-row__type" viewBox="0 0 24 24" aria-hidden="true" focusable="false" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    {kind === 'dir' ? <path d={expanded ? 'M3 9V7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v1M3 10h18l-2 9H5Z' : 'M3 8a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z'} /> : <>
      <path className="material-row__paper" d="M6 3.5h8l4 4V20H6Z" />
      <path d="M14 3.5V8h4" />
      {kind === 'image' ? <><path d="m8.5 17 2.5-3 2 2 1.5-1.5L16 17" /><circle cx="10" cy="11" r=".7" /></> : kind === 'video' ? <path d="m10 11 4 2.5-4 2.5Z" /> : kind === 'pdf' ? <><path d="M8.5 11.5h7v3h-7Z" /><path d="M8.5 17h5" /></> : <path d="M8.5 11.5h7M8.5 14.5h7M8.5 17.5h4" />}
    </>}
  </svg>
}

type MaterialsIconName = 'fileImport' | 'folderPlus'

const PATHS: Record<MaterialsIconName, JSX.Element> = {
  fileImport: (
    <>
      <path d="M12 3.5v9M8.5 9l3.5 3.5L15.5 9" />
      <path d="M4 14.5h4l1.5 2h5l1.5-2h4l-1.25 5.5H5.25z" />
    </>
  ),
  folderPlus: (
    <>
      <path d="M3.5 6h6l2 2h9v11h-17z" />
      <path d="M17 13.5v5M14.5 16h5" />
    </>
  )
}

export function MaterialsIcon({
  name,
  ...props
}: SVGProps<SVGSVGElement> & { name: MaterialsIconName }): JSX.Element {
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
        strokeWidth="1.75"
      >
        {PATHS[name]}
      </g>
    </svg>
  )
}
