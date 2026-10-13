import { randomUUID } from 'node:crypto'
import type { PluginEditorRequest } from '../../../shared/types/pluginEditor'

export function createPluginEditorBridge(
  send: (request: PluginEditorRequest) => void,
) {
  const pending = new Map<
    string,
    {
      resolve(value: unknown): void
      reject(error: Error): void
      timer: NodeJS.Timeout
    }
  >()
  return {
    request(input: Omit<PluginEditorRequest, 'requestId'>): Promise<unknown> {
      const requestId = randomUUID()
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(requestId)
          reject(new Error('Editor did not respond'))
        }, 5_000)
        pending.set(requestId, { resolve, reject, timer })
        try {
          send({ ...input, requestId })
        } catch (error) {
          clearTimeout(timer)
          pending.delete(requestId)
          reject(error)
        }
      })
    },
    reply(id: string, value: unknown, error?: string): void {
      const item = pending.get(id)
      if (item === undefined) return
      pending.delete(id)
      clearTimeout(item.timer)
      if (error === undefined) item.resolve(value)
      else item.reject(new Error(error))
    },
    dispose(): void {
      for (const item of pending.values()) {
        clearTimeout(item.timer)
        item.reject(new Error('Editor bridge closed'))
      }
      pending.clear()
    },
  }
}
