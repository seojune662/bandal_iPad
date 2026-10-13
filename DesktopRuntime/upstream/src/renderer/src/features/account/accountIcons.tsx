import type { SVGProps } from 'react'
export function AccountIcon({ name: _name, ...props }: SVGProps<SVGSVGElement> & { name: 'logOut' }): JSX.Element {
  return <svg aria-hidden="true" viewBox="0 0 24 24" width="1em" height="1em" {...props}><g fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round"><path d="M14 4.5h4A1.5 1.5 0 0 1 19.5 6v12a1.5 1.5 0 0 1-1.5 1.5h-4" /><path d="M9 8.5 5 12l4 3.5M5 12h10" /></g></svg>
}
