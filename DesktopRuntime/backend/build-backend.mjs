import { createRequire } from 'node:module'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { mkdir, writeFile, copyFile } from 'node:fs/promises'
import { dependencies } from '../scripts/dependencies.mjs'
import { adaptPlatformSource } from '../renderer/platform/index.mjs'
const here = dirname(fileURLToPath(import.meta.url))
let esbuild
const { require: runtimeRequire } = dependencies()
try { esbuild = createRequire(runtimeRequire.resolve('vite'))('esbuild') } catch { /* Direct dependency fallback below. */ }
for (const location of [resolve(here, '../package.json'), resolve(here, '../../../bandal/package.json')]) {
  try { esbuild = createRequire(location)('esbuild'); break } catch { /* Next installed workspace. */ }
}
if (!esbuild) throw new Error('esbuild is required; install DesktopRuntime dependencies first')
export const output = resolve(process.argv[2] ?? resolve(here, 'dist/backend.js'))
const shim = name => resolve(here, 'shims', name + '.ts')
const aliases = { 'node:fs': shim('fs'), 'node:fs/promises': shim('fs-promises'), 'node:crypto': shim('crypto'),
  'node:path': shim('path'), 'node:os': shim('os'), 'node:timers/promises': shim('timers-promises'), electron: shim('electron') }
