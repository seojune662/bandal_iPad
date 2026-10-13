import { useId, useMemo, useState } from 'react'
import { searchUniversities } from '../../../../shared/universities'
import type {
  CustomUniversityInput,
  University
} from '../../../../shared/types/university'
import { useLocale, useT } from '../../i18n'

interface SettingsUniversityPickerProps {
  selectedId: string | null
  customName?: string | undefined
  onSelectPreset: (universityId: string) => void
  onAddCustom: (input: CustomUniversityInput) => Promise<boolean>
  busy?: boolean
}

function displayName(
  university: University,
  locale: ReturnType<typeof useLocale>
): string {
  return locale === 'en-US' && university.nameEn.length > 0
    ? university.nameEn
    : university.nameKo
}

export function SettingsUniversityPicker({
  selectedId,
  customName,
  onSelectPreset,
  onAddCustom,
  busy = false
}: SettingsUniversityPickerProps): JSX.Element {
  const t = useT()
  const locale = useLocale()
  const [query, setQuery] = useState('')
  const [customOpen, setCustomOpen] = useState(false)
  const [customNameDraft, setCustomNameDraft] = useState('')
  const [customUrl, setCustomUrl] = useState('')
  const searchId = useId()
  const nameId = useId()
  const urlId = useId()

  const results = useMemo(() => searchUniversities(query), [query])
  const trimmedQuery = query.trim()
  const customSelected =
    selectedId !== null && customName !== undefined && customName.length > 0

  const openCustomForm = (): void => {
    setCustomNameDraft(trimmedQuery)
    setCustomOpen(true)
  }

  const submitCustom = (event: React.FormEvent): void => {
    event.preventDefault()
    const nameKo = customNameDraft.trim()
    if (busy || nameKo.length === 0) return
    const courseUrl = customUrl.trim()
    void onAddCustom(courseUrl.length > 0 ? { nameKo, courseUrl } : { nameKo }).then(saved => {
      if (!saved) return
      setCustomOpen(false)
      setCustomUrl('')
      setQuery('')
    })
  }

  return (
    <div className="university-picker">
      <label className="sr-only" htmlFor={searchId}>
        {t('settings.university.picker.searchLabel')}
      </label>
      <input
        id={searchId}
        type="search"
        className="university-field university-picker__search"
        placeholder={t('settings.university.picker.searchPlaceholder')}
        value={query}
        autoComplete="off"
        disabled={busy}
        onChange={(event) => setQuery(event.target.value)}
      />

      {customSelected && (
        <p className="university-picker__current">
          {t('settings.university.picker.currentCustom', { name: customName })}
        </p>
      )}

      <ul
        className="university-list"
        role="listbox"
        aria-label={t('settings.university.picker.listLabel')}
      >
        {results.map((university) => {
          const selected = university.id === selectedId
          return (
            <li key={university.id}>
              <button
                type="button"
                role="option"
                aria-selected={selected}
                className="university-option"
                data-selected={selected}
                disabled={busy}
                onClick={() => onSelectPreset(university.id)}
              >
                <span className="university-option__name">
                  {displayName(university, locale)}
                </span>
                <span className="university-option__meta">
                  {university.domain} ·{' '}
                  {university.verifiedAt.length === 0
                    ? t('settings.university.noVerifiedAt')
                    : t('settings.university.verifiedAt', {
                        date: university.verifiedAt
                      })}
                </span>
              </button>
            </li>
          )
        })}
      </ul>

      {results.length === 0 && (
        <p className="university-picker__zero">
          {t('settings.university.picker.zero')}
        </p>
      )}

      {!customOpen ? (
        <button
          type="button"
          className="university-picker__custom-cta"
          disabled={busy}
          onClick={openCustomForm}
        >
          {trimmedQuery.length > 0
            ? t('settings.university.picker.addNamed', { name: trimmedQuery })
            : t('settings.university.picker.addUnlisted')}
        </button>
      ) : (
        <form className="university-custom-form" onSubmit={submitCustom}>
          <label className="university-label" htmlFor={nameId}>
            {t('settings.university.picker.name')}
          </label>
          <input
            id={nameId}
            className="university-field"
            value={customNameDraft}
            placeholder={t('settings.university.picker.namePlaceholder')}
            autoComplete="off"
            disabled={busy}
            onChange={(event) => setCustomNameDraft(event.target.value)}
          />
          <label className="university-label" htmlFor={urlId}>
            {t('settings.university.picker.courseUrl')}{' '}
            <span className="university-custom-form__optional">
              {t('settings.university.picker.optional')}
            </span>
          </label>
          <input
            id={urlId}
            className="university-field"
            value={customUrl}
            placeholder={t('settings.university.picker.urlPlaceholder')}
            autoComplete="off"
            disabled={busy}
            onChange={(event) => setCustomUrl(event.target.value)}
          />
          <p className="university-custom-form__hint">
            {t('settings.university.picker.urlHelp')}
          </p>
          <div className="university-custom-form__actions">
            <button
              type="button"
              className="university-button"
              disabled={busy}
              onClick={() => setCustomOpen(false)}
            >
              {t('settings.university.picker.cancel')}
            </button>
            <button
              type="submit"
              className="university-button university-button--primary"
              disabled={busy || customNameDraft.trim().length === 0}
            >
              {t('settings.university.picker.add')}
            </button>
          </div>
        </form>
      )}
    </div>
  )
}
