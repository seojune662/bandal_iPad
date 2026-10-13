import type { EngineRequest, EngineResponse, EngineResult } from './engineProtocol'
import { createSpeechEngine } from './speechEngine'
import { createWhisperEngine } from './whisperEngine'

let engine: {
  accept(samples: Float32Array, preview?: boolean): EngineResult | Promise<EngineResult>
  flush(): EngineResult | Promise<EngineResult>
} | null = null
process.parentPort.on('message', async (event) => {
  const req = event.data as EngineRequest
  const before = performance.now()
  let response: EngineResponse
  try {
    if (req.type === 'init') {
      if (engine) throw new Error('이미 준비된 음성 엔진입니다.')
      engine =
        req.modelId === 'whisper-large-v3-turbo'
          ? await createWhisperEngine(req.directory)
          : createSpeechEngine(req.modelId, req.directory)
      response = {
        seq: req.seq,
        result: { segments: [], partial: null },
        elapsedMs: performance.now() - before
      }
    } else {
      if (!engine) throw new Error('음성 엔진이 준비되지 않았습니다.')
      const result = await (req.type === 'audio'
        ? engine.accept(req.samples, req.preview)
        : engine.flush())
      response = {
        seq: req.seq,
        result,
        elapsedMs: performance.now() - before
      }
    }
  } catch (error) {
    response = {
      seq: req.seq,
      error: error instanceof Error ? error.message : String(error)
    }
  }
  process.parentPort.postMessage(response)
})
