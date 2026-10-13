import { useEffect, useId, useState, type ReactNode } from 'react'
import type { Settings } from '../../../../shared/types/settings'
import { EDITOR_FONTS } from '../../../../shared/types/settings'
import { RECORDING_PLAYBACK_RATES } from '../../../../shared/tabPreferences'
import {
  formatChord,
  parseChord,
  resolveKeymap,
  type ShortcutActionId
} from '../../../../shared/keymap'
import type { SpeechModelState } from '../../../../shared/recording'
import type { SettingsCategoryId } from '../../../../shared/settingsCategories'
import { useLocale } from '../../i18n'
import { invoke, onPush } from '../../lib/ipc'
import { SpeechModelPicker } from '../recordings/SpeechModelPicker'
import { TabKindIcon } from '../workspace/workspaceIcons'
import { SettingsCard, ToggleRow } from './primitives'
import { savePreference } from './savePreference'
import '../recordings/recording.css'
import './tabs-settings.css'

const TABS = [
  { id: 'note', ko: '마크다운', en: 'Markdown', action: 'new-markdown' },
  { id: 'browser', ko: '브라우저', en: 'Browser', action: 'new-browser-tab' },
  { id: 'chat', ko: 'AI', en: 'AI', action: 'new-ai-tab' },
  { id: 'recording', ko: '녹음', en: 'Recording', action: 'new-recording-tab' },
  {
    id: 'whiteboard',
    ko: '화이트보드',
    en: 'Whiteboard',
    action: 'new-whiteboard'
  },
  {
    id: 'board',
    ko: '학업 보드',
    en: 'Study board',
    action: 'open-study-board'
  }
] as const
type TabId = (typeof TABS)[number]['id']

