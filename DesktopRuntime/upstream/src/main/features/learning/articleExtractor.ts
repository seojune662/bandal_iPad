import { createHash, randomUUID } from 'node:crypto'
import { session, WebContentsView } from 'electron'
import type { WebContents } from 'electron'
import readabilitySource from '@mozilla/readability/Readability.js?raw'
import type { LearningArticleInput, LearningParagraph } from '../../../shared/types/learning'
import { createPinnedArticleProxy, validatePublicArticleUrl } from './articleNetwork'
export { isPublicArticleAddress, validatePublicArticleUrl } from './articleNetwork'

const EXTRACTION_WORLD = 1001
const DEFAULT_TIMEOUT_MS = 20_000
const MAX_ARTICLE_CHARS = 100_000
const MAX_PAGE_ELEMENTS = 30_000

export interface RawLearningArticle {
  title: string
  paragraphs: string[]
  byline?: string | null
  publishedAt?: string | null
  siteName?: string | null
  language?: string
  canonicalUrl?: string
  blocked?: boolean
}

/** The script returns text only and never changes the original page DOM. */
export const ARTICLE_EXTRACTION_SOURCE = `(() => {
  ${readabilitySource}
  const page = document.cloneNode(true);
  const blocker = Array.from(page.querySelectorAll('[class*="paywall"], [id*="paywall"], [class*="subscription-wall"], [id*="subscription-wall"]'))
    .some(el => /(?:subscribe|sign in|log in).{0,60}(?:to (?:read|continue)|read (?:the|this) (?:full|article)|unlock)|subscription required|subscribers? only|premium content/i.test(el.textContent || ''));
  const article = new Readability(page, { maxElemsToParse: ${MAX_PAGE_ELEMENTS}, serializer: el => el }).parse();
  if (!article) return null;
  const root = article.content;
  const nodes = Array.from(root.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,blockquote,pre'));
  const selected = new Set(nodes);
  const paragraphs = nodes.filter(node => {
      for (let parent = node.parentElement; parent && parent !== root; parent = parent.parentElement) if (selected.has(parent)) return false;
      return true;
    })
    .map(node => (node.textContent || '').replace(/\\s+/g, ' ').trim()).filter(Boolean);
  if (!paragraphs.length) paragraphs.push((article.textContent || '').replace(/\\s+/g, ' ').trim());
  return { title: article.title || document.title || '', paragraphs, byline: article.byline,
    publishedAt: article.publishedTime, siteName: article.siteName,
    language: article.lang || document.documentElement.lang || '',
    canonicalUrl: document.querySelector('link[rel="canonical"]')?.href || location.href,
    blocked: blocker };
})()`

export type ArticlePageContents = Pick<WebContents, 'getURL' | 'isDestroyed' | 'loadURL' | 'executeJavaScriptInIsolatedWorld'>
export interface PublicArticlePage { contents: ArticlePageContents; close(): void | Promise<void> }
export interface ArticleExtractorDeps {
  /** Only the host's validated, course-owned guest registry may resolve this. */
  resolveSourceTab?: (tabId: string) => ArticlePageContents | null
  validateUrl?: (url: string) => Promise<string>
  createPublicPage?: (partition: string, validateUrl: (url: string) => Promise<string>) => PublicArticlePage | Promise<PublicArticlePage>
  now?: () => Date
  timeoutMs?: number
}

function cleanUrl(input: string): string {
  const url = new URL(input)
  url.hash = ''
  for (const key of [...url.searchParams.keys()]) if (/^utm_/i.test(key) || ['fbclid', 'gclid'].includes(key)) url.searchParams.delete(key)
  return url.href
}

