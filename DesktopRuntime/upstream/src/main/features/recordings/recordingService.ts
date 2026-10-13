import { powerSaveBlocker } from 'electron'
import type {
  RecordingEvent,
  RecordingSession,
  SpeechModelId,
  TranscriptSegment
} from '../../../shared/recording'
import { RECORDING_CHUNK_SAMPLES } from '../../../shared/recording'
import type { RecordingRepo } from './recordingRepo'
import type { createModelManager } from './modelManager'
import { createEngineClient } from './engineClient'
import type { EngineResult } from './engineProtocol'

interface Active {
  id: string
  lastSession: RecordingSession
  engine: ReturnType<typeof createEngineClient> | null
  cursor: number
  busy: boolean
  flushed: boolean
  rtf: number | null
  timings?: { samples: number; elapsedMs: number }[]
  blocker: number
  lastAudioAt: number
}
export function createRecordingService(deps: {
  repo: RecordingRepo
  models: ReturnType<typeof createModelManager>
  hostEntry: string
  emit(event: RecordingEvent): void
  onActivityChanged?(active: boolean, session: RecordingSession): void
}) {
  const { repo } = deps
  let active: Active | null = null
  let starting = false
  let disposed = false
  let thermal = 'unknown'
  let timer: ReturnType<typeof setTimeout> | null = null
  const emit = (
    session: RecordingSession,
    segment: TranscriptSegment | null = null,
    result?: EngineResult
  ): void => {
    if (active?.id === session.id) active.lastSession = session
    deps.emit({
      session,
      segment,
      partial: result?.partial ?? null,
      rtf: active?.rtf ?? null,
      cooling: thermal === 'critical'
    })
  }
  function release(current: Active, session = current.lastSession): void {
    current.engine?.dispose()
    if (powerSaveBlocker.isStarted(current.blocker)) powerSaveBlocker.stop(current.blocker)
    if (active === current) active = null
    deps.onActivityChanged?.(false, session)
  }
  function schedule(): void {
    if (disposed || timer || !active) return
    timer = setTimeout(
      () => {
        timer = null
        void pump()
      },
      thermal === 'critical' ? 2000 : thermal === 'serious' ? 250 : 15
    )
  }
  async function pump(): Promise<void> {
    const current = active
    if (!current || current.busy || !current.engine || disposed) return
    if (thermal === 'critical') {
      schedule()
      return
    }
    current.busy = true
    try {
      let session = repo.get(current.id)
      let result: EngineResult | null = null
      if (current.cursor < session.samples) {
        const audio = repo.readAudio(session, current.cursor, RECORDING_CHUNK_SAMPLES)
        const response = await current.engine.request({
          type: 'audio',
          samples: audio,
          preview: session.status === 'recording' && session.samples - current.cursor < 16000 * 6
        })
        if (active !== current || disposed) return
        // Whisper decodes in bursts after buffering speech. A per-IPC-chunk
        // ratio would report a false overload every time a sentence finishes.
        const timings = (current.timings ??= [])
        timings.push({ samples: audio.length, elapsedMs: response.elapsedMs })
        if (timings.length > 60) timings.shift()
        current.rtf =
          timings.reduce((sum, item) => sum + item.elapsedMs, 0) /
          (timings.reduce((sum, item) => sum + item.samples, 0) / 16)
        current.cursor += audio.length
        current.flushed = false
        result = response.result
      } else if (session.status !== 'recording' && !current.flushed) {
        const response = await current.engine.request({ type: 'flush' })
        if (active !== current || disposed) return
        result = response.result
        current.flushed = true
      }
      session = repo.get(current.id) // microphone writes may have advanced it
      if (result) {
        session = repo.save({ ...session, transcribedSamples: current.cursor })
        for (const segment of result.segments) {
          if (segment.endSample <= segment.startSample || segment.endSample > session.samples)
            continue
          emit(
            session,
            repo.addSegment(session.id, segment.startSample, segment.endSample, segment.text),
            result
          )
        }
        emit(session, null, result)
      }
      if (session.status === 'processing' && current.flushed && current.cursor >= session.samples) {
        session = repo.save({ ...session, status: 'complete', error: null })
        release(current, session)
        emit(session)
      }
    } catch (error) {
      if (disposed || active !== current) return
      current.engine?.dispose()
      current.engine = null
      try {
        const session = repo.get(current.id)
        const next = repo.save({
          ...session,
          status: session.status === 'processing' ? 'interrupted' : session.status,
          error: error instanceof Error ? error.message : String(error)
        })
        if (next.status === 'interrupted') release(current, next)
        emit(next)
      } catch {
        interrupt('자막 상태를 저장하지 못해 녹음을 중단했습니다. 저장 공간을 확인해 주세요.')
      }
    } finally {
      current.busy = false
      if (active === current && current.engine) {
        const session = repo.get(current.id)
        if (
          current.cursor < session.samples ||
          (session.status !== 'recording' && !current.flushed)
        )
          schedule()
      }
    }
  }
  async function control(
    id: string,
    action: 'start' | 'pause' | 'stop' | 'retry' | 'interrupt',
    modelId?: SpeechModelId
  ): Promise<RecordingSession> {
    let session = repo.get(id)
    if (!['start', 'pause', 'stop', 'retry', 'interrupt'].includes(action))
      throw new Error('지원하지 않는 녹음 동작입니다.')
    if (action === 'interrupt') {
      if (active?.id === id)
        return interrupt('녹음 입력 또는 저장이 중단되었습니다. 저장된 음성을 확인해 주세요.')!
      return repo.get(id)
    }
    if (starting) throw new Error('음성 모델을 준비하고 있습니다. 잠시 기다려 주세요.')
    if (action === 'start' || action === 'retry') {
      if (active && active.id !== id)
        throw new Error('다른 녹음이 진행 중입니다. 먼저 해당 녹음을 종료해 주세요.')
      if (action === 'start' && session.status === 'paused' && active) {
        active.lastAudioAt = Date.now()
        session = repo.save({ ...session, status: 'recording' })
        emit(session)
        return session
      }
      if (active) throw new Error('이미 진행 중인 녹음입니다.')
      if (action === 'start' && session.status !== 'ready')
        throw new Error('종료된 녹음에는 이어 녹음할 수 없습니다. 새 녹음을 시작해 주세요.')
      if (
        action === 'retry' &&
        (session.samples === 0 || ['recording', 'paused'].includes(session.status))
      )
        throw new Error('녹음을 종료한 뒤 다시 시도해 주세요.')
      starting = true
      let engine: ReturnType<typeof createEngineClient> | null = null
      try {
        const selectedModel = action === 'retry' ? (modelId ?? session.modelId) : session.modelId
        const directory = await deps.models.verify(selectedModel)
        if (disposed) throw new Error('앱이 종료되었습니다.')
        engine = createEngineClient(deps.hostEntry)
        await engine.request({
          type: 'init',
          modelId: selectedModel,
          directory
        })
        if (disposed) throw new Error('앱이 종료되었습니다.')
        if (action === 'retry') session = repo.resetTranscript(id)
        active = {
          id,
          lastSession: session,
          engine,
          cursor: 0,
          busy: false,
          flushed: false,
          rtf: null,
          blocker: powerSaveBlocker.start('prevent-app-suspension'),
          lastAudioAt: Date.now()
        }
        deps.onActivityChanged?.(true, session)
        session = repo.save({
          ...session,
          modelId: selectedModel,
          status: action === 'retry' ? 'processing' : 'recording',
          error: null
        })
        emit(session)
        schedule()
        return session
      } catch (error) {
        if (active?.engine === engine && active) release(active)
        else engine?.dispose()
        throw error
      } finally {
        starting = false
      }
    }
    if (!active || active.id !== id) {
      // After a capture failure, the renderer may send a second stop.
      if (action === 'stop' && ['complete', 'interrupted', 'ready'].includes(session.status))
        return session
      throw new Error('진행 중인 녹음이 아닙니다.')
    }
    if (action === 'pause' && session.status !== 'recording')
      throw new Error('녹음 중에만 일시정지할 수 있습니다.')
    session = repo.save({
      ...session,
      status: action === 'pause' ? 'paused' : active.engine ? 'processing' : 'interrupted'
    })
    if (!active.engine && action === 'stop') release(active, session)
    emit(session)
    schedule()
    return session
  }
  function interrupt(reason: string): RecordingSession | null {
    if (!active) return null
    const current = active
    let session: RecordingSession = {
      ...current.lastSession,
      status: 'interrupted',
      error: reason
    }
    try {
      session = repo.save({
        ...repo.get(current.id),
        status: 'interrupted',
        error: reason
      })
    } catch {
      // A full/read-only metadata disk must still release the microphone and
      // inference process. Startup recovery repairs the last persisted state.
      session.error = `${reason} 녹음 상태도 저장하지 못했습니다. 앱을 다시 열면 복구를 시도합니다.`
    }
    release(current, session)
    emit(session)
    return session
  }
  const watchdog = setInterval(() => {
    if (!active || disposed) return
    if (active.lastSession.status === 'recording' && Date.now() - active.lastAudioAt > 15_000)
      interrupt('마이크 입력이 15초 이상 끊겨 녹음을 중단했습니다. 저장한 음성은 보존됩니다.')
  }, 5000)
  watchdog.unref()
  return {
    getActiveSession: () => {
      if (!active) return null
      try {
        return repo.get(active.id)
      } catch {
        return active.lastSession
      }
    },
    control,
    append(id: string, sequence: number, pcm: Uint8Array) {
      if (!active || active.id !== id) throw new Error('활성 녹음을 찾을 수 없습니다.')
      const session = repo.append(id, sequence, pcm)
      active.lastSession = session
      active.lastAudioAt = Date.now()
      // Feed wakeups carry no audio. At most ONE inference chunk is in memory.
      schedule()
      return { nextSequence: session.nextSequence, samples: session.samples }
    },
    interrupt,
    setThermalState(value: string) {
      thermal = value
      if (active) emit(repo.get(active.id))
      schedule()
    },
    dispose() {
      disposed = true
      clearInterval(watchdog)
      if (timer) clearTimeout(timer)
      if (active) release(active)
      deps.models.dispose()
    }
  }
}
