import { watch, type FSWatcher } from 'chokidar'
import type { PluginStore } from './pluginStore'
import { readManifest } from './pluginStore'

export function createPluginDevelopment(deps: {
  store: PluginStore
  unload(id: string): void
  changed(): void
  log(id: string, message: string): void
}) {
  const watchers = new Map<
    string,
    {
      path: string
      watcher: FSWatcher
      timer: NodeJS.Timeout | undefined
      running: boolean
      dirty: boolean
    }
  >()
  async function stop(id: string): Promise<void> {
    const entry = watchers.get(id)
    watchers.delete(id)
    if (entry) {
      clearTimeout(entry.timer)
      await entry.watcher.close()
    }
  }
  return {
    list: () => [...watchers].map(([id, entry]) => ({ id, path: entry.path })),
    async start(path: string): Promise<void> {
      const installed = await deps.store.installFromFolder(path)
      const id = installed.plugin.manifest.id
      await stop(id)
      deps.unload(id)
      deps.changed()
      const watcher = watch(path, {
        ignoreInitial: true,
        awaitWriteFinish: { stabilityThreshold: 250, pollInterval: 50 },
      })
      const entry = {
        path,
        watcher,
        running: false,
        dirty: false,
        timer: undefined as NodeJS.Timeout | undefined,
      }
      watchers.set(id, entry)
      async function refresh(): Promise<void> {
        if (watchers.get(id) !== entry) return
        if (entry.running) {
          entry.dirty = true
          return
        }
        entry.running = true
        try {
          if (readManifest(path).manifest.id !== id)
            throw new Error(
              'Development plugin id changed; reconnect the folder',
            )
          await deps.store.installFromFolder(path)
          deps.unload(id)
          deps.changed()
          deps.log(
            id,
            'Development files updated. Review and approve the changed code before enabling.',
          )
        } catch (error) {
          deps.log(id, error instanceof Error ? error.message : String(error))
        } finally {
          entry.running = false
          if (entry.dirty) {
            entry.dirty = false
            void refresh()
          }
        }
      }
      watcher.on('all', () => {
        clearTimeout(entry.timer)
        entry.timer = setTimeout(() => void refresh(), 200)
      })
      watcher.on('error', (error) => deps.log(id, String(error)))
      try {
        await new Promise<void>((resolve, reject) => {
          const timer = setTimeout(() => {
            cleanup()
            reject(new Error('Development watcher did not become ready'))
          }, 10_000)
          const cleanup = (): void => {
            clearTimeout(timer)
            watcher.off('ready', ready)
            watcher.off('error', failed)
          }
          const ready = (): void => {
            cleanup()
            resolve()
          }
          const failed = (error: unknown): void => {
            cleanup()
            reject(error)
          }
          watcher.once('ready', ready)
          watcher.once('error', failed)
        })
      } catch (error) {
        await stop(id)
        throw error
      }
    },
    stop,
    async dispose(): Promise<void> {
      await Promise.all([...watchers.keys()].map(stop))
    },
  }
}
