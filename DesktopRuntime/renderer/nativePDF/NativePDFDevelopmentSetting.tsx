import { useEffect, useState } from 'react'
import { useLocale } from '../../upstream/src/renderer/src/i18n'
import { SettingsCard, ToggleRow } from '../../upstream/src/renderer/src/features/settings/primitives'

interface DevelopmentCapabilities { development?: boolean; enabled?: boolean }
const invoke = (channel: string, request: Record<string, unknown> = {}): Promise<unknown> =>
  (window.bandal as unknown as { invoke(channel: string, request: Record<string, unknown>): Promise<unknown> }).invoke(channel, request)

/** The native host owns both build-channel eligibility and the saved flag.
 * A renderer build mode is not evidence that a shipping app permits this UI. */
export function NativePDFDevelopmentSetting(): JSX.Element | null {
  const ko = useLocale() === 'ko-KR'
  const [enabled, setEnabled] = useState<boolean | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [changed, setChanged] = useState(false)
  useEffect(() => {
    let disposed = false
    void invoke('pdfNative:capabilities').then(value => {
      const state = value as DevelopmentCapabilities | null
      if (!disposed && state?.development === true && typeof state.enabled === 'boolean') setEnabled(state.enabled)
    }).catch(() => { /* Fail closed: never expose this control without native DEBUG confirmation. */ })
    return () => { disposed = true }
  }, [])
  const save = async (next: boolean): Promise<void> => {
    if (busy || enabled === null) return
    setBusy(true); setError(null)
    try {
      const result = await invoke('pdfNative:setEnabled', { enabled: next }) as { enabled?: unknown } | null
      if (result?.enabled !== next) throw new Error(ko ? 'PDF 비교 설정이 저장되지 않았습니다.' : 'The PDF comparison setting was not saved.')
      setEnabled(next); setChanged(true)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : ko ? 'PDF 비교 설정을 저장하지 못했습니다.' : 'Could not save the PDF comparison setting.')
    } finally { setBusy(false) }
  }
  if (enabled === null) return null
  return <SettingsCard title={ko ? 'PDF 필기 비교 (개발용)' : 'PDF writing comparison (development)'}
    description={ko ? '네이티브 PDF와 기존 화면의 필기·확대 동작을 비교합니다. 변경 후 열려 있는 PDF를 닫고 다시 열어 주세요.' : 'Compare writing and zooming in the native PDF view and the existing view. Close and reopen PDFs after changing this setting.'}>
    <div className="settings-card__rows">
      <ToggleRow label={ko ? '네이티브 PDF와 Pencil 입력' : 'Native PDF and Pencil input'}
        description={ko ? '끄면 기존 PDF 화면을 사용합니다. 저장한 자료와 필기는 유지됩니다.' : 'Turn off to use the existing PDF view. Saved materials and drawings are retained.'}
        checked={enabled} disabled={busy} onChange={next => { void save(next) }} />
    </div>
    {error && <p className="settings-feedback--error" role="alert">{error}</p>}
    {!error && changed && <p className="setting-row__description" role="status">{ko ? '저장했습니다. PDF를 닫고 다시 열면 적용됩니다.' : 'Saved. Close and reopen the PDF to apply.'}</p>}
  </SettingsCard>
}
