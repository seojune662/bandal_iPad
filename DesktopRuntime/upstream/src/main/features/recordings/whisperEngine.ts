import { join } from 'node:path'
import type { TranscribeResult } from '@fugood/whisper.node'
import { RECORDING_SAMPLE_RATE as RATE } from '../../../shared/recording'
import type { EngineResult } from './engineProtocol'
import { speechUnavailableReason } from './speechCompatibility'

interface VoiceDetector {
  acceptWaveform(samples: Float32Array): void
  isDetected(): boolean
  isEmpty(): boolean
  front(copy: boolean): { start: number; samples: Float32Array }
  pop(): void
  flush(): void
  reset(): void
}

// The scheduling layer is independent of the native bindings so silence,
// timestamps, pause/resume and memory bounds can be tested without a GPU.
export function createWhisperStream(
  vad: VoiceDetector,
  decode: (samples: Float32Array) => Promise<TranscribeResult>
) {
  const ring = new Float32Array(RATE * 30)
  let received = 0
  let vadBase = 0
  let frameUsed = 0
  let frame = new Float32Array(512)
  let openStart: number | null = null
  let sealedThrough = 0
  let hasSpeech = false
  let quietSamples = 0
  let lastEnd = 0
  let nextPreview = 0
  let previewInterval = RATE * 4
  let partial: EngineResult['partial'] = null

  const clean = (text: string): string => text.replace(/<\|[^|]*\|>/g, '').trim()
  async function transcribe(samples: Float32Array): Promise<TranscribeResult> {
    const before = performance.now()
    const result = await decode(samples)
    if (result.isAborted) throw new Error('음성 전사가 중단되었습니다.')
    // Spend at most roughly a quarter of audio time on speculative previews.
    // The native model remains resident; never reload it for each window.
    previewInterval = Math.max(RATE * 4, (performance.now() - before) * 16 * 4)
    return result
  }
  function windowAudio(start: number): Float32Array {
    const audio = new Float32Array(received - start)
    for (let i = 0; i < audio.length; i++) audio[i] = ring[(start + i) % ring.length]!
    return audio
  }
  async function finalize(result: EngineResult): Promise<void> {
    if (openStart !== null && hasSpeech) {
      const base = openStart
      const decoded = await transcribe(windowAudio(base))
      for (const segment of decoded.segments) {
        // The Node binding converts whisper.cpp's 10-ms units to MILLISECONDS.
        // Clamp padding/rounding to
        // real captured audio and keep the persistent transcript monotonic.
        const startSample = Math.max(lastEnd, base + Math.round((segment.t0 * RATE) / 1000))
        const endSample = Math.min(received, base + Math.round((segment.t1 * RATE) / 1000))
        const text = clean(segment.text)
        if (text && endSample > startSample) {
          result.segments.push({ startSample, endSample, text })
          lastEnd = endSample
        }
      }
    }
    sealedThrough = received
    partial = null
    openStart = null
    hasSpeech = false
    quietSamples = 0
  }
  function inspectFrame(): boolean {
    vad.acceptWaveform(frame)
    const speech = vad.isDetected()
    let endpoint = false
    while (!vad.isEmpty()) {
      const speech = vad.front(false)
      if (vadBase + speech.start + speech.samples.length > sealedThrough) {
        endpoint = true
        openStart ??= Math.max(sealedThrough, vadBase + speech.start)
      }
      vad.pop()
    }
    const rms = Math.sqrt(frame.reduce((sum, value) => sum + value * value, 0) / frame.length)
    quietSamples = rms < 0.006 ? quietSamples + frameUsed : 0
    // VAD is a boundary hint, not a destructive crop. On the real lecture it
    // missed the first six seconds. Keep audible pre-speech and short pauses
    // in a contiguous window, but require VAD evidence before running Whisper
    // so stationary background noise alone doesn't trigger transcription.
    if ((speech || rms >= 0.006) && openStart === null) {
      openStart = Math.max(sealedThrough, received - frameUsed - Math.round(RATE * 0.4))
      nextPreview = received + previewInterval
    }
    hasSpeech ||= speech || endpoint
    return endpoint
  }
  return {
    async accept(samples: Float32Array, preview = true): Promise<EngineResult> {
      const result: EngineResult = { segments: [], partial: null }
      // Consume exact VAD frames; the IPC producer sends half-second blocks.
      for (const sample of samples) {
        ring[received % ring.length] = sample
        received++
        frame[frameUsed++] = sample
        if (frameUsed === 512) {
          const endpoint = inspectFrame()
          frameUsed = 0
          const length = openStart === null ? 0 : received - openStart
          // Merge brief utterances for enough Korean academic context. A
          // continuous lecturer is still bounded below Whisper's 30-s limit.
          if (
            length >= RATE * 28 ||
            (length >= RATE * 12 && (quietSamples >= RATE * 0.8 || endpoint))
          )
            await finalize(result)
        }
      }
      if (preview && openStart !== null && hasSpeech && received >= nextPreview) {
        const start = Math.max(openStart, received - ring.length)
        const decoded = await transcribe(windowAudio(start))
        const text = clean(decoded.result)
        partial = text ? { startSample: start, text } : null
        nextPreview = received + previewInterval
      }
      result.partial = partial
      return result
    },
    async flush(): Promise<EngineResult> {
      const result: EngineResult = { segments: [], partial: null }
      if (frameUsed) {
        frame.fill(0, frameUsed)
        inspectFrame()
      }
      vad.flush()
      while (!vad.isEmpty()) {
        const speech = vad.front(false)
        if (vadBase + speech.start + speech.samples.length > sealedThrough) {
          hasSpeech = true
          openStart ??= Math.max(sealedThrough, vadBase + speech.start)
        }
        vad.pop()
      }
      await finalize(result)
      vad.reset()
      vadBase = received
      frameUsed = 0
      frame = new Float32Array(512)
      openStart = null
      partial = null
      return result
    }
  }
}

// Called only in the isolated speech utility process (or explicit benchmark).
export async function createWhisperEngine(directory: string) {
  const unavailable = speechUnavailableReason('whisper-large-v3-turbo')
  if (unavailable) throw new Error(unavailable)
  const { initWhisper } = require('@fugood/whisper.node') as typeof import('@fugood/whisper.node')
  const { Vad } = require('sherpa-onnx-node') as {
    Vad: new (config: unknown, seconds: number) => VoiceDetector
  }
  const vad = new Vad(
    {
      sileroVad: {
        model: join(directory, 'silero_vad.onnx'),
        threshold: 0.5,
        minSilenceDuration: 0.8,
        minSpeechDuration: 0.25,
        maxSpeechDuration: 24,
        windowSize: 512
      },
      sampleRate: RATE,
      numThreads: 1,
      provider: 'cpu',
      debug: 0
    },
    30
  )
  const context = await initWhisper({
    filePath: join(directory, 'ggml-large-v3-turbo.bin'),
    useGpu: process.platform === 'darwin' && process.arch === 'arm64',
    useFlashAttn: true
  })
  return {
    ...createWhisperStream(vad, async (samples) => {
      const pcm = new Int16Array(samples.length)
      for (let i = 0; i < samples.length; i++)
        pcm[i] = Math.round(
          Math.max(-1, Math.min(1, samples[i]!)) * (samples[i]! < 0 ? 32768 : 32767)
        )
      return context.transcribeData(pcm.buffer, {
        language: 'ko',
        translate: false,
        maxThreads: 2,
        maxContext: 0,
        temperature: 0,
        temperatureInc: 0,
        bestOf: 1
      }).promise
    }),
    dispose: () => context.release()
  }
}
