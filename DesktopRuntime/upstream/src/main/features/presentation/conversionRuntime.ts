import { createHash } from 'node:crypto'
import { createWriteStream } from 'node:fs'
import { access, cp, mkdir, mkdtemp, readFile, readdir, rename, rm, stat, utimes, writeFile } from 'node:fs/promises'
import { basename, join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { spawn } from 'node:child_process'
import { Transform, Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import type { ConversionRuntimeState } from '../../../shared/types/presentation'

// Pinned upstream installers retain The Document Foundation's platform signature.
// Updating these hashes is an explicit application release, not a remote-code feed.
export const OFFICE_RUNTIME_VERSION = '26.2.6'
export const OFFICE_PACKAGES: Record<string, { path: string; sha256: string }> = {
  'darwin-arm64': { path: 'mac/aarch64/LibreOffice_26.2.6_MacOS_aarch64.dmg', sha256: '94bb3248df074c225490a8a6d1d9dc87c7d6783dbb7a8e9f0d0c3d94348552af' },
  'darwin-x64': { path: 'mac/x86_64/LibreOffice_26.2.6_MacOS_x86-64.dmg', sha256: '135b8a95b8133396d54bf8e726dbc0066145efa0d785963fc3d4592acbfcfe5b' },
  'win32-x64': { path: 'win/x86_64/LibreOffice_26.2.6_Win_x86-64.msi', sha256: 'f9877032fd908beb9c0ddf06df4af5c2e85f419c42e14876c4cce5aae5fb2660' }
}

/** Use only HTTPS mirrors advertised by the official server; pinned hashes still
 * authenticate every byte. Race a small prefix so a slow regional mirror does
 * not trap a first-time user for the whole several-hundred-MB download. */
async function downloadSource(url: string, signal: AbortSignal): Promise<{ stream: Readable; total: number }> {
  const metadata = await fetch(url, { signal, redirect: 'manual' })
  if (metadata.status === 404) {
    await metadata.body?.cancel()
    if (!url.includes(`/stable/${OFFICE_RUNTIME_VERSION}/`)) throw new Error('고정된 버전의 변환기를 찾지 못했어요. 앱을 업데이트해 주세요.')
    return downloadSource(url.replace(`/stable/${OFFICE_RUNTIME_VERSION}/`, `/old/${OFFICE_RUNTIME_VERSION}.2/`).replace('download.documentfoundation.org', 'downloadarchive.documentfoundation.org'), signal)
  }
  if (metadata.ok && metadata.body) return { stream: Readable.fromWeb(metadata.body as Parameters<typeof Readable.fromWeb>[0]), total: Number(metadata.headers.get('content-length')) || 0 }
  const candidates = Array.from(new Set([
    metadata.headers.get('location') ?? '',
    ...Array.from((metadata.headers.get('link') ?? '').matchAll(/<([^>]+)>;\s*rel=duplicate/g), (match) => match[1]!)
  ])).filter((value) => {
    try { const mirror = new URL(value); return mirror.protocol === 'https:' && !mirror.username && !mirror.password && mirror.pathname.endsWith(new URL(url).pathname.split('/').at(-1)!) }
    catch { return false }
  }).slice(0, 5)
  await metadata.body?.cancel()
  if (!candidates.length) throw new Error('변환기 다운로드 서버에 연결하지 못했어요.')
  const controllers = candidates.map(() => new AbortController())
  let winner = -1
  try {
    const result = await Promise.any(candidates.map(async (candidate, index) => {
      const controller = controllers[index]!
      const timeout = setTimeout(() => controller.abort(), 30_000)
      try {
        const response = await fetch(candidate, { signal: AbortSignal.any([signal, controller.signal]) })
        if (!response.ok || !response.body) throw new Error('다운로드 서버 응답 오류')
        const reader = response.body.getReader(), prefix: Uint8Array[] = []
        let bytes = 0
        while (bytes < 1024 * 1024) {
          const part = await reader.read()
          if (part.done) throw new Error('불완전한 다운로드')
          prefix.push(part.value); bytes += part.value.length
        }
        return { index, response, reader, prefix }
      } catch (error) { controller.abort(); throw error }
      finally { clearTimeout(timeout) }
    }))
    winner = result.index
    return {
      total: Number(result.response.headers.get('content-length')) || 0,
      stream: Readable.from((async function* () {
        try {
          yield* result.prefix
          for (;;) { const part = await result.reader.read(); if (part.done) break; yield part.value }
        } finally { await result.reader.cancel().catch(() => {}) }
      })())
    }
  } catch { throw new Error(signal.aborted ? '변환기 설치를 취소했어요.' : '변환기를 내려받지 못했어요. 네트워크를 확인해 주세요.') }
  finally { controllers.forEach((controller, index) => { if (index !== winner) controller.abort() }) }
}

export function runOfficeCommand(file: string, args: string[], signal?: AbortSignal, env?: NodeJS.ProcessEnv): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, { stdio: 'ignore', windowsHide: true, ...(env ? { env } : {}) })
    const stop = (): void => {
      if (process.platform === 'win32' && child.pid) spawn('taskkill', ['/pid', String(child.pid), '/t', '/f'], { stdio: 'ignore', windowsHide: true })
      else child.kill('SIGKILL')
    }
    const timer = setTimeout(stop, 180_000)
    if (signal?.aborted) stop()
    signal?.addEventListener('abort', stop, { once: true })
    const cleanup = (): void => { clearTimeout(timer); signal?.removeEventListener('abort', stop) }
    child.on('error', () => { cleanup(); reject(new Error('변환기를 실행하지 못했어요.')) })
    child.on('exit', (code) => { cleanup(); code === 0 && !signal?.aborted ? resolve() : reject(new Error(signal?.aborted ? '변환을 취소했어요.' : '변환기를 실행하지 못했거나 처리 시간이 초과됐어요.')) })
  })
}

