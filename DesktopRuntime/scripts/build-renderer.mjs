import nativePDFPlugin from '../renderer/nativePDF/index.mjs'
import { readFile, writeFile } from 'node:fs/promises'
import { resolve, relative } from 'node:path'
import { pathToFileURL } from 'node:url'
import { dependencies, runtime } from './dependencies.mjs'
import { verifySnapshot } from './verify-snapshot.mjs'
import { copyPDFResources } from './pdf-resources.mjs'
import pencilInputPlugin from '../renderer/pencil/index.mjs'
import syncPlugin from '../renderer/sync/index.mjs'
import nativeRecordingPlugin from '../renderer/recording/index.mjs'
import ipadPlatformPlugin from '../renderer/platform/index.mjs'
import nativeMiniPlayerPlugin from '../renderer/pip/index.mjs'
import browserPlugin from '../renderer/browser/index.mjs'

await verifySnapshot()
await import('./build-article-extraction.mjs')
await import('./build-browser-agent.mjs')
await import('./build-pip.mjs')
const { require, source } = dependencies()
const { build } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: react } = await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
const snapshot = JSON.parse(await readFile(resolve(runtime, 'upstream/manifest.json'), 'utf8'))
const outDir = resolve(runtime, '../App/Resources/Desktop')
const built = await build({
  configFile: false, root: resolve(runtime, 'renderer'), base: './',
  define: { __APP_VERSION__: JSON.stringify(snapshot.appVersion) },
  plugins: [pencilInputPlugin(), ipadPlatformPlugin(), nativeRecordingPlugin(), browserPlugin(), nativePDFPlugin(), syncPlugin(), nativeMiniPlayerPlugin(), react()],
  resolve: { dedupe: ['react', 'react-dom', '@milkdown/core', '@milkdown/ctx', '@milkdown/utils', '@milkdown/prose', '@milkdown/transformer', '@milkdown/exception'] },
  build: { target: 'safari18', outDir, emptyOutDir: true, reportCompressedSize: false, sourcemap: false, manifest: true,
    rollupOptions: { input: { main: resolve(runtime, 'renderer/index.html'), pip: resolve(runtime, 'renderer/pip.html'), capture: resolve(runtime, 'renderer/capture.html') } } }
})
const outputs = Array.isArray(built) ? built : [built]
await copyPDFResources(outDir)
const modules = new Set(outputs.flatMap(output => output.output.filter(item => item.type === 'chunk').flatMap(chunk => Object.keys(chunk.modules))).filter(path => path.startsWith(resolve(runtime, 'upstream/'))).map(path => relative(runtime, path)))
await writeFile(resolve(outDir, 'bundled-source.json'), JSON.stringify([...modules].sort(), null, 2) + '\n')
await writeFile(resolve(outDir, 'source-provenance.json'), JSON.stringify({
  format: snapshot.format, sourceCommit: snapshot.sourceCommit, appVersion: snapshot.appVersion,
  manifest: 'DesktopRuntime/upstream/manifest.json', files: snapshot.files.length,
  renderer: 'original desktop src/renderer/src/main.tsx', platform: 'ipad',
  adapters: ['WK native IPC', 'Files input staging', 'Pencil/finger input', 'iPad Command key mapping', 'native API connection controls', 'native lecture recording', 'local PDF CMaps/fonts/decoders']
}, null, 2) + '\n')
console.log(`Full desktop renderer built from ${source}: ${outDir}`)