const ENGLISH_FUNCTION_WORDS = new Set('the and to of a in that is for it on with as was are this be by from at an or have has but not we they you their which will can its'.split(' '))
function englishText(text: string, declared: string): boolean {
  if (declared && !/^en(?:-|$)/i.test(declared)) return false
  const letters = text.match(/\p{L}/gu) ?? []
  const latin = text.match(/[A-Za-z]/g) ?? []
  if (!letters.length || latin.length / letters.length < 0.85) return false
  const tokens = text.toLowerCase().match(/[a-z]+(?:['’][a-z]+)*/g) ?? []
  const functions = tokens.filter(token => ENGLISH_FUNCTION_WORDS.has(token))
  return tokens.length >= 60 && functions.length / tokens.length >= 0.035 && new Set(functions).size >= 3
}

export function buildArticleSnapshot(
  raw: RawLearningArticle,
  sourceUrl: string,
  access: 'public' | 'source-tab',
  now = new Date()
): LearningArticleInput {
  if (!raw || !Array.isArray(raw.paragraphs) || raw.paragraphs.some(text => typeof text !== 'string')) throw new Error('기사 본문을 추출하지 못했어요.')
  if (raw.blocked) throw new Error('로그인 또는 구독이 필요한 기사예요. 다른 무료 기사를 찾아 주세요.')
  const texts = raw.paragraphs.map(text => text.replace(/\s+/gu, ' ').trim()).filter(Boolean)
  const text = texts.join('\n\n')
  if (text.length > MAX_ARTICLE_CHARS) throw new Error('짧은 기사로 읽기에는 본문이 너무 길어요.')
  if (!englishText(text, raw.language ?? '')) throw new Error('읽을 수 있는 영어 기사 본문을 확인하지 못했어요.')
  const segmenter = new Intl.Segmenter('en', { granularity: 'sentence' })
  const paragraphs: LearningParagraph[] = texts.map((paragraph, index) => ({
    id: `p${index + 1}`,
    text: paragraph,
    sentences: [...segmenter.segment(paragraph)].map((part, sentenceIndex) => {
      const leading = part.segment.length - part.segment.trimStart().length
      const sentence = part.segment.trim()
      return { id: `p${index + 1}-s${sentenceIndex + 1}`, text: sentence, start: part.index + leading, end: part.index + leading + sentence.length }
    }).filter(sentence => sentence.text.length > 0)
  }))
  const wordCount = (text.match(/[A-Za-z]+(?:['’][A-Za-z]+)*/g) ?? []).length
  let canonicalUrl = cleanUrl(sourceUrl)
  if (raw.canonicalUrl) {
    try {
      const canonical = new URL(raw.canonicalUrl, sourceUrl)
      if (canonical.origin === new URL(sourceUrl).origin && !canonical.username && !canonical.password) canonicalUrl = cleanUrl(canonical.href)
    } catch { /* Invalid page metadata cannot replace the verified URL. */ }
  }
  return {
    sourceUrl: cleanUrl(sourceUrl), canonicalUrl,
    title: typeof raw.title === 'string' && raw.title.trim() ? raw.title.trim().slice(0, 500) : new URL(sourceUrl).hostname,
    byline: raw.byline?.trim() || null, publishedAt: raw.publishedAt?.trim() || null,
    siteName: raw.siteName?.trim() || new URL(sourceUrl).hostname, language: 'en',
    wordCount, estimatedMinutes: Math.round(wordCount / 150 * 10) / 10,
    paragraphs, contentHash: createHash('sha256').update(text).digest('hex'), fetchedAt: now.toISOString(), access
  }
}

export interface ArticleWordTarget { id: string; surface: string; forms?: readonly string[] }
export interface ArticleWordMatch { wordId: string; surface: string; paragraphId: string; sentenceId: string; sentence: string; start: number; end: number }

/** Literal whole tokens only. Inflections must be supplied explicitly; no substring stemming. */
export function matchArticleWords(article: Pick<LearningArticleInput, 'paragraphs'>, words: readonly ArticleWordTarget[]): ArticleWordMatch[] {
  const matches: ArticleWordMatch[] = []
  for (const paragraph of article.paragraphs) {
    const tokens = [...paragraph.text.matchAll(/[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*/gu)]
    for (const word of words) {
      const forms = new Set([word.surface, ...(word.forms ?? [])].map(form => form.toLowerCase().normalize('NFC')).filter(Boolean))
      const seen = new Set<string>()
      for (const form of forms) {
        const wanted = form.match(/[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*/gu) ?? []
        if (!wanted.length) continue
        for (let index = 0; index <= tokens.length - wanted.length; index++) {
          const selected = tokens.slice(index, index + wanted.length)
          if (!selected.every((token, offset) => token[0].toLowerCase().normalize('NFC') === wanted[offset])) continue
          const first = selected[0]!, last = selected[selected.length - 1]!
          const start = first.index!, end = last.index! + last[0].length
          // A phrase cannot leap over a sentence break or unrelated punctuation.
          if (wanted.length > 1 && !selected.slice(1).every((token, offset) => /^[\s-]*$/u.test(paragraph.text.slice(selected[offset]!.index! + selected[offset]![0].length, token.index!)))) continue
          const key = `${start}:${end}`
          if (seen.has(key)) continue
          const sentence = paragraph.sentences.find(item => item.start <= start && item.end >= end)
          if (!sentence) continue
          seen.add(key)
          matches.push({ wordId: word.id, surface: paragraph.text.slice(start, end), paragraphId: paragraph.id, sentenceId: sentence.id, sentence: sentence.text, start, end })
        }
      }
    }
  }
  return matches
}

function abortError(): Error { const error = new Error('기사 읽기를 중지했어요.'); error.name = 'AbortError'; return error }
function assertActive(signal: AbortSignal): void { if (signal.aborted) throw abortError() }

function bounded<T>(work: Promise<T>, signal: AbortSignal, timeoutMs: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const onAbort = (): void => { cleanup(); reject(abortError()) }
    const timer = setTimeout(() => { cleanup(); reject(new Error('기사 읽기 시간이 초과됐어요. 다른 기사로 다시 시도해 주세요.')) }, timeoutMs)
    const cleanup = (): void => { clearTimeout(timer); signal.removeEventListener('abort', onAbort) }
    signal.addEventListener('abort', onAbort, { once: true })
    if (signal.aborted) { onAbort(); return }
    work.then(value => { cleanup(); resolve(value) }, error => { cleanup(); reject(error) })
  })
}

async function createPublicPage(partition: string, validateUrl: (url: string) => Promise<string>): Promise<PublicArticlePage> {
  const anonymousSession = session.fromPartition(partition)
  anonymousSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false))
  anonymousSession.setPermissionCheckHandler(() => false)
  let closed = false
  const proxy = await createPinnedArticleProxy()
  // Electron destroys a WebContentsView's contents when the unattached view is
  // collected. Keep the owning view alive until this page is explicitly closed.
  let view: WebContentsView | undefined
  const close = async (): Promise<void> => {
    if (closed) return
    closed = true
    anonymousSession.webRequest.onBeforeRequest(null)
    const ownedView = view
    view = undefined
    const cleanup = await Promise.allSettled([
      Promise.resolve().then(() => {
        if (ownedView && !ownedView.webContents.isDestroyed()) ownedView.webContents.close({ waitForBeforeUnload: false })
      }),
      proxy.close(), anonymousSession.closeAllConnections(),
      anonymousSession.clearStorageData(), anonymousSession.clearCache()
    ])
    const failed = cleanup.find(result => result.status === 'rejected')
    if (failed?.status === 'rejected') throw failed.reason
  }
  try {
    await anonymousSession.setProxy({ mode: 'fixed_servers', proxyRules: proxy.proxyRules, proxyBypassRules: '<-loopback>' })
    const checked = new Map<string, Promise<string>>()
    anonymousSession.webRequest.onBeforeRequest((details, callback) => {
      if (closed) { callback({ cancel: true }); return }
      let url: URL
      try { url = new URL(details.url) } catch { callback({ cancel: true }); return }
      if (url.username || url.password) { callback({ cancel: true }); return }
      if (details.resourceType !== 'mainFrame' && ['data:', 'blob:'].includes(url.protocol)) { callback({}); return }
      const key = url.origin
      let approval = checked.get(key)
      if (!approval) { approval = validateUrl(details.url); checked.set(key, approval) }
      void approval.then(() => callback({ cancel: closed }), () => callback({ cancel: true }))
    })
    anonymousSession.on('will-download', (event) => event.preventDefault())
    view = new WebContentsView({ webPreferences: { session: anonymousSession, nodeIntegration: false,
      contextIsolation: true, sandbox: true, webSecurity: true, allowRunningInsecureContent: false,
      backgroundThrottling: false, autoplayPolicy: 'user-gesture-required' } })
    const contents = view.webContents
    contents.setWindowOpenHandler(() => ({ action: 'deny' }))
    contents.setWebRTCIPHandlingPolicy('disable_non_proxied_udp')
    contents.on('login', (event, _details, _auth, callback) => { event.preventDefault(); callback() })
    contents.setAudioMuted(true)
    return { contents, close }
  } catch (error) {
    await close().catch(() => undefined)
    throw error
  }
}

export function createArticleExtractor(deps: ArticleExtractorDeps = {}) {
  const validateUrl = deps.validateUrl ?? validatePublicArticleUrl
  const createPage = deps.createPublicPage ?? createPublicPage
  const active = new Set<AbortController>()
  const now = deps.now ?? (() => new Date())
  let disposed = false

  async function extract(urlOrTab: string, sourceTab: boolean, externalSignal?: AbortSignal): Promise<LearningArticleInput> {
    if (disposed) throw new Error('기사 읽기가 종료됐어요.')
    const controller = new AbortController()
    const relay = (): void => controller.abort()
    externalSignal?.addEventListener('abort', relay, { once: true })
    if (externalSignal?.aborted) controller.abort()
    active.add(controller)
    let page: PublicArticlePage | undefined
    const work = async (): Promise<LearningArticleInput> => {
      assertActive(controller.signal)
      let contents: ArticlePageContents
      if (sourceTab) {
        const source = deps.resolveSourceTab?.(urlOrTab)
        if (!source || source.isDestroyed()) throw new Error('원문 브라우저 탭을 찾지 못했어요.')
        contents = source
        await validateUrl(contents.getURL())
      } else {
        const url = await validateUrl(urlOrTab)
        assertActive(controller.signal)
        const candidate = await createPage(`bandal-learning-extract-${randomUUID()}`, validateUrl)
        if (controller.signal.aborted) { await candidate.close(); throw abortError() }
        page = candidate
        contents = page.contents
        await contents.loadURL(url)
      }
      assertActive(controller.signal)
      if (contents.isDestroyed()) throw new Error('기사 페이지가 닫혔어요.')
      const originalUrl = contents.getURL()
      const before = await validateUrl(originalUrl)
      const raw: unknown = await contents.executeJavaScriptInIsolatedWorld(EXTRACTION_WORLD, [{ code: ARTICLE_EXTRACTION_SOURCE }])
      assertActive(controller.signal)
      if (contents.isDestroyed() || contents.getURL() !== originalUrl) throw new Error('기사를 읽는 동안 원문 주소가 바뀌었어요. 다시 시도해 주세요.')
      if (!raw || typeof raw !== 'object') throw new Error('기사 본문을 추출하지 못했어요.')
      return buildArticleSnapshot(raw as RawLearningArticle, before, sourceTab ? 'source-tab' : 'public', now())
    }
    try { return await bounded(work(), controller.signal, deps.timeoutMs ?? DEFAULT_TIMEOUT_MS) }
    finally {
      controller.abort()
      active.delete(controller)
      externalSignal?.removeEventListener('abort', relay)
      await page?.close()
    }
  }
  return {
    extractUrl: (url: string, signal?: AbortSignal) => extract(url, false, signal),
    extractSourceTab: (tabId: string, signal?: AbortSignal) => extract(tabId, true, signal),
    dispose() { disposed = true; for (const controller of active) controller.abort(); active.clear() }
  }
}