const result = await esbuild.build({ entryPoints: [resolve(here, 'index.ts')], outfile: output,
  bundle: true, platform: 'neutral', mainFields: ['browser', 'module', 'main'], target: 'es2020', format: 'iife', sourcemap: false, metafile: true,
  plugins: [{ name: 'ipad-native-boundaries', setup(build) {
    build.onLoad({ filter: /\/shared\/keymap\.ts$|\/main\/features\/browser\/webviewPolicy\.ts$/ }, async args => {
      const source = await (await import('node:fs/promises')).readFile(args.path, 'utf8')
      return { contents: adaptPlatformSource(source, args.path)?.code ?? source, loader: 'ts', resolveDir: dirname(args.path) }
    })
    build.onResolve({filter:/^electron$/},args=>args.importer.endsWith('/hoverPreview.ts')?{path:resolve(here,'hover/utility-process.ts')}:undefined)
    build.onLoad({filter:/\/hoverPreview\.ts$/},async args=>({contents:'const __dirname = "";\n'+await(await import('node:fs/promises')).readFile(args.path,'utf8'),loader:'ts',resolveDir:dirname(args.path)}))
    build.onLoad({filter:/\/hoverPreviewExtract\.ts$/},async args=>{
      const source=await(await import('node:fs/promises')).readFile(args.path,'utf8'),start=source.indexOf('export const HOVER_TEXT_READ_BYTES'),end=source.indexOf('async function boundedZip')
      if(start<0||end<=start)throw new Error('Original hover text boundary changed')
      // Only the exact original bounded text reader belongs in JavaScriptCore.
      // Office/image extraction is bundled unchanged in the disposable worker.
      return{contents:"import {open} from 'node:fs/promises';\n"+source.slice(start,end),loader:'ts',resolveDir:dirname(args.path)}
    })
    build.onLoad({ filter: /\/mcpRegistry\/registryStore\.ts$/ }, async args => {
      let source = await (await import('node:fs/promises')).readFile(args.path, 'utf8')
      const start = source.indexOf('function loginShellPath()'), end = source.indexOf('function inputStringMap(', start)
      if (start < 0 || end < 0) throw new Error('Original MCP process boundary changed')
      source = source.slice(0, start) + 'const defaultCommandExists = () => false\n\n' + source.slice(end)
      source = source.replace("import { spawnSync } from 'node:child_process'\n", '').replace(/import \{[\s\S]*?\} from '\.\.\/agent\/platform'\n/, match => {
        const start = match.lastIndexOf('import {'); return match.slice(0, start)
      })
      return { contents: source, loader: 'ts', resolveDir: dirname(args.path) }
    })
    build.onLoad({filter:/\/shared\/plugins\/archive\.ts$/},async args=>{
      const source=await(await import('node:fs/promises')).readFile(args.path,'utf8'),needle="entry.nodeStream() as import('node:stream').Readable"
      if(source.split(needle).length!==2)throw new Error('Original plugin archive stream boundary changed')
      return{contents:`import {createZipEntryStream} from ${JSON.stringify(resolve(here,'market/zip-stream.ts'))};\n`+source.replace(needle,'createZipEntryStream(entry)'),loader:'ts',resolveDir:dirname(args.path)}
    })
    build.onResolve({filter:/^\.\/conversionRuntime$/},args=>args.importer.endsWith('/presentationService.ts')?{path:resolve(here,'presentation/native-conversion.ts')}:undefined)
    build.onLoad({filter:/\/presentationService\.ts$/},async args=>{
      const source=await(await import('node:fs/promises')).readFile(args.path,'utf8'),needle="resolveDefaultFontPath('NotoSansKR-Regular.otf')"
      if(source.split(needle).length!==2)throw new Error('Original presentation font boundary changed')
      return{contents:`import {nativeFontPath} from ${JSON.stringify(resolve(here,'presentation/fonts.ts'))};\n`+source.replace(needle,"nativeFontPath('NotoSansKR-Regular.otf')"),loader:'ts',resolveDir:dirname(args.path)}
    })
    build.onLoad({ filter: /\/main\/settingsStore\.ts$/ }, async args => {
      let source = await (await import('node:fs/promises')).readFile(args.path, 'utf8')
      const signature = 'export function setSettings(patch: SettingsPatch): Settings {'
      if (!source.includes(signature)) throw new Error('Original settings platform boundary changed')
      source = source.replace(signature, signature + `
  if (patch.experimental?.extensionRuntime === true) throw new ValidationError('iPad에서는 로컬 실행 플러그인 런타임을 사용할 수 없습니다.')
  if (patch.browser?.extensions?.length) throw new ValidationError('iPad WKWebView에서는 Chromium 확장을 실행할 수 없습니다.')`)
      source = source.replace('...DEFAULT_SETTINGS,', '...DEFAULT_SETTINGS, experimental: { extensionRuntime: false },')
      source = source.replace('cached = sanitizeSettings(raw, defaultsWithPaths())', 'cached = sanitizeSettings(raw, defaultsWithPaths()); cached.experimental.extensionRuntime = false; cached.browser.extensions = []')
      source = source.replace('    ...DEFAULT_SETTINGS,\n    dataRoot: current.dataRoot,', '    ...DEFAULT_SETTINGS, experimental: { extensionRuntime: false },\n    dataRoot: current.dataRoot,')
      return { contents: source, loader: 'ts', resolveDir: dirname(args.path) }
    })
    build.onResolve({ filter: /^(mammoth|exceljs|jszip)$/ }, args => ({ path: args.path === 'mammoth' ? resolve(here, 'ai/mammoth.ts') : runtimeRequire.resolve(args.path === 'exceljs' ? 'exceljs/dist/exceljs.bare.min.js' : 'jszip/dist/jszip.min.js') }))
    build.onLoad({ filter: /\/agentTools\/documentEdit\.ts$/ }, async args => {
      const source = await (await import('node:fs/promises')).readFile(args.path, 'utf8')
      const needle = 'await workbook.xlsx.readFile(input.absPath)'
      if (source.split(needle).length !== 2) throw new Error('Original workbook IO boundary changed')
      return { contents: source.replace(needle, 'await workbook.xlsx.load(await readFile(input.absPath))'), loader: 'ts' }
    })
    build.onResolve({ filter: /\/browserAgent\/browserTools$/ }, args => ({ path: resolve(args.resolveDir, args.path + '.ts'), namespace: 'browser-key-constants' }))
    build.onLoad({ filter: /.*/, namespace: 'browser-key-constants' }, async args => {
      const source = await (await import('node:fs/promises')).readFile(args.path, 'utf8')
      const declaration = source.match(/^export const BROWSER_KEYS = .+$/m)?.[0]
      if (!declaration) throw new Error('Original browser key constants changed')
      return { contents: declaration, loader: 'ts' }
    })
    build.onResolve({ filter: /\/materialSource$/ }, args => /\/learning(?:Grounding)?[^/]*\.ts$/.test(args.importer) ? ({ path: resolve(here, 'ai/material-source.ts') }) : undefined)
    build.onResolve({ filter: /^(node:|electron$)/ }, args => {
      const path = aliases[args.path]; if (!path) throw new Error(`Unbridged native module: ${args.path}`); return { path }
    })
    build.onResolve({ filter: /\/lib\/atomicWrite$/ }, () => ({ path: shim('atomic-write') }))
    // Keep the original pure word matcher byte-for-byte. Its surrounding
    // Electron browser adapter is supplied by the WK host, never bundled.
    build.onResolve({ filter: /\/learning\/articleExtractor$/ }, args => ({ path: resolve(args.resolveDir, args.path + '.ts'), namespace: 'article-matcher' }))
    build.onLoad({ filter: /.*/, namespace: 'article-matcher' }, async args => {
      const source = await (await import('node:fs/promises')).readFile(args.path, 'utf8')
      const start = source.indexOf('function cleanUrl('), end = source.indexOf('\nfunction abortError()', start)
      if (start < 0 || end < 0) throw new Error('Original article matcher boundary changed; review adapter')
      return { contents: `import { createHash } from ${JSON.stringify(shim('crypto'))}; const MAX_ARTICLE_CHARS = 100_000;\n` + source.slice(start, end), loader: 'ts', resolveDir: here }
    })
    build.onResolve({ filter: /^\.\/binaryLocator$|^\.\/rpcSession$/ }, args => {
      if (!/\/SessionManager\.ts$/i.test(args.importer)) return undefined
      return { path: resolve(args.resolveDir, args.path + '.ts'), namespace: 'agent-pure' }
    })
    build.onLoad({ filter: /.*/, namespace: 'agent-pure' }, async args => {
      const source = await (await import('node:fs/promises')).readFile(args.path, 'utf8')
      const locator = args.path.endsWith('/binaryLocator.ts')
      const start = source.indexOf(locator ? 'export class AgentUnavailableError' : 'export function providerModel(')
      const end = source.indexOf(locator ? '/** One candidate' : '\nfunction errorCode(', start)
      if (start < 0 || end < 0) throw new Error('Original agent pure boundary changed; review adapter')
      return { contents: source.slice(start, end), loader: 'ts' }
    })
    build.onResolve({ filter: /\.sql\?raw$/ }, args => ({ path: resolve(args.resolveDir, args.path.replace(/\?raw$/, '')), namespace: 'sql' }))
    build.onLoad({ filter: /.*/, namespace: 'sql' }, async args => ({ contents: await (await import('node:fs/promises')).readFile(args.path, 'utf8'), loader: 'text' }))
  } }] })
await mkdir(resolve(here, 'dist'), { recursive: true })
await writeFile(resolve(here, 'dist/backend-metafile.json'), JSON.stringify(result.metafile, null, 2))
// Renderer rebuilds replace this resource directory. Always embed the freshly
// built backend afterwards, including when a caller chooses a custom output.
const embedded = resolve(here, '../../App/Resources/Desktop/backend.js')
await mkdir(dirname(embedded), { recursive: true })
if (process.env.BANDAL_SKIP_EMBED !== '1' && output !== embedded) await copyFile(output, embedded)
console.log(`Desktop backend built: ${output}; ${Object.keys(result.metafile.inputs).length} input modules`)
