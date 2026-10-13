import { useRef } from 'react'
import type { CSSProperties, KeyboardEvent, MutableRefObject } from 'react'
import { SYSTEM_THEME } from '../../../../shared/theme'
import type { ThemeId } from '../../../../shared/theme'
import {
  DENSITIES,
  EDITOR_FONTS,
  FONT_SCALES
} from '../../../../shared/types/settings'
import type {
  Density,
  EditorFont,
  FontScale,
  ThemePreference
} from '../../../../shared/types/settings'
import { useLocale, useT } from '../../i18n'
import { SettingsCard } from './primitives'
import { Icon } from './SettingsIcon'
const THEME_OPTIONS: readonly ThemePreference[] = ['system', 'light', 'dark']
function fontScaleLabel(scale: FontScale): string {
  return `${Math.round(scale * 100)}%`
}
function swatchVars(mode: ThemeId): CSSProperties {
  const cell = `--preview-${mode}`
  return {
    '--preview-bg': `var(${cell}-bg)`,
    '--preview-surface': `var(${cell}-surface)`,
    '--preview-text': `var(${cell}-text)`,
    '--preview-accent': `var(${cell}-accent)`
  } as CSSProperties
}

function PreviewBody(): JSX.Element {
  return (
    <>
      <span className="theme-preview__sidebar" />
      <span className="theme-preview__accent" />
      <span className="theme-preview__line theme-preview__line--long" />
      <span className="theme-preview__line theme-preview__line--short" />
    </>
  )
}

function ThemePreview({ theme }: { theme: ThemePreference }): JSX.Element {
  if (theme === 'system') {
    return (
      <div className="theme-preview theme-preview--system" aria-hidden="true">
        <span
          className="theme-preview__half"
          style={swatchVars(SYSTEM_THEME.dark)}
        >
          <PreviewBody />
        </span>
        <span
          className="theme-preview__half"
          style={swatchVars(SYSTEM_THEME.light)}
        >
          <PreviewBody />
        </span>
      </div>
    )
  }

  return (
    <div className="theme-preview" style={swatchVars(theme)} aria-hidden="true">
      <PreviewBody />
    </div>
  )
}

/** Three rows of chrome at the option's rhythm — the gap IS the preview. */
function DensityPreview({ density }: { density: Density }): JSX.Element {
  return (
    <div
      className={`density-preview density-preview--${density}`}
      aria-hidden="true"
    >
      <span className="density-preview__row density-preview__row--chrome" />
      <span className="density-preview__row" />
      <span className="density-preview__row" />
      <span className="density-preview__row density-preview__row--short" />
    </div>
  )
}

/**
 * Roving-tabindex keyboard model shared by every appearance radiogroup:
 * arrows move *and* select (the preview is the feedback), Home/End jump.
 */
function useRovingRadios<T extends string | number>(
  options: readonly T[],
  value: T,
  onSelect: (next: T) => void
): {
  refs: MutableRefObject<Array<HTMLButtonElement | null>>
  selectedIndex: number
  handleKeyDown: (event: KeyboardEvent<HTMLDivElement>) => void
} {
  const refs = useRef<Array<HTMLButtonElement | null>>([])
  const selectedIndex = Math.max(0, options.indexOf(value))

  const moveTo = (index: number): void => {
    const count = options.length
    const next = ((index % count) + count) % count
    refs.current[next]?.focus()
    onSelect(options[next]!)
  }

  const handleKeyDown = (event: KeyboardEvent<HTMLDivElement>): void => {
    const current = options.indexOf(value)
    switch (event.key) {
      case 'ArrowRight':
      case 'ArrowDown':
        event.preventDefault()
        moveTo(current + 1)
        break
      case 'ArrowLeft':
      case 'ArrowUp':
        event.preventDefault()
        moveTo(current - 1)
        break
      case 'Home':
        event.preventDefault()
        moveTo(0)
        break
      case 'End':
        event.preventDefault()
        moveTo(options.length - 1)
        break
      default:
        break
    }
  }

  return { refs, selectedIndex, handleKeyDown }
}

