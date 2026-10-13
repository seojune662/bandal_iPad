import { create } from 'zustand'
import type { RecordingSession } from '../../../../shared/recording'
import { invoke } from '../../lib/ipc'
import workletUrl from './pcm-worklet.js?url&no-inline'

interface CaptureState {
  session: RecordingSession | null
  busy: boolean
  level: number
  error: string | null
}
export const useCaptureStore = create<CaptureState>(() => ({
  session: null,
  busy: false,
  level: 0,
  error: null
}))
let context: AudioContext | null = null
let media: MediaStream | null = null
let source: MediaStreamAudioSourceNode | null = null
let worklet: AudioWorkletNode | null = null
let sink: GainNode | null = null
let queue: Promise<void> = Promise.resolve()
let queued = 0
let sequence = 0
let failure: Error | null = null
let flushed: (() => void) | null = null
let stopping = false
let captureSerial = 0

function disposeAudio(): void {
  if (worklet) {
    worklet.port.onmessage = null
    worklet.port.close()
  }
  worklet?.disconnect()
  source?.disconnect()
  sink?.disconnect()
  for (const track of media?.getTracks() ?? []) {
    track.onended = null
    track.stop()
  }
  void context?.close()
  context = null
  media = null
  source = null
  worklet = null
  sink = null
}
export function abandonCapture(reason: string): void {
  captureSerial++
  disposeAudio()
  failure = new Error(reason)
  flushed?.()
  flushed = null
  useCaptureStore.setState({ session: null, level: 0, busy: false, error: reason })
}
async function failCapture(error: unknown, serial = captureSerial): Promise<void> {
  if (serial !== captureSerial) return
  const id = useCaptureStore.getState().session?.id
  const message = error instanceof Error ? error.message : String(error)
  abandonCapture(message)
  if (id) await invoke('recordings:control', { id, action: 'interrupt' }).catch(() => undefined)
}
export async function startCapture(session: RecordingSession, deviceId: string): Promise<void> {
  if (useCaptureStore.getState().busy || useCaptureStore.getState().session)
    throw new Error('이미 녹음이 진행 중입니다.')
  useCaptureStore.setState({ busy: true, error: null })
  const serial = ++captureSerial
  let started = false
  try {
    // Request access before spending time loading a model, but no samples are
    // saved until the model is ready and the explicit recording state starts.
    const acquiredMedia = await navigator.mediaDevices.getUserMedia({
      audio: {
        ...(deviceId !== 'default' ? { deviceId: { exact: deviceId } } : {}),
        channelCount: 1,
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false
      },
      video: false
    })
    if (serial !== captureSerial) {
      for (const track of acquiredMedia.getTracks()) track.stop()
      throw new Error('녹음 시작이 취소되었습니다.')
    }
    media = acquiredMedia
    context = new AudioContext({ sampleRate: 16000, latencyHint: 'balanced' })
    if (context.sampleRate !== 16000)
      throw new Error('이 기기에서 16 kHz 오디오를 준비하지 못했습니다.')
    await context.audioWorklet.addModule(workletUrl)
    if (serial !== captureSerial) throw new Error('녹음 시작이 취소되었습니다.')
    const recording = await invoke('recordings:control', { id: session.id, action: 'start' })
    started = true
    if (serial !== captureSerial) throw new Error('녹음 시작이 취소되었습니다.')
    sequence = recording.nextSequence
    failure = null
    queued = 0
    queue = Promise.resolve()
    useCaptureStore.setState({ session: recording, busy: false, level: 0 })
    worklet = new AudioWorkletNode(context, 'bandal-recording-pcm')
    worklet.port.onmessage = (
      event: MessageEvent<{ pcm?: ArrayBuffer; level?: number; flushed?: boolean }>
    ) => {
      if (serial !== captureSerial) return
      if (event.data.flushed) {
        flushed?.()
        flushed = null
        return
      }
      if (!event.data.pcm || failure) return
      const pcm = new Uint8Array(event.data.pcm)
      const seq = sequence++
      if (++queued > 20) {
        void failCapture(
          new Error(
            '디스크 저장이 10초 이상 지연되어 녹음을 멈췄습니다. 저장 공간을 확인해 주세요.'
          ),
          serial
        )
        return
      }
      useCaptureStore.setState({ level: event.data.level ?? 0 })
      queue = queue
        .then(async () => {
          if (failure || serial !== captureSerial) return
          const saved = await invoke('recordings:append', { id: recording.id, sequence: seq, pcm })
          const current = useCaptureStore.getState().session
          if (serial === captureSerial && current?.id === recording.id)
            useCaptureStore.setState({ session: { ...current, ...saved } })
        })
        .catch((error: unknown) => {
          if (serial !== captureSerial) return
          failure = error instanceof Error ? error : new Error(String(error))
          void failCapture(failure, serial)
        })
        .finally(() => {
          if (serial === captureSerial) queued--
        })
    }
    source = context.createMediaStreamSource(media)
    sink = context.createGain()
    sink.gain.value = 0
    source.connect(worklet)
    worklet.connect(sink)
    sink.connect(context.destination)
    for (const track of media.getAudioTracks())
      track.onended = () => {
        void failCapture(
          new Error('마이크 연결이 끊겨 녹음을 중단했습니다. 저장한 음성은 보존됩니다.'),
          serial
        )
      }
    await context.resume()
  } catch (error) {
    // Cleanup belongs to this attempt. A cancelled startup may finish after a
    // different capture acquired the global audio resources.
    if (serial === captureSerial) disposeAudio()
    if (started)
      await invoke('recordings:control', { id: session.id, action: 'interrupt' }).catch(
        () => undefined
      )
    if (serial !== captureSerial) throw error
    useCaptureStore.setState({
      session: null,
      busy: false,
      error: error instanceof Error ? error.message : String(error)
    })
    throw error
  }
}
async function flushInput(): Promise<void> {
  if (!worklet) {
    await queue
    return
  }
  await new Promise<void>((resolve, reject) => {
    const timeout = window.setTimeout(() => {
      flushed = null
      reject(new Error('마지막 음성 구간을 저장하지 못했습니다.'))
    }, 5000)
    flushed = () => {
      clearTimeout(timeout)
      resolve()
    }
    worklet!.port.postMessage('pause')
  })
  await queue
  if (failure) throw failure
}
export async function pauseCapture(): Promise<void> {
  const session = useCaptureStore.getState().session
  if (!session || stopping || useCaptureStore.getState().busy) return
  useCaptureStore.setState({ busy: true })
  const serial = captureSerial
  try {
    if (session.status === 'paused') {
      const next = await invoke('recordings:control', { id: session.id, action: 'start' })
      if (serial !== captureSerial) return
      await context?.resume()
      if (serial !== captureSerial) return
      for (const track of media?.getAudioTracks() ?? []) track.enabled = true
      worklet?.port.postMessage('resume')
      useCaptureStore.setState({ session: next })
    } else {
      await flushInput()
      if (serial !== captureSerial) return
      for (const track of media?.getAudioTracks() ?? []) track.enabled = false
      await context?.suspend()
      if (serial !== captureSerial) return
      const next = await invoke('recordings:control', { id: session.id, action: 'pause' })
      if (serial === captureSerial) useCaptureStore.setState({ session: next, level: 0 })
    }
  } catch (error) {
    await failCapture(error, serial)
  } finally {
    if (serial === captureSerial) useCaptureStore.setState({ busy: false })
  }
}
export async function stopCapture(): Promise<void> {
  const session = useCaptureStore.getState().session
  if (!session || stopping || useCaptureStore.getState().busy) return
  const serial = captureSerial
  stopping = true
  useCaptureStore.setState({ busy: true })
  try {
    if (session.status !== 'paused') await flushInput()
    if (serial !== captureSerial) return
    await invoke('recordings:control', { id: session.id, action: 'stop' })
  } catch (error) {
    await failCapture(error, serial)
  } finally {
    if (serial === captureSerial) {
      captureSerial++
      disposeAudio()
      useCaptureStore.setState({ session: null, busy: false, level: 0 })
    }
    stopping = false
  }
}
