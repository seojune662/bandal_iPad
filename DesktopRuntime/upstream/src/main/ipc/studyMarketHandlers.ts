import type { StudyMarketIpcContract } from '../../shared/ipc/studyMarketContract'
import type { createStudyMarketClient } from '../features/studyMarket/client'
import type { createStudyMarketBundles } from '../features/studyMarket/bundles'
import { ValidationError } from '../db/errors'

type Handler = <K extends keyof StudyMarketIpcContract>(channel: K, fn: (input: StudyMarketIpcContract[K]['req']) => StudyMarketIpcContract[K]['res'] | Promise<StudyMarketIpcContract[K]['res']>) => void
interface Deps {
  client: ReturnType<typeof createStudyMarketClient>
  bundles: ReturnType<typeof createStudyMarketBundles>
  createCourse(name: string): { id: string }
  changed(courseId: string): void
  openExternal(url: string): Promise<void>
  pickPreviewImage(): Promise<{ dataUrl: string } | null>
}

export function registerStudyMarketHandlers(handle: Handler, deps: Deps): void {
  const uploading = new Map<string, Promise<unknown>>()
  const importing = new Set<string>()
  handle('studyMarket:request', req => deps.client.dispatch(req))
  handle('studyMarket:prepare', req => deps.bundles.prepare(req))
  handle('studyMarket:previewSource', req => deps.bundles.previewSource(req))
  handle('studyMarket:preview', req => deps.bundles.preview(req))
  handle('studyMarket:pickPreviewImage', () => deps.pickPreviewImage())
  handle('studyMarket:discardPreview', req => deps.bundles.discardPreview(req.bundleId, req.fileId))
  handle('studyMarket:discardBundle', req => deps.bundles.discardBundle(req.bundleId))
  handle('studyMarket:upload', async req => {
    if (uploading.has(req.versionId)) throw new ValidationError('이미 자료를 올리고 있어요. 잠시 기다려 주세요.')
    const task = (async () => {
      const files = await deps.bundles.getUploadFiles(req.bundleId)
      const selected = new Set(req.fileIds)
      if (!selected.size || selected.size !== req.fileIds.length || [...selected].some(id => !files.some(file => file.id === id))) throw new ValidationError('판매할 자료를 다시 확인해 주세요.')
      for (const file of files) if (selected.has(file.id)) await deps.client.upload(req.versionId, file)
      if (req.publish !== false) return deps.client.request('publish', { versionId: req.versionId })
      const dashboard = await deps.client.request('dashboard', {})
      const draft = dashboard.listings.find(listing => listing.versionId === req.versionId)
      if (!draft) throw new ValidationError('저장한 초안을 다시 불러와 주세요.')
      return draft
    })()
    uploading.set(req.versionId, task)
    try { return await task } finally { uploading.delete(req.versionId) }
  })
  handle('studyMarket:openCheckout', async req => {
    await deps.openExternal(await deps.client.checkout(req.orderId))
    return { ok: true as const }
  })
  handle('studyMarket:import', async req => {
    if (importing.has(req.orderId)) throw new ValidationError('이 자료를 이미 받고 있어요.')
    importing.add(req.orderId)
    try {
      const download = await deps.client.request('download', { orderId: req.orderId, acceptSupply: req.acceptSupply })
      // The backend cannot turn a purchase into an arbitrary main-process fetch.
      const files = download.files.map(file => ({ ...file, url: deps.client.trustedStorageUrl(file.url) }))
      const courseId = req.courseId ?? deps.createCourse(download.courseName).id
      try {
        let renewedAt = 0
        let renewedFiles = files
        const result = await deps.bundles.importDownload({ courseId, title: download.title, files, refreshUrl: async file => {
          if (Date.now() - renewedAt > 30_000) {
            const renewed = await deps.client.request('download', { orderId: req.orderId, acceptSupply: req.acceptSupply })
            if (renewed.orderId !== download.orderId || renewed.files.length !== files.length) throw new ValidationError('구매한 자료 정보가 달라졌어요. 다시 확인해 주세요.')
            renewedFiles = renewed.files.map(candidate => {
              const original = files.find(entry => entry.id === candidate.id)
              if (!original || candidate.path !== original.path || candidate.bytes !== original.bytes || candidate.sha256 !== original.sha256 || candidate.mime !== original.mime || candidate.preview !== original.preview) throw new ValidationError('구매한 자료 정보가 달라졌어요. 다시 확인해 주세요.')
              return { ...candidate, url: deps.client.trustedStorageUrl(candidate.url) }
            })
            renewedAt = Date.now()
          }
          const renewed = renewedFiles.find(entry => entry.id === file.id)
          if (!renewed) throw new ValidationError('구매한 자료를 다시 확인해 주세요.')
          return renewed.url
        } })
        deps.changed(courseId)
        // A receipt acknowledgement failure must not present a successful local import as failed.
        await deps.client.request('downloadComplete', { orderId: req.orderId, success: true }).catch(() => undefined)
        return { courseId, relPath: result.relPath }
      } catch (error) {
        await deps.client.request('downloadComplete', { orderId: req.orderId, success: false, reason: '자료를 과목에 저장하지 못했습니다.' }).catch(() => undefined)
        throw error
      }
    } finally { importing.delete(req.orderId) }
  })
}
