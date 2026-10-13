import type { InkTool } from '../ink'

export type CanvasToolIconName = InkTool | 'image' | 'lineWidth' | 'undo' | 'redo'

export function CanvasToolIcon({ name }: { name: CanvasToolIconName }): JSX.Element {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      width="1em"
      height="1em"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.75"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      {name === 'select' && <path d="m6 3 11 8-5 1.5L9.5 18z" />}
      {name === 'pen' && (
        <>
          <path d="m5 19 3.5-1 9.8-9.8-2.5-2.5L6 15.5z" />
          <path d="m14.5 7 2.5 2.5" />
        </>
      )}
      {name === 'highlighter' && (
        <>
          <path d="m7 15 7.8-9.5 3.7 3.7L9 17z" />
          <path d="m5 19 4-2 2 2zM4 21h16" />
        </>
      )}
      {name === 'eraser' && (
        <>
          <path d="m5 15 7.8-9.5 5.7 5.7-6.4 7.3H8z" />
          <path d="m9.5 18.5 5-5" />
        </>
      )}
      {name === 'text' && (
        <>
          <path d="M5 6V4h14v2M12 4v16" />
          <path d="M8.5 20h7" />
        </>
      )}
      {name === 'rect' && <rect x="4" y="5" width="16" height="14" rx="1" />}
      {name === 'ellipse' && <ellipse cx="12" cy="12" rx="8" ry="6" />}
      {name === 'arrow' && (
        <>
          <path d="M5 19 19 5" />
          <path d="M12 5h7v7" />
        </>
      )}
      {name === 'line' && <path d="M5 19 19 5" />}
      {name === 'image' && (
        <>
          <rect x="3.5" y="5" width="17" height="14" rx="2" />
          <circle cx="9" cy="10" r="1.5" />
          <path d="m5.5 17 4.5-4 3 2.5 2.5-2 3 3.5" />
        </>
      )}
      {name === 'lineWidth' && (
        <>
          <path d="M4 7h16M4 12h16" />
          <path d="M4 18h16" strokeWidth="3" />
        </>
      )}
      {name === 'undo' && (
        <>
          <path d="m9 7-5 4 5 4" />
          <path d="M5 11h8a6 6 0 0 1 6 6" />
        </>
      )}
      {name === 'redo' && (
        <>
          <path d="m15 7 5 4-5 4" />
          <path d="M19 11h-8a6 6 0 0 0-6 6" />
        </>
      )}
    </svg>
  )
}
