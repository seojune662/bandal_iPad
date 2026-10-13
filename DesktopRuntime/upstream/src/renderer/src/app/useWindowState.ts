import { useEffect } from 'react'
import { invoke, onPush } from '../lib/ipc'

/** Native fullscreen is independent of the document Fullscreen API. */
export function useWindowState(): void {
  useEffect(() => {
    let alive = true, pushed = false
    const apply = ({ fullscreen }: { fullscreen: boolean }): void => {
      document.documentElement.dataset.fullscreen = String(fullscreen)
    }
    const unsubscribe = onPush('window:stateChanged', state => {
      pushed = true
      apply(state)
    })
    void invoke('window:getState', {}).then(state => {
      if (alive && !pushed) apply(state)
    }).catch(() => undefined)
    return () => { alive = false; unsubscribe() }
  }, [])
}
