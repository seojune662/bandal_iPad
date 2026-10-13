interface SaveJob {
  keys: string[]
  versions: Map<string, number>
  save(keys: readonly string[]): Promise<void>
}
export interface CanvasSaveState {
  pending: number
  error: string | null
}

/** Keeps optimistic board edits recoverable and prevents exports racing saves. */
export function createCanvasSaveQueue(onChange: (state: CanvasSaveState) => void) {
  let queue = Promise.resolve()
  let pending = 0
  const versions = new Map<string, number>()
  const failed = new Map<string, { job: SaveJob; message: string }>()
  const preparations = new Set<Promise<unknown>>()
  const publish = (): void => onChange({ pending, error: failed.values().next().value?.message ?? null })
  const enqueue = (keysInput: readonly string[], save: SaveJob['save']): Promise<void> => {
    const keys = [...new Set(keysInput)]
    if (keys.length === 0) return Promise.resolve()
    const job: SaveJob = { keys, save, versions: new Map() }
    for (const key of keys) {
      const version = (versions.get(key) ?? 0) + 1
      versions.set(key, version)
      job.versions.set(key, version)
    }
    pending++
    publish()
    const result = queue.then(async () => {
      try {
        await save(keys)
        for (const key of keys) {
          if (versions.get(key) === job.versions.get(key)) failed.delete(key)
        }
      } catch (cause) {
        const message = cause instanceof Error ? cause.message : '화이트보드 내용을 저장하지 못했어요.'
        for (const key of keys) {
          if (versions.get(key) === job.versions.get(key)) failed.set(key, { job, message })
        }
      } finally {
        pending--
        publish()
      }
    })
    queue = result
    return result
  }
  const prepare = <T>(work: () => Promise<T>): Promise<T> => {
    pending++; publish()
    const result = Promise.resolve().then(work).finally(() => {
      preparations.delete(result); pending--; publish()
    })
    preparations.add(result)
    return result
  }
  const flush = async (): Promise<void> => {
    let current: Promise<void>
    do {
      await Promise.all([...preparations])
      current = queue; await current
    } while (current !== queue || preparations.size > 0)
    const error = failed.values().next().value?.message
    if (error !== undefined) throw new Error(error)
  }
  const retry = async (): Promise<void> => {
    const jobs = new Map<SaveJob, string[]>()
    for (const [key, failure] of failed) {
      if (versions.get(key) !== failure.job.versions.get(key)) continue
      const keys = jobs.get(failure.job) ?? []
      keys.push(key)
      jobs.set(failure.job, keys)
    }
    for (const [job, keys] of jobs) void enqueue(keys, job.save)
    await flush()
  }
  return { enqueue, prepare, flush, retry }
}
