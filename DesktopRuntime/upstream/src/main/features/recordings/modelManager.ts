import { createHash } from 'node:crypto'
import { createReadStream, createWriteStream, existsSync, statSync } from 'node:fs'
import { mkdir, rename, unlink, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { Readable, Transform } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import type { SpeechModelId, SpeechModelState } from '../../../shared/recording'
import { SPEECH_MODELS, speechModel } from './modelCatalog'
import { speechUnavailableReason } from './speechCompatibility'

export async function fileHash(path: string): Promise<string> {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return hash.digest('hex')
}
export function createModelManager(root: string, changed: (states: SpeechModelState[]) => void) {
  const progress = new Map<SpeechModelId, Partial<SpeechModelState>>()
  const controllers = new Map<SpeechModelId, AbortController>()
  const directory = (id: SpeechModelId): string => join(root, speechModel(id).id)
  const installed = (id: SpeechModelId): boolean => {
    const dir = directory(id)
    try {
      return (
        existsSync(join(dir, 'ready.json')) &&
        speechModel(id).files.every((file) => statSync(join(dir, file.name)).size === file.bytes)
      )
    } catch {
      return false
    }
  }
  function list(): SpeechModelState[] {
    return SPEECH_MODELS.map((model) => ({
      id: model.id,
      name: model.name,
      description: model.description,
      bytes: model.files.reduce((n, file) => n + file.bytes, 0),
      downloadedBytes: 0,
      status: installed(model.id) ? 'installed' : 'available',
      error: null,
      unavailableReason: speechUnavailableReason(model.id),
      ...progress.get(model.id)
    }))
  }
  function update(id: SpeechModelId, patch: Partial<SpeechModelState>): void {
    progress.set(id, { ...progress.get(id), ...patch })
    changed(list())
  }
  async function verify(id: SpeechModelId): Promise<string> {
    if (!installed(id)) {
      update(id, { status: 'available', error: null })
      throw new Error('먼저 음성 모델을 다운로드해 주세요.')
    }
    const dir = directory(id)
    for (const file of speechModel(id).files) {
      if ((await fileHash(join(dir, file.name))) !== file.sha256) {
        await unlink(join(dir, 'ready.json')).catch(() => undefined)
        const message = '모델 파일이 손상되었습니다. 다시 다운로드해 주세요.'
        update(id, { status: 'error', error: message })
        throw new Error(message)
      }
    }
    return dir
  }
  async function download(id: SpeechModelId): Promise<void> {
    const unavailable = speechUnavailableReason(id)
    if (unavailable) throw new Error(unavailable)
    const model = speechModel(id)
    if (controllers.has(id)) return
    const controller = new AbortController()
    controllers.set(id, controller)
    let downloaded = 0
    try {
      const dir = directory(id)
      await mkdir(dir, { recursive: true })
      await unlink(join(dir, 'ready.json')).catch(() => undefined)
      update(id, { status: 'downloading', downloadedBytes: 0, error: null })
      for (const file of model.files) {
        controller.signal.throwIfAborted()
        const target = join(dir, file.name)
        if (
          existsSync(target) &&
          statSync(target).size === file.bytes &&
          (await fileHash(target)) === file.sha256
        ) {
          downloaded += file.bytes
          continue
        }
        const partial = `${target}.part`
        const response = await fetch(
          file.url ?? `https://huggingface.co/${model.repo}/resolve/${model.revision}/${file.name}`,
          {
            signal: AbortSignal.any([controller.signal, AbortSignal.timeout(15 * 60 * 1000)])
          }
        )
        if (!response.ok || !response.body)
          throw new Error(`다운로드 실패 (${response.status}). 다시 시도해 주세요.`)
        let size = 0
        let lastProgress = 0
        const hash = createHash('sha256')
        const meter = new Transform({
          transform(chunk: Buffer, _encoding, callback) {
            size += chunk.length
            if (size > file.bytes) {
              callback(new Error('모델 파일 크기가 일치하지 않습니다.'))
              return
            }
            hash.update(chunk)
            if (Date.now() - lastProgress > 200) {
              lastProgress = Date.now()
              update(id, { downloadedBytes: downloaded + size })
            }
            callback(null, chunk)
          }
        })
        await pipeline(
          Readable.fromWeb(response.body as never),
          meter,
          createWriteStream(partial, { mode: 0o600 }),
          { signal: controller.signal }
        )
        if (size !== file.bytes || hash.digest('hex') !== file.sha256) {
          await unlink(partial).catch(() => undefined)
          throw new Error('모델 무결성 검사에 실패했습니다. 다시 다운로드해 주세요.')
        }
        controller.signal.throwIfAborted()
        await rename(partial, target)
        downloaded += size
      }
      controller.signal.throwIfAborted()
      update(id, { status: 'verifying', downloadedBytes: downloaded })
      await writeFile(
        join(directory(id), 'ready.json'),
        JSON.stringify({ revision: model.revision }),
        { mode: 0o600 }
      )
      progress.delete(id)
    } catch (error) {
      update(id, {
        status: controller.signal.aborted ? 'available' : 'error',
        error: controller.signal.aborted
          ? null
          : String(error instanceof Error ? error.message : error)
      })
    } finally {
      // These are exclusively our uncommitted download files. A cancelled
      // 240 MB install must not strand its partial download indefinitely.
      for (const file of model.files)
        await unlink(join(directory(id), `${file.name}.part`)).catch(() => undefined)
      controllers.delete(id)
      changed(list())
    }
  }
  return {
    list,
    verify,
    download,
    cancel(id: SpeechModelId) {
      speechModel(id)
      controllers.get(id)?.abort()
    },
    dispose() {
      for (const controller of controllers.values()) controller.abort()
    }
  }
}
