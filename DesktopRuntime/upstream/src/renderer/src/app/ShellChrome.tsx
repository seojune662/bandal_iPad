import { Icon } from './icons'
import { Tooltip } from '../components/Tooltip'
import { useUiStore } from '../stores/uiStore'

/** One owner for window chrome, independent of tabs and sidebar lifetime. */
export function ShellChrome(): JSX.Element {
  const open = useUiStore((state) => state.leftRailOpen)
  const toggle = useUiStore((state) => state.toggleLeftRail)
  const label = open ? '과목 사이드바 접기' : '과목 사이드바 펼치기'
  return (
    <header className="shell-chrome">
      <span className="shell-chrome__traffic" aria-hidden="true" />
      <Tooltip label={label} placement="bottom">
        <button
          className="titlebar-button"
          aria-label={label}
          aria-pressed={open}
          aria-expanded={open}
          onClick={toggle}
        >
          <Icon name="layoutLeft" />
        </button>
      </Tooltip>
    </header>
  )
}
