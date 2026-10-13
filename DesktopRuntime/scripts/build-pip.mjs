import { createRequire } from 'node:module'
import { resolve } from 'node:path'
import { mkdir } from 'node:fs/promises'
import { dependencies, runtime } from './dependencies.mjs'
const { require } = dependencies(), { build } = createRequire(require.resolve('vite'))('esbuild')
const directory = resolve(runtime, '../App/Resources/DesktopNative')
await mkdir(directory, { recursive: true })
await build({ entryPoints: [resolve(runtime, 'upstream/src/main/windows/webPipIsolation.ts')], outfile: resolve(directory, 'web-pip.js'), bundle: true, platform: 'browser', target: 'safari18', format: 'iife', globalName: 'BandalWebPip' })
console.log('Bundled original web video isolation')
