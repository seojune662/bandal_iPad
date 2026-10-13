import { createRequire } from 'node:module'
import { mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'
import { dependencies, runtime } from './dependencies.mjs'
const { require } = dependencies()
const { build } = createRequire(require.resolve('vite'))('esbuild')
const directory = resolve(runtime, '../App/Resources/DesktopNative')
await mkdir(directory, { recursive: true })
await build({ entryPoints: [resolve(runtime,'native/browser-agent.ts')], outfile:resolve(directory,'browser-agent.js'), bundle:true, platform:'browser', target:'safari18', format:'iife', minify:false })
console.log('Bundled original isolated browser driver and action policy')
