import type { SupabaseClient } from '@supabase/supabase-js'
import { open } from 'node:fs/promises'
import { readSupabaseConfig, type SupabaseConfig } from '../account/config'
import { ValidationError } from '../../db/errors'
import { STUDY_MARKET_ACTIONS, STUDY_MARKET_LIMITS, type StudyMarketAction, type StudyMarketApi, type StudyMarketDashboard, type StudyMarketFile, type StudyMarketRequest } from '../../../shared/types/studyMarket'

const emptyDashboard = (configured: boolean, signedIn: boolean): StudyMarketDashboard => ({
  configured, signedIn, tradingEnabled: false, operator: false, seller: { status: 'unregistered', displayName: '' },
  listings: [], purchases: [], payouts: [], salesCount: 0, pendingAmount: 0, paidAmount: 0,
  notice: '마켓플레이스를 준비하고 있어요. 실제 거래가 열리면 이곳에서 이용할 수 있어요.'
})

export function createStudyMarketClient(deps: { getClient(): SupabaseClient | null; fetch: typeof fetch; config?: () => SupabaseConfig | null }) {
  const config = deps.config ?? readSupabaseConfig
  const uploads = new Map<string, string>()
  async function session(): Promise<string | null> {
    const result = await deps.getClient()?.auth.getSession()
    if (result?.error) throw new ValidationError('로그인을 다시 확인해 주세요.')
    return result?.data.session?.access_token ?? null
  }
  async function request<K extends StudyMarketAction>(action: K, input: StudyMarketApi[K]['req']): Promise<StudyMarketApi[K]['res']> {
    if (!STUDY_MARKET_ACTIONS.includes(action)) throw new ValidationError('지원하지 않는 마켓 요청입니다.')
    const current = config()
    const access = await session()
    if (!current) {
      if (action === 'dashboard') return emptyDashboard(false, !!access) as StudyMarketApi[K]['res']
      if (action === 'context') return { universities: [], tradingEnabled: false, notice: emptyDashboard(false, false).notice } as StudyMarketApi[K]['res']
      throw new ValidationError('마켓플레이스 연결을 준비하고 있어요.')
    }
    const response = await deps.fetch(`${current.url}/functions/v1/study-market`, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(120_000),
      headers: { 'Content-Type': 'application/json', apikey: current.publishableKey, ...(access ? { Authorization: `Bearer ${access}` } : {}) },
      body: JSON.stringify({ action, input })
    })
    if (response.status === 404 && action === 'dashboard') return emptyDashboard(false, !!access) as StudyMarketApi[K]['res']
    if (response.status === 404 && action === 'context') return { universities: [], tradingEnabled: false, notice: emptyDashboard(false, false).notice } as StudyMarketApi[K]['res']
    const result: unknown = await response.json().catch(() => null)
    if (!response.ok) {
      const error = result && typeof result === 'object' && 'error' in result && typeof result.error === 'string' ? result.error : '마켓 요청을 처리하지 못했어요. 다시 시도해 주세요.'
      throw new ValidationError(error.slice(0, 500))
    }
    return result as StudyMarketApi[K]['res']
  }
  function trustedStorageUrl(raw: string): string {
    const current = config()
    if (!current) throw new ValidationError('마켓 연결 설정이 없습니다.')
    const base = new URL(current.url)
    const target = new URL(raw, base)
    const storageHost = base.hostname.replace(/\.supabase\.co$/, '.storage.supabase.co')
    if (target.username || target.password || target.protocol !== base.protocol ||
      ![base.hostname, storageHost].includes(target.hostname) || target.port !== base.port || !target.pathname.startsWith('/storage/v1/')) throw new ValidationError('자료 저장소 주소가 올바르지 않습니다.')
    return target.href
  }
  async function upload(versionId: string, file: StudyMarketFile & { absolutePath: string }): Promise<void> {
    const grant = await request('uploadGrant', { versionId, fileId: file.id })
    if (grant.alreadyVerified) return
    const endpoint = trustedStorageUrl(grant.resumableUrl)
    const current = config()!
    const headers = { 'Tus-Resumable': '1.0.0', 'x-signature': grant.token, apikey: current.publishableKey }
    const key = `${versionId}:${file.id}`
    const handle = await open(file.absolutePath, 'r')
    try {
      const stat = await handle.stat()
      if (!stat.isFile() || stat.size !== file.bytes || stat.size > STUDY_MARKET_LIMITS.fileBytes) throw new ValidationError('판매 자료 사본이 변경되었어요. 자료를 다시 선택해 주세요.')
      let location = uploads.get(key)
      let offset = 0
      if (location) {
        const head = await deps.fetch(location, { method: 'HEAD', headers, redirect: 'error', signal: AbortSignal.timeout(30_000) })
        if (head.ok) offset = Number(head.headers.get('Upload-Offset'))
        else { uploads.delete(key); location = undefined }
      }
      if (!location) {
        const metadata = { bucketName: grant.bucket, objectName: grant.objectPath, contentType: file.mime }
        const response = await deps.fetch(endpoint, { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(60_000),
          headers: { ...headers, 'Upload-Length': String(file.bytes), 'Upload-Metadata': Object.entries(metadata).map(([name, value]) => `${name} ${Buffer.from(value).toString('base64')}`).join(',') } })
        if (!response.ok || !response.headers.get('Location')) throw new ValidationError('자료 업로드를 시작하지 못했어요. 다시 시도해 주세요.')
        location = trustedStorageUrl(new URL(response.headers.get('Location')!, endpoint).href)
        uploads.set(key, location)
      }
      if (!Number.isSafeInteger(offset) || offset < 0 || offset > file.bytes) throw new ValidationError('업로드 진행 정보가 올바르지 않습니다.')
      let failures = 0
      while (offset < file.bytes) {
        const buffer = Buffer.alloc(Math.min(6 * 1024 * 1024, file.bytes - offset))
        const { bytesRead } = await handle.read(buffer, 0, buffer.length, offset)
        if (bytesRead !== buffer.length) throw new ValidationError('자료 사본을 읽지 못했어요.')
        try {
          const response = await deps.fetch(location, { method: 'PATCH', redirect: 'error', signal: AbortSignal.timeout(90_000),
            headers: { ...headers, 'Content-Type': 'application/offset+octet-stream', 'Upload-Offset': String(offset) }, body: buffer })
          const next = Number(response.headers.get('Upload-Offset'))
          if (!response.ok || next !== offset + bytesRead) throw new Error('Upload interrupted')
          offset = next; failures = 0
        } catch {
          if (++failures > 3) throw new ValidationError('자료 업로드가 중단됐어요. 다시 시도하면 이어서 올립니다.')
          const head = await deps.fetch(location, { method: 'HEAD', headers, redirect: 'error', signal: AbortSignal.timeout(30_000) })
          const next = Number(head.headers.get('Upload-Offset'))
          if (!head.ok || !Number.isSafeInteger(next) || next < offset || next > file.bytes) throw new ValidationError('업로드를 이어갈 수 없어요. 다시 시도해 주세요.')
          offset = next
        }
      }
      await request('finalizeFile', { versionId, fileId: file.id })
      uploads.delete(key)
    } finally { await handle.close() }
  }
  async function checkout(orderId: string): Promise<string> {
    const order = await request('orderStatus', { orderId, refreshCheckout: true })
    if (!order.checkoutUrl || order.status !== 'pending') throw new ValidationError('구매 내역에서 결제 상태를 확인해 주세요.')
    const url = new URL(order.checkoutUrl)
    if (url.origin !== 'https://bandal.io' || url.pathname !== '/checkout' || url.username || url.password) throw new ValidationError('결제 페이지 주소가 올바르지 않습니다.')
    return url.href
  }
  return { request, dispatch: (req: StudyMarketRequest) => request(req.action, req.input), upload, checkout, trustedStorageUrl }
}
