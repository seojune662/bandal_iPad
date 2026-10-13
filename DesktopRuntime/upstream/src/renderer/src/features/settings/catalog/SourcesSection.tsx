import { useState, type FormEvent } from 'react'
import {
  OFFICIAL_CATALOG_URL,
  type CatalogSource
} from '../../../../../shared/types/pluginCatalog'
import { useT } from '../../../i18n'

function isHttpsUrl(value: string): boolean {
  try {
    return new URL(value).protocol === 'https:'
  } catch {
    return false
  }
}

function SourceStatus({ source }: { source: CatalogSource | undefined }): JSX.Element {
  const t = useT()
  const status = source?.status ?? 'pending'
  return (
    <span className="status-pill settings-catalog-source__status" data-status={status}>
      {t(`settings.catalog.sources.status.${status}`)}
    </span>
  )
}

export function SourcesSection({
  sources,
  userUrls,
  disabled,
  onChange
}: {
  sources: readonly CatalogSource[]
  userUrls: readonly string[]
  disabled: boolean
  onChange: (next: readonly string[]) => Promise<void>
}): JSX.Element {
  const t = useT()
  const [value, setValue] = useState('')
  const [saving, setSaving] = useState(false)
  const [feedback, setFeedback] = useState<string | null>(null)
  const official = sources.find((source) => source.official)

  const submit = (event: FormEvent<HTMLFormElement>): void => {
    event.preventDefault()
    const url = value.trim()
    if (
      !isHttpsUrl(url) ||
      url === OFFICIAL_CATALOG_URL ||
      userUrls.includes(url)
    ) {
      setFeedback(t('settings.catalog.sources.invalid'))
      return
    }
    setSaving(true)
    setFeedback(null)
    void onChange([...userUrls, url])
      .then(() => setValue(''))
      .catch(() => setFeedback(t('settings.catalog.sources.saveFailed')))
      .finally(() => setSaving(false))
  }

  const remove = (url: string): void => {
    if (saving) return
    setSaving(true)
    setFeedback(null)
    void onChange(userUrls.filter((item) => item !== url))
      .catch(() => setFeedback(t('settings.catalog.sources.saveFailed')))
      .finally(() => setSaving(false))
  }

  return (
    <section className="settings-catalog-sources" aria-labelledby="settings-catalog-sources-title">
      <h2 id="settings-catalog-sources-title">{t('settings.catalog.sources.title')}</h2>
      <div className="settings-catalog-sources__list">
        <div className="settings-catalog-source">
          <div className="settings-catalog-source__copy">
            <strong>{t('settings.catalog.sources.official')}</strong>
            <span>{OFFICIAL_CATALOG_URL}</span>
          </div>
          <SourceStatus source={official} />
          <span className="settings-catalog-source__count">
            {t('settings.catalog.sources.count', { count: official?.entryCount ?? 0 })}
          </span>
          <span className="settings-catalog-source__locked">
            {t('settings.catalog.sources.locked')}
          </span>
        </div>
        {userUrls.map((url) => {
          const source = sources.find((item) => item.url === url)
          return (
            <div className="settings-catalog-source" key={url}>
              <div className="settings-catalog-source__copy">
                <strong>{t('settings.catalog.sources.custom')}</strong>
                <span>{url}</span>
              </div>
              <SourceStatus source={source} />
              <span className="settings-catalog-source__count">
                {t('settings.catalog.sources.count', { count: source?.entryCount ?? 0 })}
              </span>
              <button
                type="button"
                className="secondary-button"
                disabled={saving}
                onClick={() => remove(url)}
              >
                {t('settings.catalog.sources.remove')}
              </button>
            </div>
          )
        })}
      </div>
      <form className="settings-catalog-sources__form" onSubmit={submit}>
        <label htmlFor="settings-catalog-source-url">
          {t('settings.catalog.sources.urlLabel')}
        </label>
        <input
          id="settings-catalog-source-url"
          type="url"
          inputMode="url"
          value={value}
          disabled={disabled || saving}
          placeholder="https://…/index.json"
          onChange={(event) => {
            setValue(event.currentTarget.value)
            setFeedback(null)
          }}
        />
        <button
          type="submit"
          className="secondary-button"
          disabled={disabled || saving || value.trim().length === 0}
        >
          {t('settings.catalog.sources.add')}
        </button>
      </form>
      {feedback !== null && (
        <p className="settings-catalog-sources__feedback" role="alert">{feedback}</p>
      )}
    </section>
  )
}
