/**
 * Tab-kind icons. `pdf`/`note` reuse the shared app icon set; the kinds the
 * shell does not know about yet (browser/chat/board/group-chat/whiteboard) are
 * drawn here so the workspace stays self-contained.
 */

import { useState, type SVGProps } from 'react'
import type { TabDescriptor, TabKind } from '../../../../shared/tabs'
import { Icon } from '../../app/icons'
import { useBrowserGuests } from '../browser/browserGuestsStore'

type LocalKind = 'browser' | 'chat' | 'board' | 'whiteboard' | 'recording'

const localPaths: Record<LocalKind, JSX.Element> = {
  recording: <><rect x="9" y="3" width="6" height="12" rx="3" /><path d="M6 10v2a6 6 0 0 0 12 0v-2M12 18v3M9 21h6" /></>,
  browser: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M3.5 12h17M12 3.5c2.5 2.3 3.8 5.2 3.8 8.5s-1.3 6.2-3.8 8.5c-2.5-2.3-3.8-5.2-3.8-8.5s1.3-6.2 3.8-8.5z" />
    </>
  ),
  chat: (
    <>
      <path d="M4 5.5h16v11H10l-4.5 3.5v-3.5H4z" />
      <path d="M8 9.5h8M8 12.5h5" />
    </>
  ),
  board: (
    <>
      <rect x="3.5" y="4" width="17" height="16" rx="2" />
      <path d="M9.2 4v16M14.8 4v16M5.8 7.5h1M11.5 7.5h1M17.2 7.5h1" />
    </>
  ),
  whiteboard: (
    <>
      <rect x="3.5" y="4" width="17" height="14" rx="2" />
      <path d="m7 14 3-3 2.5 2 4-5M8 21h8M12 18v3" />
    </>
  ),
}

function LocalIcon({
  kind,
  ...props
}: { kind: LocalKind } & SVGProps<SVGSVGElement>): JSX.Element {
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
        {localPaths[kind]}
      </g>
    </svg>
  )
}

interface TabKindIconProps extends Omit<SVGProps<SVGSVGElement>, 'name'> {
  kind: TabKind
}

export function TabKindIcon({ kind, ...props }: TabKindIconProps): JSX.Element {
  switch (kind) {
    case 'pdf':
      return <Icon name="filePdf" {...props} />
    case 'note':
      return <Icon name="fileText" {...props} />
    case 'image':
      return <Icon name="fileImage" {...props} />
    case 'file':
      return <Icon name="file" {...props} />
    case 'plugin-panel':
      return <Icon name="puzzle" {...props} />
    case 'learning':
      return <Icon name="graph" {...props} />
    case 'browser':
    case 'recording':
    case 'chat':
    case 'board':
    case 'whiteboard':
      return <LocalIcon kind={kind} {...props} />
  }
}

/** Reuse the browser session's already validated raster data, never a remote URL. */
export function WorkspaceTabIcon({ descriptor, className }: { descriptor: TabDescriptor; className?: string }): JSX.Element {
  const favicon = useBrowserGuests(state => descriptor.kind === 'browser' ? state.favicon[descriptor.payload.tabId] : undefined)
  const [failed, setFailed] = useState<string | undefined>()
  if (favicon && favicon !== failed && /^data:image\/(?:png|jpeg|gif|webp|x-icon|vnd\.microsoft\.icon);base64,/i.test(favicon)) {
    return <img src={favicon} alt="" draggable={false} className={`workspace-tab__favicon ${className ?? ''}`} data-tab-icon="browser" onError={() => setFailed(favicon)} />
  }
  return <TabKindIcon kind={descriptor.kind} {...(className ? { className } : {})} data-tab-icon={descriptor.kind} />
}
