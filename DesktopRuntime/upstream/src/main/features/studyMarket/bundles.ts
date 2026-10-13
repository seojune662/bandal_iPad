import { createHash, randomUUID } from 'node:crypto'
import { constants, createReadStream } from 'node:fs'
import { lstat, mkdir, mkdtemp, open, readFile, readdir, realpath, rename, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { basename, dirname, extname, join, posix } from 'node:path'
import { PDFDocument } from 'pdf-lib'
import {
  STUDY_MARKET_EXTENSIONS, STUDY_MARKET_LIMITS,
  type StudyMarketFile, type StudyMarketPreparedBundle, type StudyMarketPreview
} from '../../../shared/types/studyMarket'
import type { Annotation } from '../../../shared/types/annotation'
import { ValidationError } from '../../db/errors'
import { createMaterialLink } from '../link/materialLink'
import { scanMaterialTree } from '../materials/scanMaterialTree'
import { markdownImageDependencies, rewriteMarketMarkdown } from './markdown'

const MAX_PREVIEW_BYTES = 4 * 1024 * 1024
const MIME: Record<string, string> = {
  pdf: 'application/pdf', md: 'text/markdown', txt: 'text/plain', png: 'image/png',
  jpg: 'image/jpeg', jpeg: 'image/jpeg', webp: 'image/webp',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
}

export interface StudyMarketBundlesDeps {
  getCourseFolder(courseId: string): string
  exportAnnotated(input: { courseId: string; relPath: string }, savePath: string): Promise<void>
  listAnnotations(courseId: string, relPath: string): Annotation[]
  tempRoot?: string
  fetch?: typeof fetch
  /** Chromium/pdf.js owns rasterization; main re-encodes bounded PNG bytes. */
  sanitizePreview?: (bytes: Buffer) => Promise<Buffer> | Buffer
}

export interface StudyMarketPreviewSource {
  mime: string
  /** PDF bytes contain one selected page, irrespective of its original page number. */
  base64?: string
  text?: string
}

export type StudyMarketUploadFile = StudyMarketFile & { absolutePath: string }
export interface StudyMarketBundleDownload {
  courseId: string
  title: string
  files: Array<StudyMarketFile & { url: string }>
  signal?: AbortSignal
  /** Recheck entitlement and renew an expired grant, preserving this manifest. */
  refreshUrl?: (file: StudyMarketFile) => Promise<string>
}
interface Prepared { folder: string; bundle: StudyMarketPreparedBundle }

function key(path: string): string { return path.normalize('NFC').toLowerCase() }
function extension(path: string): string { return extname(path).slice(1).toLowerCase() }
function mime(path: string): string { return MIME[extension(path)] ?? 'application/octet-stream' }
function fail(message: string): never { throw new ValidationError(message) }

/** Keep the package portable across macOS and Windows, with no path rewriting. */
export function validateMarketPath(value: unknown): string {
  if (typeof value !== 'string' || !value || value.length > 400 || /[\\\x00-\x1f:*?"<>|]/.test(value) || value.startsWith('/')) fail('자료 경로가 올바르지 않아요.')
  const parts = value.split('/')
  if (parts.length > 12 || parts.some(part => !part || part.startsWith('.') || /[. ]$/.test(part) || part.length > 120 || /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part))) fail('다른 컴퓨터에서 사용할 수 없는 자료 경로예요.')
  return value
}

function validateFilePath(path: string): void {
  validateMarketPath(path)
  if (!(STUDY_MARKET_EXTENSIONS as readonly string[]).includes(extension(path))) fail(`지원하지 않는 자료 형식이에요: ${basename(path)}`)
}

function validateManifest(files: StudyMarketFile[]): void {
  if (files.length === 0 || files.length > STUDY_MARKET_LIMITS.files + STUDY_MARKET_LIMITS.previews) fail('판매 자료는 1~100개까지 담을 수 있어요.')
  const paths = new Set<string>(); const ids = new Set<string>(); let bytes = 0; let originals = 0; let previews = 0
  for (const file of files) {
    validateFilePath(file.path)
    if (typeof file.id !== 'string' || !file.id || ids.has(file.id)) fail('중복된 자료 ID가 있어요.')
    ids.add(file.id)
    const pathKey = key(file.path)
    if (paths.has(pathKey)) fail('이름이 겹치는 자료가 있어요. 대소문자와 한글 표기를 확인해 주세요.')
    for (const existing of paths) if (existing.startsWith(`${pathKey}/`) || pathKey.startsWith(`${existing}/`)) fail('파일과 폴더 이름이 겹쳐요.')
    paths.add(pathKey)
    if (!Number.isSafeInteger(file.bytes) || file.bytes < 0 || file.bytes > STUDY_MARKET_LIMITS.fileBytes || !/^[0-9a-f]{64}$/.test(file.sha256)) fail('자료 크기나 검증 정보가 올바르지 않아요.')
    if (file.mime !== mime(file.path)) fail('자료 형식과 파일 이름이 일치하지 않아요.')
    if (file.preview) { previews += 1; if (file.bytes > MAX_PREVIEW_BYTES || file.mime !== 'image/png') fail('미리보기는 4MB 이하 PNG만 사용할 수 있어요.') }
    else originals += 1
    bytes += file.bytes
  }
  if (originals === 0 || originals > STUDY_MARKET_LIMITS.files || previews > STUDY_MARKET_LIMITS.previews || bytes > STUDY_MARKET_LIMITS.bundleBytes) fail('자료는 100개, 총 200MB까지 담을 수 있어요.')
}

/** Reject symlinks in every segment, including ones that still point inside the course. */
async function safeSource(root: string, relPath: string): Promise<string> {
  validateMarketPath(relPath)
  let cursor = await realpath(root)
  for (const part of relPath.split('/')) {
    cursor = join(cursor, part)
    const info = await lstat(cursor)
    if (info.isSymbolicLink()) fail('바로가기나 심볼릭 링크는 판매할 수 없어요.')
  }
  if (!(await lstat(cursor)).isFile()) fail('파일만 판매 자료로 선택할 수 있어요.')
  return cursor
}

async function describeFile(path: string, relPath: string, id: string = randomUUID(), preview = false): Promise<StudyMarketFile> {
  const hash = createHash('sha256'); let bytes = 0
  for await (const chunk of createReadStream(path)) {
    bytes += chunk.length
    if (bytes > STUDY_MARKET_LIMITS.fileBytes) fail('자료 하나는 50MB까지 담을 수 있어요.')
    hash.update(chunk)
  }
  return { id, path: relPath, bytes, sha256: hash.digest('hex'), mime: mime(relPath), ...(preview ? { preview: true } : {}) }
}

async function copySnapshot(source: string, destination: string): Promise<void> {
  const input = await open(source, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  try {
    const before = await input.stat()
    if (!before.isFile() || before.size > STUDY_MARKET_LIMITS.fileBytes) fail('자료 하나는 50MB 이하의 일반 파일이어야 해요.')
    await mkdir(dirname(destination), { recursive: true })
    const output = await open(destination, 'wx', 0o600)
    try {
      let copied = 0
      for await (const chunk of input.createReadStream({ autoClose: false })) {
        copied += chunk.length
        if (copied > STUDY_MARKET_LIMITS.fileBytes) fail('자료 하나는 50MB까지 담을 수 있어요.')
        await output.writeFile(chunk)
      }
      const after = await input.stat()
      if (before.size !== after.size || before.mtimeMs !== after.mtimeMs || copied !== before.size) fail('준비하는 동안 자료가 변경됐어요. 다시 시도해 주세요.')
    } finally { await output.close() }
  } finally { await input.close() }
}

function escapeMarkdown(value: string): string { return value.replace(/([\\`*_[\]<>])/g, '\\$1') }
function annotationNotes(path: string, annotations: Annotation[]): string | null {
  const comments = annotations.filter(annotation => annotation.comment?.trim()).sort((a, b) => a.page - b.page)
  if (!comments.length) return null
  return `# ${escapeMarkdown(basename(path))} 메모\n\n${comments.map(annotation => {
    const link = createMaterialLink({ relPath: path, page: annotation.page })
    const quote = annotation.anchor.quote.split('\n').map(line => `> ${escapeMarkdown(line)}`).join('\n')
    return `## [${annotation.page}쪽](${link})\n\n${quote}\n\n${escapeMarkdown(annotation.comment!.trim())}\n`
  }).join('\n')}`
}

function copyBundle(bundle: StudyMarketPreparedBundle): StudyMarketPreparedBundle {
  return { ...bundle, files: bundle.files.map(file => ({ ...file })), warnings: [...bundle.warnings] }
}

function validatePreviewPng(bytes: Buffer): void {
  if (bytes.length > MAX_PREVIEW_BYTES) fail('미리보기 이미지가 너무 커요.')
  // Decode only bounded PNG input: no SVG, HTML, remote resources or original PDF.
  if (bytes.length < 24 || !bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) fail('미리보기는 PNG 이미지여야 해요.')
  const width = bytes.readUInt32BE(16); const height = bytes.readUInt32BE(20)
  if (!width || !height || width > 2048 || height > 2048) fail('미리보기 이미지는 가로·세로 2048픽셀까지 사용할 수 있어요.')
}

async function canRenewDownload(response: Response): Promise<boolean> {
  if (response.status === 403) return true
  if (![400, 401].includes(response.status) || !response.body) return false
  // Supabase returns InvalidJWT/ExpiredToken as 400 or 401 depending on version.
  // Consume only a bounded error body; unrelated client errors are not retried.
  const reader = response.body.getReader(); const parts: Buffer[] = []; let bytes = 0
  try {
    while (true) {
      const chunk = await reader.read(); if (chunk.done) break
      bytes += chunk.value.byteLength
      if (bytes > 4096) return false
      parts.push(Buffer.from(chunk.value))
    }
    const value: unknown = JSON.parse(Buffer.concat(parts).toString('utf8'))
    if (!value || typeof value !== 'object' || Array.isArray(value)) return false
    const error = value as Record<string, unknown>
    return [error.code, error.error].some(code => code === 'InvalidJWT' || code === 'ExpiredToken') ||
      [error.message, error.error].some(message => typeof message === 'string' && /^jwt expired$/i.test(message.trim()))
  } catch { return false }
  finally { await reader.cancel().catch(() => undefined); reader.releaseLock() }
}

export function createStudyMarketBundles(deps: StudyMarketBundlesDeps) {
  const prepared = new Map<string, Prepared>()
  let preparing = 0
  let rootPromise: Promise<string> | undefined
  const temporaryRoot = (): Promise<string> => rootPromise ??= (async () => {
    const root = deps.tempRoot ?? tmpdir()
    await mkdir(root, { recursive: true })
    return mkdtemp(join(root, 'bandal-study-market-'))
  })()
  const requireBundle = (id: string): Prepared => {
    const item = prepared.get(id)
    if (!item) fail('준비한 자료가 없어요. 자료를 다시 선택해 주세요.')
    return item
  }
  const requireFile = (bundleId: string, fileId: string): { item: Prepared; file: StudyMarketFile } => {
    const item = requireBundle(bundleId); const file = item.bundle.files.find(candidate => candidate.id === fileId && !candidate.preview)
    if (!file) fail('미리볼 자료를 찾지 못했어요.')
    return { item, file }
  }

  async function prepare(input: { courseId: string; relPaths: string[] }): Promise<StudyMarketPreparedBundle> {
    if (prepared.size + preparing >= 4) fail('열려 있는 판매 준비를 마친 뒤 다시 시도해 주세요.')
    preparing += 1
    try { return await prepareSnapshot(input) } finally { preparing -= 1 }
  }

  async function prepareSnapshot(input: { courseId: string; relPaths: string[] }): Promise<StudyMarketPreparedBundle> {
    if (!input.courseId || !Array.isArray(input.relPaths) || !input.relPaths.length || input.relPaths.length > STUDY_MARKET_LIMITS.files) fail('판매할 자료를 1~100개 선택해 주세요.')
    const folder = await realpath(deps.getCourseFolder(input.courseId))
    const tree = await scanMaterialTree(folder, { maxDepth: 12, maxEntries: 20_000 })
    if (tree.truncation.size) fail('과목 자료가 너무 많거나 폴더가 너무 깊어요. 판매할 자료를 별도 과목으로 옮겨 주세요.')
    const coursePaths = tree.files.map(file => file.relPath)
    const selected = new Set<string>()
    for (const path of input.relPaths) { validateFilePath(path); selected.add(path) }
    const id = randomUUID(); const snapshot = join(await temporaryRoot(), id)
    await mkdir(snapshot, { mode: 0o700 })
    const warnings: string[] = []; const files: StudyMarketFile[] = []; const notes = new Map<string, string>()
    try {
      let snapshotBytes = 0
      for (const path of selected) {
        if (selected.size > STUDY_MARKET_LIMITS.files) fail('첨부 이미지를 포함해 자료는 100개까지 담을 수 있어요.')
        const source = await safeSource(folder, path)
        const destination = join(snapshot, path)
        await copySnapshot(source, destination)
        if (extension(path) === 'pdf') {
          const originalStat = await stat(source)
          await deps.exportAnnotated({ courseId: input.courseId, relPath: path }, destination)
          const after = await stat(await safeSource(folder, path))
          if (after.size !== originalStat.size || after.mtimeMs !== originalStat.mtimeMs) fail('준비하는 동안 PDF가 변경됐어요. 다시 시도해 주세요.')
          const comments = annotationNotes(path, deps.listAnnotations(input.courseId, path))
          if (comments) {
            let number = 1; let commentsPath: string
            do { commentsPath = `${path.slice(0, -4)}-메모${number === 1 ? '' : ` (${number})`}.md`; number += 1 } while ([...selected, ...notes.keys()].some(existing => key(existing) === key(commentsPath)))
            notes.set(commentsPath, comments)
            warnings.push(`${basename(path)}의 하이라이트 메모를 ${basename(commentsPath)}에 함께 담았어요.`)
          }
        } else if (extension(path) === 'md') {
          const markdown = await readFile(destination, 'utf8'); notes.set(path, markdown)
          for (const dependency of markdownImageDependencies(markdown, coursePaths)) {
            validateFilePath(dependency)
            if (!/\.(?:png|jpe?g|webp)$/i.test(dependency)) fail('노트의 첨부 이미지 형식을 지원하지 않아요.')
            if (!selected.has(dependency)) { selected.add(dependency); warnings.push(`노트에 사용한 이미지 ${dependency}를 함께 담았어요.`) }
          }
        }
        snapshotBytes += (await describeFile(destination, path)).bytes
        if (snapshotBytes > STUDY_MARKET_LIMITS.bundleBytes) fail('자료 묶음은 총 200MB까지 담을 수 있어요.')
      }
      const includedPaths = [...new Set([...selected, ...notes.keys()])]
      for (const [path, markdown] of notes) {
        validateFilePath(path)
        await mkdir(dirname(join(snapshot, path)), { recursive: true })
        await writeFile(join(snapshot, path), rewriteMarketMarkdown(markdown, { coursePaths, includedPaths }), { mode: 0o600 })
      }
      for (const path of includedPaths) files.push(await describeFile(join(snapshot, path), path))
      validateManifest(files)
      const bundle: StudyMarketPreparedBundle = { id, courseId: input.courseId, files, warnings, totalBytes: files.reduce((sum, file) => sum + file.bytes, 0) }
      prepared.set(id, { folder: snapshot, bundle })
      return copyBundle(bundle)
    } catch (error) { await rm(snapshot, { recursive: true, force: true }); throw error }
  }

  async function getUploadFiles(bundleId: string): Promise<StudyMarketUploadFile[]> {
    const item = requireBundle(bundleId)
    const files: StudyMarketUploadFile[] = []
    for (const file of item.bundle.files) {
      const absolutePath = await safeSource(item.folder, file.path)
      const actual = await describeFile(absolutePath, file.path, file.id, file.preview)
      if (actual.bytes !== file.bytes || actual.sha256 !== file.sha256) fail('준비한 자료가 변경됐어요. 다시 준비해 주세요.')
      files.push({ ...file, absolutePath })
    }
    return files
  }

  async function previewSource(input: { bundleId: string; fileId: string; page?: number; text?: string }): Promise<StudyMarketPreviewSource> {
    const { item, file } = requireFile(input.bundleId, input.fileId)
    const bytes = await readFile(await safeSource(item.folder, file.path))
    if (createHash('sha256').update(bytes).digest('hex') !== file.sha256) fail('준비한 자료가 변경됐어요.')
    if (file.mime === 'application/pdf') {
      const source = await PDFDocument.load(bytes); const page = input.page ?? 1
      if (!Number.isSafeInteger(page) || page < 1 || page > source.getPageCount()) fail('미리볼 페이지 번호가 올바르지 않아요.')
      const excerpt = await PDFDocument.create(); const pages = await excerpt.copyPages(source, [page - 1]); excerpt.addPage(pages[0]!)
      const data = Buffer.from(await excerpt.save())
      if (data.length > STUDY_MARKET_LIMITS.fileBytes) fail('미리볼 페이지가 너무 커요.')
      return { mime: 'application/pdf', base64: data.toString('base64') }
    }
    if (file.mime === 'text/markdown' || file.mime === 'text/plain') {
      const original = bytes.toString('utf8')
      const data = (input.text ?? original.slice(0, 1200)).trim()
      if (!data || data.length > 3000 || !original.includes(data)) fail('미리보기는 자료에 있는 문장 3,000자 이내로 선택해 주세요.')
      return { mime: file.mime, text: data }
    }
    if (file.mime.startsWith('image/')) return { mime: file.mime, base64: bytes.toString('base64') }
    fail('PDF, 노트, 이미지 중에서 미리보기를 선택해 주세요.')
  }

  async function acceptPreview(input: { bundleId: string; fileId: string; dataUrl: string }): Promise<StudyMarketPreview> {
    const { item } = requireFile(input.bundleId, input.fileId)
    if (item.bundle.files.filter(file => file.preview).length >= STUDY_MARKET_LIMITS.previews) fail('미리보기는 3개까지 만들 수 있어요.')
    if (typeof input.dataUrl !== 'string' || input.dataUrl.length > Math.ceil(MAX_PREVIEW_BYTES * 4 / 3) + 32 || !/^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(input.dataUrl)) fail('미리보기 PNG 이미지가 올바르지 않아요.')
    const raw = Buffer.from(input.dataUrl.slice('data:image/png;base64,'.length), 'base64')
    validatePreviewPng(raw)
    if (!deps.sanitizePreview) fail('미리보기 이미지 처리가 준비되지 않았어요.')
    const bytes = await deps.sanitizePreview(raw)
    validatePreviewPng(bytes)
    if (bytes.length > MAX_PREVIEW_BYTES) fail('미리보기 이미지가 너무 커요.')
    const id = randomUUID(); const path = `preview-${id}.png`
    await writeFile(join(item.folder, path), bytes, { flag: 'wx', mode: 0o600 })
    const file = await describeFile(join(item.folder, path), path, id, true)
    try { validateManifest([...item.bundle.files, file]) } catch (error) { await rm(join(item.folder, path), { force: true }); throw error }
    item.bundle.files.push(file); item.bundle.totalBytes += file.bytes
    return { file: { ...file }, dataUrl: `data:image/png;base64,${bytes.toString('base64')}` }
  }

  async function preview(input: { bundleId: string; fileId: string; page?: number; text?: string; dataUrl?: string }): Promise<StudyMarketPreview> {
    if (!input.dataUrl) fail('공개할 미리보기 이미지를 먼저 만들어 주세요.')
    return acceptPreview({ bundleId: input.bundleId, fileId: input.fileId, dataUrl: input.dataUrl })
  }

  async function importDownload(input: StudyMarketBundleDownload): Promise<{ relPath: string; files: string[] }> {
    validateManifest(input.files)
    const originals = input.files.filter(file => !file.preview).map(file => ({ ...file }))
    const root = await realpath(deps.getCourseFolder(input.courseId))
    const safeTitle = Array.from(input.title.normalize('NFC').trim().replace(/[\\/\x00-\x1f:*?"<>|]/g, ' ').replace(/\s+/g, ' ').replace(/^[. ]+/g, '')).slice(0, 60).join('').replace(/[. ]+$/g, '') || '구매 자료'
    const title = /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(safeTitle) ? `구매 ${safeTitle}` : safeTitle
    const purchases = join(root, '구매 자료')
    await mkdir(purchases, { recursive: true })
    if ((await lstat(purchases)).isSymbolicLink() || await realpath(purchases) !== purchases) fail('구매 자료 폴더가 올바르지 않아요.')
    const stage = await mkdtemp(join(purchases, '.bandal-market-'))
    try {
      for (const file of originals) {
        input.signal?.throwIfAborted()
        const fetchFile = async (rawUrl: string): Promise<Response> => {
          input.signal?.throwIfAborted()
          const url = new URL(rawUrl)
          if (url.protocol !== 'https:' || url.username || url.password) fail('자료 다운로드 주소가 올바르지 않아요.')
          return (deps.fetch ?? fetch)(url.href, { redirect: 'error', signal: input.signal ? AbortSignal.any([input.signal, AbortSignal.timeout(120_000)]) : AbortSignal.timeout(120_000) })
        }
        let response = await fetchFile(file.url)
        if (input.refreshUrl && await canRenewDownload(response)) {
          await response.body?.cancel().catch(() => undefined)
          const { url: _expiredUrl, ...manifest } = file
          // Exactly one renewal per file. Earlier files remain in the same private stage.
          response = await fetchFile(await input.refreshUrl(manifest))
        }
        if (!response.ok || !response.body) fail('자료를 내려받지 못했어요. 구매 내역에서 다시 시도해 주세요.')
        const declared = response.headers.get('content-length')
        if (declared !== null && Number(declared) !== file.bytes) fail('다운로드한 자료의 크기가 달라요.')
        const destination = join(stage, file.path)
        await mkdir(dirname(destination), { recursive: true })
        const output = await open(destination, 'wx', 0o600); const hash = createHash('sha256'); let bytes = 0
        const reader = response.body.getReader()
        try {
          while (true) {
            input.signal?.throwIfAborted()
            const chunk = await reader.read(); if (chunk.done) break
            bytes += chunk.value.byteLength
            if (bytes > file.bytes || bytes > STUDY_MARKET_LIMITS.fileBytes) fail('다운로드한 자료가 허용된 크기를 넘었어요.')
            hash.update(chunk.value); await output.writeFile(chunk.value)
          }
          if (bytes !== file.bytes || hash.digest('hex') !== file.sha256) fail('다운로드한 자료의 무결성을 확인하지 못했어요.')
        } finally { await reader.cancel().catch(() => undefined); await output.close() }
      }
      const paths = originals.map(file => file.path)
      // A private exclusive lock serializes equal names across concurrent imports.
      // Staging and final paths are on the same volume, so one rename publishes all files.
      let number = 1; let name = title; let reservation: Awaited<ReturnType<typeof open>> | undefined; let reservationPath = ''
      while (!reservation) {
        const occupied = new Set((await readdir(purchases)).map(key))
        if (!occupied.has(key(name))) {
          reservationPath = join(purchases, `.bandal-market-reserve-${createHash('sha256').update(key(name)).digest('hex')}`)
          try { reservation = await open(reservationPath, 'wx', 0o600) } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error }
        }
        if (!reservation) { number += 1; name = `${title} (${number})` }
      }
      const destination = join(purchases, name)
      try {
        const contentRelPath = posix.join('구매 자료', name)
        for (const file of originals) if (extension(file.path) === 'md') {
          const path = join(stage, file.path)
          const markdown = await readFile(path, 'utf8')
          await writeFile(path, rewriteMarketMarkdown(markdown, { coursePaths: paths, includedPaths: paths, prefix: contentRelPath }))
        }
        input.signal?.throwIfAborted()
        if (await realpath(deps.getCourseFolder(input.courseId)) !== root) fail('과목 폴더가 바뀌었어요. 다시 가져와 주세요.')
        if ((await lstat(purchases)).isSymbolicLink() || await realpath(purchases) !== purchases) fail('자료 폴더가 바뀌었어요.')
        const existing = await lstat(destination).catch((error: NodeJS.ErrnoException) => { if (error.code === 'ENOENT') return null; throw error })
        if (existing !== null) fail('같은 이름의 폴더가 생겼어요. 다시 가져와 주세요.')
        await rename(stage, destination)
        return { relPath: contentRelPath, files: paths.map(path => posix.join(contentRelPath, path)) }
      } finally { await reservation.close(); await rm(reservationPath, { force: true }) }
    } finally { await rm(stage, { recursive: true, force: true }) }
  }

  async function discardBundle(bundleId: string): Promise<{ ok: true }> {
    const item = prepared.get(bundleId); prepared.delete(bundleId)
    if (item) await rm(item.folder, { recursive: true, force: true })
    return { ok: true }
  }
  async function discardPreview(bundleId: string, fileId: string): Promise<{ ok: true }> {
    const item = requireBundle(bundleId)
    const file = item.bundle.files.find(candidate => candidate.id === fileId && candidate.preview)
    if (!file) fail('삭제할 미리보기를 찾지 못했어요.')
    await rm(join(item.folder, file.path), { force: true })
    item.bundle.files = item.bundle.files.filter(candidate => candidate.id !== fileId)
    item.bundle.totalBytes = item.bundle.files.reduce((sum, candidate) => sum + candidate.bytes, 0)
    return { ok: true }
  }
  async function dispose(): Promise<void> {
    prepared.clear()
    if (rootPromise) await rm(await rootPromise, { recursive: true, force: true })
    rootPromise = undefined
  }
  return { prepare, getUploadFiles, previewSource, acceptPreview, preview, importDownload, discardBundle, discardPreview, dispose }
}
