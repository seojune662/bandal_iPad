import { enUS } from './messages/en-US'
import { koKR } from './messages/ko-KR'
import type { MessageKey } from './messages/ko-KR'
import type { Locale } from './types'

type TranslationVars = Record<string, string | number>

const MESSAGES: Record<Locale, Readonly<Record<MessageKey, string>>> = {
  'ko-KR': koKR,
  'en-US': enUS
}

function warnMissing(locale: Locale, key: string): void {
  if (import.meta.env.DEV) {
    console.warn(`[i18n] Missing message "${key}" for locale "${locale}".`)
  }
}

function interpolate(
  message: string,
  locale: Locale,
  vars: TranslationVars | undefined
): string {
  if (vars === undefined) return message

  const numberFormatter = new Intl.NumberFormat(locale)
  return message.replace(/\{([^{}]+)\}/g, (placeholder, name: string) => {
    const value = vars[name]
    if (value === undefined) return placeholder
    return typeof value === 'number' ? numberFormatter.format(value) : value
  })
}

/** Resolves one flat message key, with Korean and then key-name fallback. */
export function translate(
  locale: Locale,
  key: string,
  vars?: TranslationVars
): string {
  const localized = (MESSAGES[locale] as Readonly<Record<string, string>>)[key]
  if (localized !== undefined) return interpolate(localized, locale, vars)

  warnMissing(locale, key)
  const korean = (koKR as Readonly<Record<string, string>>)[key]
  return korean === undefined ? key : interpolate(korean, locale, vars)
}
