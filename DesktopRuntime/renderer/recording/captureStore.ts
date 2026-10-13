import { create } from 'zustand'
import type { RecordingSession, SpeechModelId } from '../../upstream/src/shared/recording'
import { invoke, onPush } from '../../upstream/src/renderer/src/lib/ipc'

interface CaptureState { session: RecordingSession | null; busy: boolean; level: number; error: string | null }
export const useCaptureStore = create<CaptureState>(() => ({ session: null, busy: false, level: 0, error: null }))
let serial = 0
let selectedDevice = 'default'
function native<T>(channel: string, request: unknown): Promise<T> {
  return (window.bandal.invoke as (channel: string, request: unknown) => Promise<T>)(channel, request)
}
function message(error: unknown): string { return error instanceof Error ? error.message : String(error) }
export function abandonCapture(reason: string): void {
  const active = useCaptureStore.getState()
  serial++
  useCaptureStore.setState({ session: null, level: 0, busy: false, error: reason })
  if (active.session || active.busy) void native('runtime:recordingAbandon', {}).catch(() => undefined)
}
export async function startCapture(session: RecordingSession, deviceId: string): Promise<void> {
  if (useCaptureStore.getState().busy || useCaptureStore.getState().session) throw new Error('이미 녹음이 진행 중입니다.')
  const token = ++serial
  useCaptureStore.setState({ busy: true, error: null })
  selectedDevice = deviceId
  try {
    const recording = await native<RecordingSession>('runtime:recordingStart', { id: session.id, deviceId })
    if (serial !== token) return
    useCaptureStore.setState({ session: recording, busy: false, level: 0 })
  } catch (error) {
    if (serial === token) useCaptureStore.setState({ session: null, busy: false, error: message(error) })
    throw error
  }
}
export async function pauseCapture(): Promise<void> {
  const { session, busy } = useCaptureStore.getState()
  if (!session || busy) return
  const token = serial
  useCaptureStore.setState({ busy: true })
  try {
    const next = session.status === 'paused'
      ? await native<RecordingSession>('runtime:recordingStart', { id: session.id, deviceId: selectedDevice })
      : await invoke('recordings:control', { id: session.id, action: 'pause' })
    if (token === serial) useCaptureStore.setState({ session: next, busy: false, level: 0 })
  } catch (error) {
    if (token === serial) { useCaptureStore.setState({ busy: false, error: message(error) }); abandonCapture(message(error)) }
  }
}
export async function stopCapture(): Promise<void> {
  const { session, busy } = useCaptureStore.getState()
  if (!session || busy) return
  const token = serial
  useCaptureStore.setState({ busy: true })
  try {
    await invoke('recordings:control', { id: session.id, action: 'stop' })
    if (token === serial) { serial++; useCaptureStore.setState({ session: null, busy: false, level: 0 }) }
  } catch (error) { if (token === serial) abandonCapture(message(error)) }
}
onPush('recordings:event', event => {
  const current = useCaptureStore.getState().session
  if (current?.id !== event.session.id) return
  if (event.session.status === 'interrupted') { serial++; useCaptureStore.setState({ session: null, busy: false, level: 0, error: event.session.error }); return }
  useCaptureStore.setState({ session: event.session })
})
;(window.bandal.on as (channel: string, callback: (event: { id: string; level: number }) => void) => () => void)('runtime:recordingLevel', event => {
  if (useCaptureStore.getState().session?.id === event.id) useCaptureStore.setState({ level: event.level })
})
export function localRecordingModel(model: SpeechModelId): SpeechModelId { return model === 'whisper-large-v3-turbo' ? 'zipformer-ko' : model }
const listeners = new Map<EventListenerOrEventListenerObject, () => void>()
export const nativeAudioDevices = {
  async enumerateDevices(): Promise<MediaDeviceInfo[]> {
    const devices = await native<Array<Omit<MediaDeviceInfo, 'toJSON'>>>('runtime:recordingDevices', {})
    return devices.map(device => ({ ...device, toJSON: () => device }))
  },
  addEventListener(_type: 'devicechange', callback: EventListenerOrEventListenerObject): void {
    if (listeners.has(callback)) return
    const dispose = (window.bandal.on as (channel: string, handler: () => void) => () => void)('runtime:recordingDevicesChanged', () => {
      const event = new Event('devicechange')
      if (typeof callback === 'function') callback(event); else callback.handleEvent(event)
    })
    listeners.set(callback, dispose)
  },
  removeEventListener(_type: 'devicechange', callback: EventListenerOrEventListenerObject): void { listeners.get(callback)?.(); listeners.delete(callback) }
}
