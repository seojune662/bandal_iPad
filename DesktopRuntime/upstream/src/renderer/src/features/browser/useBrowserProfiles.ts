import { useCallback, useEffect, useRef, useState } from 'react'
import type { BrowserProfile } from '../../../../shared/types/browserProfile'
import { invoke } from '../../lib/ipc'

const PROFILES_CHANGED = 'bandal:browser-profiles-changed'

export function notifyBrowserProfilesChanged(): void {
  window.dispatchEvent(new Event(PROFILES_CHANGED))
}

/** Keep every tab's profile label and the settings selectors in sync. */
export function useBrowserProfiles() {
  const [profiles, setProfiles] = useState<BrowserProfile[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const request = useRef(0)
  const refresh = useCallback(async (): Promise<void> => {
    const currentRequest = ++request.current
    setLoading(true)
    setError('')
    try {
      const next = await invoke('browser:profiles', {})
      if (currentRequest === request.current) setProfiles(next)
    } catch {
      if (currentRequest === request.current) setError('브라우저 프로필을 불러오지 못했습니다. 다시 시도해 주세요.')
    } finally {
      if (currentRequest === request.current) setLoading(false)
    }
  }, [])
  useEffect(() => {
    const reload = (): void => { void refresh() }
    reload()
    window.addEventListener(PROFILES_CHANGED, reload)
    return () => {
      ++request.current
      window.removeEventListener(PROFILES_CHANGED, reload)
    }
  }, [refresh])
  return { profiles, loading, error, refresh }
}
