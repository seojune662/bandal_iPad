import { join } from 'node:path'
import type { SpeechModelId } from '../../../shared/recording'
import { RECORDING_SAMPLE_RATE as RATE } from '../../../shared/recording'
import type { EngineResult } from './engineProtocol'

interface Stream {
  acceptWaveform(input: { sampleRate: number; samples: Float32Array }): void
  inputFinished(): void
}
interface Recognizer {
  createStream(): Stream
  decode(stream: Stream): void
  getResult(stream: Stream): { text: string; tokens?: string[] }
  isReady(stream: Stream): boolean
  isEndpoint(stream: Stream): boolean
}
interface VoiceDetector {
  acceptWaveform(samples: Float32Array): void
  isEmpty(): boolean
  front(copy: boolean): { start: number; samples: Float32Array }
  pop(): void
  flush(): void
  reset(): void
}
interface Sherpa {
  OnlineRecognizer: new (config: unknown) => Recognizer
  OfflineRecognizer: new (config: unknown) => Recognizer
  Vad: new (config: unknown, seconds: number) => VoiceDetector
}

// This module is loaded ONLY by the utility process (or an explicit benchmark).
// Native inference never runs in Electron's main/renderer threads.
export function createSpeechEngine(
  modelId: Exclude<SpeechModelId, 'whisper-large-v3-turbo'>,
  directory: string
) {
  const sherpa = require('sherpa-onnx-node') as Sherpa
  const file = (name: string): string => join(directory, name)
  const common = {
    tokens: file('tokens.txt'),
    numThreads: 2,
    provider: 'cpu',
    debug: 0
  }
  const online = modelId === 'zipformer-ko'
  const recognizer = online
    ? new sherpa.OnlineRecognizer({
        featConfig: { sampleRate: RATE, featureDim: 80 },
        modelConfig: {
          ...common,
          transducer: {
            encoder: file('encoder-epoch-99-avg-1.int8.onnx'),
            decoder: file('decoder-epoch-99-avg-1.int8.onnx'),
            joiner: file('joiner-epoch-99-avg-1.int8.onnx')
          }
        },
        enableEndpoint: 1,
        rule1MinTrailingSilence: 2.4,
        rule2MinTrailingSilence: 0.8,
        rule3MinUtteranceLength: 15,
        decodingMethod: 'greedy_search'
      })
    : new sherpa.OfflineRecognizer({
        featConfig: { sampleRate: RATE, featureDim: 80 },
        modelConfig: {
          ...common,
          senseVoice: {
            model: file('model.int8.onnx'),
            useInverseTextNormalization: 1
          }
        }
      })
  const vad = online
    ? null
    : new sherpa.Vad(
        {
          sileroVad: {
            model: file('silero_vad.onnx'),
            threshold: 0.5,
            minSilenceDuration: 0.7,
            minSpeechDuration: 0.25,
            maxSpeechDuration: 12,
            windowSize: 512
          },
          sampleRate: RATE,
          numThreads: 1,
          provider: 'cpu',
          debug: 0
        },
        30
      )
  let stream = online ? recognizer.createStream() : null
  let received = 0
  let start = 0
  let vadBase = 0
  let vadPending = new Float32Array(512)
  let vadUsed = 0
  const clean = (text: string): string => text.replace(/<\|[^|]*\|>/g, '').trim()
  const onlineText = (): string => {
    const result = recognizer.getResult(stream!)
    // The Korean model's display text strips token-leading spaces; retain
    // its word boundaries instead of inventing a spacing postprocessor.
    return clean(result.tokens?.join('').replaceAll('▁', ' ') ?? result.text)
  }
  function finishOnline(result: EngineResult): void {
    if (!stream) return
    stream.acceptWaveform({
      sampleRate: RATE,
      samples: new Float32Array(RATE * 0.4)
    })
    stream.inputFinished()
    while (recognizer.isReady(stream)) recognizer.decode(stream)
    const text = onlineText()
    if (text && received > start)
      result.segments.push({ startSample: start, endSample: received, text })
    // Recreate per utterance: native acoustic features must not retain a
    // multi-hour history even when silence/endpoint detection fails.
    stream = recognizer.createStream()
    start = received
    result.partial = null
  }
  function drainVad(result: EngineResult): void {
    if (!vad) return
    while (!vad.isEmpty()) {
      const speech = vad.front(false)
      const segmentStream = recognizer.createStream()
      segmentStream.acceptWaveform({
        sampleRate: RATE,
        samples: speech.samples
      })
      recognizer.decode(segmentStream)
      const text = clean(recognizer.getResult(segmentStream).text)
      if (text)
        result.segments.push({
          startSample: vadBase + speech.start,
          endSample: Math.min(received, vadBase + speech.start + speech.samples.length),
          text
        })
      vad.pop()
    }
  }
  return {
    accept(samples: Float32Array): EngineResult {
      const result: EngineResult = { segments: [], partial: null }
      received += samples.length
      if (stream) {
        stream.acceptWaveform({ sampleRate: RATE, samples })
        while (recognizer.isReady(stream)) recognizer.decode(stream)
        const text = onlineText()
        result.partial = text ? { startSample: start, text } : null
        if (recognizer.isEndpoint(stream) || received - start >= RATE * 15) finishOnline(result)
      } else if (vad) {
        // Silero must receive its exact 512-sample analysis windows. Passing
        // IPC-sized blocks skips intermediate VAD decisions in the binding.
        for (let i = 0; i < samples.length; i++) {
          vadPending[vadUsed++] = samples[i]!
          if (vadUsed === 512) {
            vad.acceptWaveform(vadPending)
            vadUsed = 0
            drainVad(result)
          }
        }
      }
      return result
    },
    flush(): EngineResult {
      const result: EngineResult = { segments: [], partial: null }
      if (online) finishOnline(result)
      else if (vad) {
        if (vadUsed) {
          vadPending.fill(0, vadUsed)
          vad.acceptWaveform(vadPending)
        }
        vad.flush()
        drainVad(result)
        vad.reset()
        vadBase = received
        vadPending = new Float32Array(512)
        vadUsed = 0
      }
      return result
    }
  }
}
