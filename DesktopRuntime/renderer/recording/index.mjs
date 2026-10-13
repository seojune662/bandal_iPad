import { fileURLToPath } from 'node:url'
const adapter = fileURLToPath(new URL('./captureStore.ts', import.meta.url))
function replace(source, needle, value, count = 1) {
  if (source.split(needle).length - 1 !== count) throw new Error(`Native recording adapter anchor changed: ${needle}`)
  return source.split(needle).join(value)
}
export default function nativeRecordingPlugin() {
  return { name: 'bandal-native-recording', enforce: 'pre', transform(source, id) {
    if (id.endsWith('/features/recordings/captureStore.ts')) return { code: `export * from ${JSON.stringify(adapter)}`, map: null }
    if (!id.endsWith('/features/recordings/RecordingTab.tsx')) return null
    let code = `import { nativeAudioDevices, localRecordingModel } from ${JSON.stringify(adapter)}\n` + source
    code = replace(code, 'navigator.mediaDevices', 'nativeAudioDevices', 3)
    code = replace(code, '    preferences.recordingModel\n', '    localRecordingModel(preferences.recordingModel)\n')
    code = replace(code, 'setModelId(settings.tabs.recordingModel)', 'setModelId(localRecordingModel(settings.tabs.recordingModel))')
    code = replace(code, 'setModelId(settingsSnapshot().tabs.recordingModel)', 'setModelId(localRecordingModel(settingsSnapshot().tabs.recordingModel))')
    return { code, map: null }
  } }
}
