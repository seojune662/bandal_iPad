import { ensureSettingsLoaded } from '../stores/settingsSnapshot'
import { useEffect } from 'react'
import { create } from 'zustand'
import { invoke, onPush } from '../lib/ipc'
import type { Locale } from './types'

export const LOCALES: readonly Locale[] = ['ko-KR', 'en-US']
export const DEFAULT_LOCALE: Locale = 'ko-KR'

interface LocaleState {
  locale: Locale
}

const useLocaleStore = create<LocaleState>()(() => ({
  locale: DEFAULT_LOCALE
}))

let initialization: Promise<void> | null = null
let subscribed = false
let writeSequence = 0
let pendingLocale: Locale | null = null

function isLocale(value: unknown): value is Locale {
  return LOCALES.some((locale) => locale === value)
}

function normalizeLocale(value: unknown): Locale {
  return isLocale(value) ? value : DEFAULT_LOCALE
}

function initializeLocale(): Promise<void> {
  if (initialization !== null) return initialization

  initialization = (async () => {
    const sequenceAtStart = writeSequence
    if (!subscribed) {
      onPush('settings:changed', ({ settings }) => {
        const nextLocale = normalizeLocale(settings.locale)
        if (pendingLocale === null || pendingLocale === nextLocale) {
          useLocaleStore.setState({ locale: nextLocale })
        }
      })
      subscribed = true
    }

    const settings = await ensureSettingsLoaded()
    if (sequenceAtStart === writeSequence) {
      useLocaleStore.setState({ locale: normalizeLocale(settings.locale) })
    }
  })()

  void initialization.catch((error: unknown) => {
    initialization = null
    console.warn('[i18n] Failed to load the saved locale.', error)
  })
  return initialization
}

/** Returns the locale currently applied by this renderer process. */
export function getLocale(): Locale {
  return useLocaleStore.getState().locale
}

export function useLocale(): Locale {
  const locale = useLocaleStore((state) => state.locale)

  useEffect(() => {
    void initializeLocale()
  }, [])

  return locale
}

export function setLocale(locale: Locale): void {
  const previous = useLocaleStore.getState().locale
  const sequence = ++writeSequence

  pendingLocale = locale
  useLocaleStore.setState({ locale })
  void invoke('settings:set', { locale })
    .then((settings) => {
      if (sequence === writeSequence) {
        pendingLocale = null
        useLocaleStore.setState({ locale: normalizeLocale(settings.locale) })
      }
    })
    .catch((error: unknown) => {
      if (sequence === writeSequence) {
        pendingLocale = null
        useLocaleStore.setState({ locale: previous })
      }
      console.warn('[i18n] Failed to save the locale.', error)
    })
}

// The preload bridge exists before renderer modules run, so locale hydration
// can begin at boot; hook callers share this same singleton request.
if (typeof window !== 'undefined' && window.bandal !== undefined) {
  void initializeLocale()
}