export function TabsSettingsPanel({
  settings,
  aiPanel,
  browserPanel,
  onNavigate
}: {
  settings: Settings | null
  aiPanel: ReactNode
  browserPanel: ReactNode
  onNavigate: (category: SettingsCategoryId) => void
}): JSX.Element {
  const ko = useLocale() === 'ko-KR'
  const [selected, setSelected] = useState<TabId>('note')
  const id = useId()
  const current = TABS.find((tab) => tab.id === selected)!
  const [prefix, setPrefix] = useState(settings?.tabs.markdownTitlePrefix ?? '')
  useEffect(
    () => setPrefix(settings?.tabs.markdownTitlePrefix ?? ''),
    [settings?.tabs.markdownTitlePrefix]
  )
  const chord = [...resolveKeymap(settings?.keybindings ?? {})].find(
    ([, action]) => action === (current.action as ShortcutActionId)
  )?.[0]
  const parsed = chord ? parseChord(chord) : null
  const prefs = settings?.tabs
  return (
    <div className="settings-stack tab-settings">
      <div
        className="tab-settings__nav"
        role="tablist"
        aria-label={ko ? '탭 종류' : 'Tab type'}
      >
        {TABS.map((tab, index) => (
          <button
            key={tab.id}
            id={`${id}-${tab.id}`}
            type="button"
            role="tab"
            aria-selected={selected === tab.id}
            aria-controls={`${id}-panel`}
            tabIndex={selected === tab.id ? 0 : -1}
            onClick={() => setSelected(tab.id)}
            onKeyDown={(event) => {
              const next =
                event.key === 'ArrowRight'
                  ? (index + 1) % TABS.length
                  : event.key === 'ArrowLeft'
                    ? (index + TABS.length - 1) % TABS.length
                    : event.key === 'Home'
                      ? 0
                      : event.key === 'End'
                        ? TABS.length - 1
                        : null
              if (next === null) return
              event.preventDefault()
              setSelected(TABS[next]!.id)
              document.getElementById(`${id}-${TABS[next]!.id}`)?.focus()
            }}
          >
            <TabKindIcon kind={tab.id} />
            <span>{ko ? tab.ko : tab.en}</span>
          </button>
        ))}
      </div>
      <div
        id={`${id}-panel`}
        role="tabpanel"
        aria-labelledby={`${id}-${selected}`}
        className="settings-stack"
      >
        <div className="tab-settings__shortcut">
          <span>{ko ? '탭 열기 단축키' : 'Open tab shortcut'}</span>
          <kbd>
            {parsed
              ? formatChord(parsed, window.bandal?.platform ?? 'unknown')
              : ko
                ? '미지정'
                : 'Unassigned'}
          </kbd>
          <button
            className="secondary-button"
            onClick={() => onNavigate('shortcuts')}
          >
            {ko ? '단축키 변경' : 'Edit shortcuts'}
          </button>
        </div>
        {selected === 'browser' ? (
          browserPanel
        ) : selected === 'chat' ? (
          aiPanel
        ) : selected === 'recording' ? (
          <RecordingDefaults settings={settings} />
        ) : selected === 'note' ? (
          <SettingsCard
            title={ko ? '마크다운 기본 설정' : 'Markdown defaults'}
            description={
              ko
                ? '글꼴은 열린 필기에도 적용됩니다. 제목 접두어는 새로 만드는 파일에 적용됩니다.'
                : 'Font changes apply to open notes. The title prefix applies to new files.'
            }
          >
            <label className="tab-settings__field">
              {ko ? '본문 글꼴' : 'Editor font'}
              <select
                disabled={!settings}
                value={settings?.editorFont ?? 'sans'}
                onChange={(event) =>
                  void savePreference({
                    editorFont: event.target.value as Settings['editorFont']
                  })
                }
              >
                {EDITOR_FONTS.map((font) => (
                  <option key={font} value={font}>
                    {font === 'sans'
                      ? ko
                        ? '고딕'
                        : 'Sans-serif'
                      : font === 'serif'
                        ? ko
                          ? '명조'
                          : 'Serif'
                        : ko
                          ? '고정폭'
                          : 'Monospace'}
                  </option>
                ))}
              </select>
            </label>
            <form
              className="tab-settings__field"
              onSubmit={(event) => {
                event.preventDefault()
                void savePreference({ tabs: { markdownTitlePrefix: prefix } })
              }}
            >
              <label htmlFor={`${id}-prefix`}>
                {ko ? '새 파일 제목 접두어' : 'New file title prefix'}
              </label>
              <div className="tab-settings__inline">
                <input
                  id={`${id}-prefix`}
                  maxLength={60}
                  value={prefix}
                  disabled={!settings}
                  onChange={(event) => setPrefix(event.target.value)}
                />
                <button
                  className="secondary-button"
                  disabled={!prefix.trim() || !settings}
                >
                  {ko ? '저장' : 'Save'}
                </button>
              </div>
            </form>
          </SettingsCard>
        ) : selected === 'whiteboard' ? (
          <SettingsCard
            title={ko ? '새 화이트보드' : 'New whiteboards'}
            description={
              ko
                ? '새로 만드는 화이트보드의 배경입니다. 기존 보드의 배경과 필기는 변경하지 않습니다.'
                : 'Default background for new boards. Existing boards and drawings are unchanged.'
            }
          >
            <label className="tab-settings__field">
              {ko ? '기본 배경' : 'Default background'}
              <select
                value={prefs?.whiteboardBackground ?? 'grid'}
                disabled={!prefs}
                onChange={(event) =>
                  void savePreference({
                    tabs: {
                      whiteboardBackground: event.target.value as
                        | 'grid'
                        | 'blank'
                        | 'dots'
                        | 'lines'
                    }
                  })
                }
              >
                {(['grid', 'dots', 'lines', 'blank'] as const).map(
                  (value, index) => (
                    <option key={value} value={value}>
                      {ko
                        ? ['격자', '점', '줄', '빈 배경'][index]
                        : ['Grid', 'Dots', 'Lines', 'Blank'][index]}
                    </option>
                  )
                )}
              </select>
            </label>
          </SettingsCard>
        ) : (
          <SettingsCard
            title={ko ? '학업 보드 기본 설정' : 'Study board defaults'}
            description={
              ko
                ? '다음에 새로 여는 학업 보드에 적용됩니다.'
                : 'Applies when a study board is next opened.'
            }
          >
            <label className="tab-settings__field">
              {ko ? '시작 화면' : 'Initial view'}
              <select
                value={prefs?.boardDefaultView ?? 'calendar'}
                disabled={!prefs}
                onChange={(event) =>
                  void savePreference({
                    tabs: {
                      boardDefaultView: event.target.value as
                        | 'calendar'
                        | 'board'
                    }
                  })
                }
              >
                <option value="calendar">{ko ? '캘린더' : 'Calendar'}</option>
                <option value="board">
                  {ko ? '칸반 보드' : 'Kanban board'}
                </option>
              </select>
            </label>
            <ToggleRow
              label={ko ? '완료한 항목 숨기기' : 'Hide completed tasks'}
              description={
                ko
                  ? '남은 할 일에 집중할 수 있도록 완료 항목을 숨깁니다.'
                  : 'Focus on the remaining tasks.'
              }
              checked={prefs?.boardHideDone ?? false}
              disabled={!prefs}
              onChange={(boardHideDone) =>
                void savePreference({ tabs: { boardHideDone } })
              }
            />
          </SettingsCard>
        )}
      </div>
      <SettingsCard title={ko ? '모든 탭의 공통 동작' : 'Common tab behavior'}>
        <ToggleRow
          label={ko ? '현재 탭 바로 옆에 열기' : 'Open beside the current tab'}
          description={
            ko
              ? '새 탭을 같은 그룹의 현재 탭 다음 위치에 엽니다.'
              : 'Insert new tabs after the active tab in the same group.'
          }
          checked={settings?.openAdjacentTab ?? false}
          disabled={!settings}
          onChange={(openAdjacentTab) =>
            void savePreference({ openAdjacentTab })
          }
        />
        <ToggleRow
          label={ko ? '마지막 과목 복원' : 'Restore last course'}
          description={
            ko
              ? '앱을 다시 열 때 마지막 과목과 저장된 탭 배치를 복원합니다.'
              : 'Restore the last course and its saved tab layout on startup.'
          }
          checked={settings?.restoreLastCourse ?? true}
          disabled={!settings}
          onChange={(restoreLastCourse) =>
            void savePreference({ restoreLastCourse })
          }
        />
      </SettingsCard>
    </div>
  )
}

