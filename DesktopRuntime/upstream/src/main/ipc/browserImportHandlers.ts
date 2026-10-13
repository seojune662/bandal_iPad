import { app, BrowserWindow, dialog } from 'electron'
import { join } from 'node:path'
import type {
  IpcChannel,
  IpcRequest,
  IpcResponse,
} from '../../shared/ipc/contract'
import type {
  BrowserImportFileKind,
  BrowserImportJob,
} from '../../shared/types/browserImport'
import type { FavoritesRepo } from '../features/favorites/favoritesRepo'
import type { Favorite } from '../../shared/types/favorite'
import {
  createBrowserImportService,
  type BrowserImportService,
} from '../features/browser/import'
import {
  browserProfileResources,
  ensureProfileSession,
  requireProfile,
} from '../features/browser/profiles'
import { randomUUID } from 'node:crypto'

type Register = <K extends IpcChannel>(
  channel: K,
  fn: (
    request: IpcRequest<K>,
    event: Electron.IpcMainInvokeEvent,
  ) => Promise<IpcResponse<K>> | IpcResponse<K>,
) => void

export function registerBrowserImportHandlers(
  handle: Register,
  favorites: FavoritesRepo,
): BrowserImportService {
  const extension = process.platform === 'win32' ? '.exe' : ''
  const helperPath = app.isPackaged
    ? join(
        process.resourcesPath,
        'browser-import',
        `bandal-browser-import${extension}`,
      )
    : join(
        app.getAppPath(),
        'resources/native/browser-import',
        process.arch,
        `bandal-browser-import${extension}`,
      )
  // Tests point discovery at synthetic profiles only. This is never an IPC input.
  const testHome = process.env.BANDAL_USER_DATA_DIR
    ? process.env.BANDAL_TEST_IMPORT_HOME
    : undefined
  const bookmarkIndexes = new Map<string, Map<string, Favorite>>()
  const bookmarkIndex = (profileId: string): Map<string, Favorite> => {
    let index = bookmarkIndexes.get(profileId)
    if (!index) {
      index = new Map(
        favorites
          .list(null)
          .flatMap((favorite) =>
            favorite.descriptor.kind === 'browser' &&
            (favorite.descriptor.payload.profileId ?? 'default') === profileId
              ? [[favorite.descriptor.payload.initialUrl, favorite] as const]
              : [],
          ),
      )
      bookmarkIndexes.set(profileId, index)
    }
    return index
  }
  const service = createBrowserImportService({
    helperPath,
    ...(testHome
      ? {
          homeDir: testHome,
          localAppData: join(testHome, 'Local'),
          appData: join(testHome, 'Roaming'),
        }
      : {}),
    sinks: {
      passwords(profileId, entries, conflict) {
        const result = browserProfileResources(
          profileId,
        ).credentials.importMany(entries, { conflict })
        return {
          imported: result.imported,
          kept: result.unchanged + result.conflicts,
          unsupported: result.invalid,
          failed: 0,
        }
      },
      bookmark(profileId, entry, conflict) {
        requireProfile(profileId)
        const index = bookmarkIndex(profileId)
        const existing = index.get(entry.url)
        if (existing) {
          if (conflict === 'replace' && existing.label !== entry.title) {
            favorites.rename({ id: existing.id, label: entry.title })
            index.set(entry.url, { ...existing, label: entry.title })
            return 'imported'
          }
          return 'kept'
        }
        const added = favorites.add({
          courseId: null,
          label: entry.title,
          descriptor: {
            kind: 'browser',
            payload: { tabId: randomUUID(), initialUrl: entry.url, profileId },
          },
        })
        index.set(entry.url, added)
        return 'imported'
      },
      history(profileId, entries, conflict) {
        return browserProfileResources(profileId).history.importMany(
          entries,
          conflict,
        )
      },
      cookies(profileId) {
        const cookies = ensureProfileSession(profileId).cookies
        return {
          get: async () =>
            (await cookies.get({})).flatMap((cookie) =>
              cookie.domain && cookie.path
                ? [
                    {
                      ...cookie,
                      domain: cookie.domain,
                      path: cookie.path,
                      secure: cookie.secure === true,
                      httpOnly: cookie.httpOnly === true,
                    },
                  ]
                : [],
            ),
          set: (cookie) => cookies.set(cookie),
          flushStore: () => cookies.flushStore(),
        }
      },
    },
  })
  service.subscribe((job) => {
    if (job.state !== 'running') bookmarkIndexes.delete(job.targetProfileId)
  })
  // before-quit can be cancelled by a page's beforeunload confirmation.
  app.once('will-quit', () => service.dispose())
  const pickFile = async (
    kind: BrowserImportFileKind,
    event: Electron.IpcMainInvokeEvent,
  ) => {
    const choices = {
      'passwords-csv': { name: '비밀번호 CSV', extensions: ['csv'] },
      'bookmarks-html': { name: '북마크 HTML', extensions: ['html', 'htm'] },
      'safari-zip': { name: 'Safari 내보내기 ZIP', extensions: ['zip'] },
    }
    if (!Object.hasOwn(choices, kind))
      throw new Error('지원하지 않는 파일 형식입니다.')
    const owner = BrowserWindow.fromWebContents(event.sender)
    const options: Electron.OpenDialogOptions = {
      title: choices[kind].name,
      properties: ['openFile'],
      filters: [choices[kind]],
    }
    const picked = owner
      ? await dialog.showOpenDialog(owner, options)
      : await dialog.showOpenDialog(options)
    return picked.canceled || !picked.filePaths[0]
      ? null
      : service.registerFile(picked.filePaths[0], kind)
  }
  handle('browser:importSources', () => service.discover())
  handle('browser:importFile', (request, event) =>
    pickFile(request.kind, event),
  )
  handle('browser:importStart', (request) => {
    requireProfile(request.targetProfileId)
    return service.start(request)
  })
  handle('browser:importJob', (request) => service.get(request.jobId))
  handle('browser:importCancel', (request) => ({
    cancelled: service.cancel(request.jobId),
  }))
  const wait = (id: string): Promise<BrowserImportJob> =>
    new Promise((resolve) => {
      const current = service.get(id)!
      if (current.state !== 'running') {
        resolve(current)
        return
      }
      const unsubscribe = service.subscribe((job) => {
        if (job.id === id && job.state !== 'running') {
          unsubscribe()
          resolve(job)
        }
      })
    })
  // Keep old entry points compatible while routing every importer through one service.
  handle('credentials:importCsv', async (request, event) => {
    const profileId = request.profileId ?? 'default'
    requireProfile(profileId)
    const source = await pickFile('passwords-csv', event)
    if (!source) return { imported: 0, skipped: 0, cancelled: true }
    const job = await wait(
      service.start({
        sourceId: source.id,
        targetProfileId: profileId,
        items: ['passwords'],
        conflict: 'keep',
      }).id,
    )
    const result = job.results.passwords
    if (job.state === 'failed')
      throw new Error('비밀번호를 가져오지 못했습니다.')
    return {
      imported: result.imported,
      skipped: result.kept + result.unsupported + result.failed,
      cancelled: job.state === 'cancelled',
    }
  })
  handle('browser:importBookmarks', async (_request, event) => {
    const source = await pickFile('bookmarks-html', event)
    if (!source) return { imported: 0, skipped: 0, cancelled: true }
    const job = await wait(
      service.start({
        sourceId: source.id,
        targetProfileId: 'default',
        items: ['bookmarks'],
        conflict: 'keep',
      }).id,
    )
    const result = job.results.bookmarks
    if (job.state === 'failed') throw new Error('북마크를 가져오지 못했습니다.')
    return {
      imported: result.imported,
      skipped: result.kept + result.unsupported + result.failed,
      cancelled: job.state === 'cancelled',
    }
  })
  return service
}