export function AppearancePanel({
  theme,
  fontScale,
  editorFont,
  density,
  saving,
  error,
  onSelect,
  onSelectFontScale,
  onSelectEditorFont,
  onSelectDensity
}: {
  theme: ThemePreference
  fontScale: FontScale
  editorFont: EditorFont
  density: Density
  saving: boolean
  error: string | null
  onSelect: (theme: ThemePreference) => void
  onSelectFontScale: (fontScale: FontScale) => void
  onSelectEditorFont: (editorFont: EditorFont) => void
  onSelectDensity: (density: Density) => void
}): JSX.Element {
  const t = useT()
  const locale = useLocale()
  const modes = useRovingRadios(THEME_OPTIONS, theme, onSelect)
  const scales = useRovingRadios(FONT_SCALES, fontScale, onSelectFontScale)
  const fonts = useRovingRadios(EDITOR_FONTS, editorFont, onSelectEditorFont)
  const densities = useRovingRadios(DENSITIES, density, onSelectDensity)

  return (
    <div className="settings-stack">
      <SettingsCard
        title={t('settings.appearance.theme.title')}
        description={t('settings.appearance.theme.description')}
      >
        <div
          className="theme-grid"
          role="radiogroup"
          aria-label={t('settings.appearance.theme.selectLabel')}
          aria-busy={saving}
          onKeyDown={modes.handleKeyDown}
        >
          {THEME_OPTIONS.map((option, index) => {
            const selected = theme === option
            return (
              <button
                key={option}
                type="button"
                role="radio"
                ref={(node) => {
                  modes.refs.current[index] = node
                }}
                aria-checked={selected}
                tabIndex={index === modes.selectedIndex ? 0 : -1}
                className={`theme-choice${selected ? ' theme-choice--selected' : ''}`}
                onClick={() => onSelect(option)}
              >
                <ThemePreview theme={option} />
                <span className="theme-choice__copy">
                  <span className="theme-choice__label">
                    {t(`settings.appearance.theme.${option}.label`)}
                    <span className="theme-choice__check">
                      {selected && <Icon name="check" size={14} />}
                    </span>
                  </span>
                  <span className="theme-choice__description">
                    {t(`settings.appearance.theme.${option}.description`)}
                  </span>
                </span>
              </button>
            )
          })}
        </div>
        <p
          className={`settings-feedback${error !== null ? ' settings-feedback--error' : ''}`}
          aria-live="polite"
        >
          {error ??
            (saving
              ? t('settings.appearance.saving')
              : t('settings.appearance.saved'))}
        </p>
      </SettingsCard>
      <p className="appearance-note">
        {locale === 'ko-KR'
          ? '기본 라이트·다크 화면을 사용합니다. 기존 색상 계열과 플러그인 테마는 적용되지 않습니다.'
          : 'Uses the default light and dark appearance. Previous palettes and plugin themes are no longer applied.'}
      </p>

      <SettingsCard
        title={t('settings.appearance.font.scale.title')}
        description={t('settings.appearance.font.scale.description')}
      >
        <div
          className="segmented"
          role="radiogroup"
          aria-label={t('settings.appearance.font.scale.selectLabel')}
          aria-busy={saving}
          onKeyDown={scales.handleKeyDown}
        >
          {FONT_SCALES.map((option, index) => {
            const selected = fontScale === option
            return (
              <button
                key={option}
                type="button"
                role="radio"
                ref={(node) => {
                  scales.refs.current[index] = node
                }}
                aria-checked={selected}
                tabIndex={index === scales.selectedIndex ? 0 : -1}
                className={`segmented__option${selected ? ' segmented__option--selected' : ''}`}
                style={{ '--segment-scale': option } as CSSProperties}
                onClick={() => onSelectFontScale(option)}
              >
                <span className="segmented__glyph" aria-hidden="true">
                  가
                </span>
                <span className="segmented__label">
                  {fontScaleLabel(option)}
                </span>
              </button>
            )
          })}
        </div>
      </SettingsCard>

      <SettingsCard
        title={t('settings.appearance.font.family.title')}
        description={t('settings.appearance.font.family.description')}
      >
        <div
          className="theme-grid theme-grid--font"
          role="radiogroup"
          aria-label={t('settings.appearance.font.family.selectLabel')}
          aria-busy={saving}
          onKeyDown={fonts.handleKeyDown}
        >
          {EDITOR_FONTS.map((option, index) => {
            const selected = editorFont === option
            return (
              <button
                key={option}
                type="button"
                role="radio"
                ref={(node) => {
                  fonts.refs.current[index] = node
                }}
                aria-checked={selected}
                tabIndex={index === fonts.selectedIndex ? 0 : -1}
                className={`theme-choice${selected ? ' theme-choice--selected' : ''}`}
                onClick={() => onSelectEditorFont(option)}
              >
                <span
                  className={`font-sample font-sample--${option}`}
                  aria-hidden="true"
                >
                  {t('settings.appearance.font.family.sample')}
                </span>
                <span className="theme-choice__copy">
                  <span className="theme-choice__label">
                    {t(`settings.appearance.font.family.${option}.label`)}
                    <span className="theme-choice__check">
                      {selected && <Icon name="check" size={14} />}
                    </span>
                  </span>
                  <span className="theme-choice__description">
                    {t(`settings.appearance.font.family.${option}.description`)}
                  </span>
                </span>
              </button>
            )
          })}
        </div>
      </SettingsCard>

      <SettingsCard
        title={t('settings.appearance.density.title')}
        description={t('settings.appearance.density.description')}
      >
        <div
          className="theme-grid theme-grid--density"
          role="radiogroup"
          aria-label={t('settings.appearance.density.selectLabel')}
          aria-busy={saving}
          onKeyDown={densities.handleKeyDown}
        >
          {DENSITIES.map((option, index) => {
            const selected = density === option
            return (
              <button
                key={option}
                type="button"
                role="radio"
                ref={(node) => {
                  densities.refs.current[index] = node
                }}
                aria-checked={selected}
                tabIndex={index === densities.selectedIndex ? 0 : -1}
                className={`theme-choice${selected ? ' theme-choice--selected' : ''}`}
                onClick={() => onSelectDensity(option)}
              >
                <DensityPreview density={option} />
                <span className="theme-choice__copy">
                  <span className="theme-choice__label">
                    {t(`settings.appearance.density.${option}.label`)}
                    <span className="theme-choice__check">
                      {selected && <Icon name="check" size={14} />}
                    </span>
                  </span>
                  <span className="theme-choice__description">
                    {t(`settings.appearance.density.${option}.description`)}
                  </span>
                </span>
              </button>
            )
          })}
        </div>
      </SettingsCard>


    </div>
  )
}