function RecordingDefaults({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const ko = useLocale() === 'ko-KR'
  const [models, setModels] = useState<SpeechModelState[]>([])
  const [devices, setDevices] = useState<MediaDeviceInfo[]>([])
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    let alive = true
    void invoke('recordings:models', {})
      .then((value) => {
        if (alive) setModels(value)
      })
      .catch(() => {
        if (alive) setError('모델 목록을 불러오지 못했습니다.')
      })
    const refresh = (): void => {
      void navigator.mediaDevices
        .enumerateDevices()
        .then((value) => {
          if (alive)
            setDevices(value.filter((device) => device.kind === 'audioinput'))
        })
        .catch(() => undefined)
    }
    refresh()
    navigator.mediaDevices.addEventListener('devicechange', refresh)
    const off = onPush('recordings:modelsChanged', setModels)
    return () => {
      alive = false
      off()
      navigator.mediaDevices.removeEventListener('devicechange', refresh)
    }
  }, [])
  const prefs = settings?.tabs
  return (
    <>
      <SettingsCard
        title={ko ? '녹음과 자막' : 'Recording and captions'}
        description={
          ko
            ? '모델과 마이크 기본값은 다음 녹음부터 적용됩니다. 진행 중인 녹음은 변경하지 않습니다.'
            : 'Model and microphone defaults apply to the next recording, not an active capture.'
        }
      >
        <label className="tab-settings__field">
          {ko ? '기본 마이크' : 'Default microphone'}
          <select
            value={prefs?.recordingDeviceId ?? 'default'}
            disabled={!prefs}
            onChange={(event) =>
              void savePreference({
                tabs: { recordingDeviceId: event.target.value }
              })
            }
          >
            <option value="default">
              {ko ? '시스템 기본 마이크' : 'System default'}
            </option>
            {prefs?.recordingDeviceId !== 'default' &&
              prefs?.recordingDeviceId &&
              !devices.some(
                (device) => device.deviceId === prefs.recordingDeviceId
              ) && (
                <option value={prefs.recordingDeviceId}>
                  {ko
                    ? '저장된 마이크 (연결되지 않음)'
                    : 'Saved microphone (disconnected)'}
                </option>
              )}
            {devices
              .filter((device) => device.deviceId !== 'default')
              .map((device, index) => (
                <option key={device.deviceId} value={device.deviceId}>
                  {device.label ||
                    `${ko ? '마이크' : 'Microphone'} ${index + 1}`}
                </option>
              ))}
          </select>
        </label>
        <label className="tab-settings__field">
          {ko ? '기본 재생 속도' : 'Default playback speed'}
          <select
            value={prefs?.recordingPlaybackRate ?? 1}
            disabled={!prefs}
            onChange={(event) =>
              void savePreference({
                tabs: { recordingPlaybackRate: Number(event.target.value) }
              })
            }
          >
            {RECORDING_PLAYBACK_RATES.map((rate) => (
              <option key={rate} value={rate}>
                {rate}×
              </option>
            ))}
          </select>
        </label>
        <ToggleRow
          label={ko ? '설정·자료 패널 열어 두기' : 'Keep the setup panel open'}
          description={
            ko
              ? '끄면 녹음과 자막에 더 넓은 공간을 사용합니다.'
              : 'Turn off to give captions more room.'
          }
          checked={prefs?.recordingSidebarOpen ?? true}
          disabled={!prefs}
          onChange={(recordingSidebarOpen) =>
            void savePreference({ tabs: { recordingSidebarOpen } })
          }
        />
        <ToggleRow
          label={ko ? '실시간 자막 자동 따라가기' : 'Follow live captions'}
          description={
            ko
              ? '새 자막을 따라갑니다. 위로 스크롤하면 자동 이동을 멈춥니다.'
              : 'Follow incoming captions. Scrolling up pauses following.'
          }
          checked={prefs?.recordingFollowTranscript ?? true}
          disabled={!prefs}
          onChange={(recordingFollowTranscript) =>
            void savePreference({ tabs: { recordingFollowTranscript } })
          }
        />
      </SettingsCard>
      <SettingsCard
        title={
          ko
            ? '기본 음성 모델 · 다운로드'
            : 'Default speech model and downloads'
        }
        description={
          ko
            ? '설치 후 기기에서 처리합니다. 모델 파일은 모든 과목에서 함께 사용합니다. 수시간 발열·배터리 안정성 검증은 진행 중입니다.'
            : 'Models run locally and are shared across courses. Long-duration thermal and battery validation is still pending.'
        }
      >
        <SpeechModelPicker
          models={models}
          value={prefs?.recordingModel ?? 'whisper-large-v3-turbo'}
          disabled={!prefs}
          onChange={(recordingModel) =>
            void savePreference({ tabs: { recordingModel } })
          }
        />
        {error && <p role="alert">{error}</p>}
      </SettingsCard>
    </>
  )
}
