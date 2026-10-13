import { useCallback } from 'react'
import { useLocale } from './localeStore'
import { translate } from './translate'

export { LOCALES, setLocale, useLocale } from './localeStore'
export type { Locale } from './types'

export function useT(): (
  key: string,
  vars?: Record<string, string | number>
) => string {
  const locale = useLocale()
  return useCallback(
    (key: string, vars?: Record<string, string | number>) =>
      translate(locale, key, vars),
    [locale]
  )
}
