import { useSyncExternalStore } from 'react'

const STORAGE_KEY = 'bandal:english-reading-guide:v1'
const listeners = new Set<() => void>()
let seenInSession = false

function hasSeenGuide(): boolean {
  if (seenInSession) return true
  try { return localStorage.getItem(STORAGE_KEY) === 'seen' } catch { return false }
}

export function dismissEnglishReadingGuide(): void {
  seenInSession = true
  try { localStorage.setItem(STORAGE_KEY, 'seen') } catch { /* Remember for this session if storage is unavailable. */ }
  for (const listener of listeners) listener()
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener)
  window.addEventListener('storage', listener)
  return () => { listeners.delete(listener); window.removeEventListener('storage', listener) }
}

export function useEnglishReadingGuideSeen(): boolean {
  return useSyncExternalStore(subscribe, hasSeenGuide)
}