export function createConversionRuntime(userData: string) {
  const root = join(userData, 'presentation-runtime')
  const installation = join(root, `${OFFICE_RUNTIME_VERSION}-${process.platform}-${process.arch}`)
  const executable = process.platform === 'darwin' ? join(installation, 'LibreOffice.app', 'Contents', 'MacOS', 'soffice') : join(installation, 'program', 'soffice.exe')
  const packageInfo = OFFICE_PACKAGES[`${process.platform}-${process.arch}`]
  let state: ConversionRuntimeState = { status: packageInfo ? 'missing' : 'unsupported', version: OFFICE_RUNTIME_VERSION, receivedBytes: 0, totalBytes: 0, message: null }
  let installing: Promise<ConversionRuntimeState> | null = null
  let controller: AbortController | null = null
  const jobs = new Map<string, AbortController>()
  async function getState(): Promise<ConversionRuntimeState> {
    if (!installing && packageInfo) {
      try { await access(executable); await access(join(installation, '.verified')); state = { ...state, status: 'ready', message: null } } catch { /* Keep useful last failure for retry UI. */ }
    }
    return { ...state }
  }
  async function install(): Promise<ConversionRuntimeState> {
    if (installing) return installing
    if ((await getState()).status === 'ready') return { ...state }
    if (!packageInfo) throw new Error('이 운영체제의 구형 PPT 변환기는 아직 지원하지 않아요.')
    controller = new AbortController()
    const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(30 * 60_000)])
    installing = (async () => {
      await mkdir(root, { recursive: true })
      const staging = await mkdtemp(join(root, '.install-'))
      const installer = join(staging, basename(packageInfo.path))
      const extracted = join(staging, 'runtime')
      let mountAttempted = false
      const mount = join(staging, 'volume')
      try {
        state = { ...state, status: 'downloading', receivedBytes: 0, totalBytes: 0, message: null }
        const source = await downloadSource(`https://download.documentfoundation.org/libreoffice/stable/${OFFICE_RUNTIME_VERSION}/${packageInfo.path}`, signal)
        state.totalBytes = source.total
        const hash = createHash('sha256')
        const progress = new Transform({ transform(chunk: Buffer, _encoding, callback) {
          state.receivedBytes += chunk.length
          if (state.receivedBytes > 600 * 1024 * 1024) { callback(new Error('변환기 크기가 올바르지 않아요.')); return }
          hash.update(chunk); callback(null, chunk)
        } })
        await pipeline(source.stream, progress, createWriteStream(installer, { flags: 'wx' }), { signal })
        if (hash.digest('hex') !== packageInfo.sha256) throw new Error('변환기 무결성 검사에 실패했어요. 다시 내려받아 주세요.')
        state.status = 'installing'
        await mkdir(extracted)
        if (process.platform === 'darwin') {
          await mkdir(mount)
          mountAttempted = true
          await runOfficeCommand('/usr/bin/hdiutil', ['attach', installer, '-nobrowse', '-readonly', '-mountpoint', mount], signal)
          const application = join(mount, 'LibreOffice.app')
          await runOfficeCommand('/usr/bin/codesign', ['--verify', '--deep', '--strict', application], signal)
          await cp(application, join(extracted, 'LibreOffice.app'), { recursive: true, verbatimSymlinks: true })
        } else {
          const script = '$s = Get-AuthenticodeSignature -LiteralPath $env:BANDAL_OFFICE_INSTALLER; if ($s.Status -ne "Valid" -or $s.SignerCertificate.Subject -notmatch "Document Foundation") { exit 1 }'
          await runOfficeCommand('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')], signal, { ...process.env, BANDAL_OFFICE_INSTALLER: installer })
          await runOfficeCommand('msiexec.exe', ['/a', installer, '/qn', '/norestart', `TARGETDIR=${extracted}`], signal)
        }
        if (signal.aborted) throw new Error('변환기 설치를 취소했어요.')
        await access(process.platform === 'darwin' ? join(extracted, 'LibreOffice.app', 'Contents', 'MacOS', 'soffice') : join(extracted, 'program', 'soffice.exe'))
        await writeFile(join(extracted, '.verified'), packageInfo.sha256, { flag: 'wx' })
        await rename(extracted, installation)
        await access(executable)
        state = { ...state, status: 'ready', message: null }
        return { ...state }
      } catch (cause) {
        state = { ...state, status: 'error', message: cause instanceof Error ? cause.message : '변환기 설치에 실패했어요.' }
        throw new Error(state.message!)
      } finally {
        if (mountAttempted) await runOfficeCommand('/usr/bin/hdiutil', ['detach', mount]).catch(() => {})
        await rm(staging, { recursive: true, force: true })
      }
    })().finally(() => { installing = null; controller = null })
    return installing
  }
  async function normalize(inputPath: string, requestId: string): Promise<Buffer> {
    if ((await getState()).status !== 'ready') throw new Error('먼저 구형 PPT 변환기를 설치해 주세요.')
    if (jobs.has(requestId) || jobs.size > 0) throw new Error('다른 프레젠테이션을 처리하고 있어요. 완료 후 다시 시도해 주세요.')
    const abort = new AbortController(); jobs.set(requestId, abort)
    let work: string | null = null
    try {
      const input = await readFile(inputPath)
      const cache = join(root, 'cache', OFFICE_RUNTIME_VERSION)
      const key = createHash('sha256').update(input).digest('hex')
      const cachedPath = join(cache, `${key}.pptx`)
      try {
        const cached = await readFile(cachedPath)
        if (cached.length > 0 && cached.length <= 128 * 1024 * 1024) {
          await utimes(cachedPath, new Date(), new Date())
          return cached
        }
      } catch { /* Cache miss. Originals are never changed. */ }
      if (abort.signal.aborted) throw new Error('변환을 취소했어요.')
      await mkdir(join(root, 'jobs'), { recursive: true })
      work = await mkdtemp(join(root, 'jobs', 'convert-'))
      const source = join(work, 'source.ppt')
      const profile = join(work, 'profile')
      await mkdir(join(profile, 'user'), { recursive: true })
      await writeFile(join(profile, 'user', 'registrymodifications.xcu'), '<?xml version="1.0"?><oor:items xmlns:oor="http://openoffice.org/2001/registry"><item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item><item oor:path="/org.openoffice.Office.Common/Load"><prop oor:name="UpdateMode" oor:op="fuse"><value>0</value></prop></item></oor:items>')
      await writeFile(source, input)
      await runOfficeCommand(executable, [`-env:UserInstallation=${pathToFileURL(profile).href}`, '--headless', '--nologo', '--nodefault', '--norestore', '--convert-to', 'pptx:Impress MS PowerPoint 2007 XML', '--outdir', work, source], abort.signal)
      const output = join(work, 'source.pptx')
      if ((await stat(output)).size > 128 * 1024 * 1024) throw new Error('변환된 파일이 너무 커요 (128MB 제한).')
      const result = await readFile(output)
      await mkdir(cache, { recursive: true })
      await cp(output, cachedPath)
      // Disposable normalized copies: at most 512MB, most recently used first.
      const entries = await Promise.all((await readdir(cache)).filter((name) => /^[a-f0-9]{64}\.pptx$/.test(name)).map(async (name) => ({ path: join(cache, name), info: await stat(join(cache, name)) })))
      let total = 0
      for (const entry of entries.sort((a, b) => b.info.mtimeMs - a.info.mtimeMs)) {
        total += entry.info.size
        if (total > 512 * 1024 * 1024) await rm(entry.path, { force: true })
      }
      return result
    } finally { jobs.delete(requestId); if (work) await rm(work, { recursive: true, force: true }) }
  }
  return { getState, install, normalize, cancelInstall: (): void => controller?.abort(), cancel: (id: string): void => jobs.get(id)?.abort() }
}
