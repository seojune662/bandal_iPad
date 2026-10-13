import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const editorRoot = join(root, 'WebEditor')
const moduleCandidates = [join(editorRoot, 'node_modules'), join(root, 'node_modules'), resolve(root, '../bandal/node_modules')]
const modules = moduleCandidates.find(directory => existsSync(join(directory, 'vite/package.json')) && existsSync(join(directory, '@milkdown/core/package.json')))
if (!modules) throw new Error('WebEditor dependencies are missing. Run pnpm install in WebEditor, or provide the adjacent bandal checkout with its dependencies installed.')
const { build } = await import(pathToFileURL(join(modules, 'vite/dist/node/index.js')).href)
const directPackages = ['@milkdown/core', '@milkdown/ctx', '@milkdown/plugin-history', '@milkdown/preset-commonmark', '@milkdown/preset-gfm', '@milkdown/prose', '@milkdown/utils', '@silurus/ooxml', 'jszip', 'mammoth', 'xlsx']
const alias = []
const typePaths = {
  react: [join(modules, '@types/react/index.d.ts')],
  'react/*': [join(modules, '@types/react/*')],
  'react-dom/*': [join(modules, '@types/react-dom/*')]
}
for (const name of directPackages) {
  const directory = join(modules, name)
  const manifest = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8'))
  if (!manifest.exports) {
    alias.push({ find: name, replacement: directory })
    const types = manifest.types ?? manifest.typings ?? manifest.main?.replace(/\.js$/, '.d.ts')
    if (types && existsSync(join(directory, types))) typePaths[name] = [join(directory, types)]
  }
  for (const [key, value] of Object.entries(manifest.exports ?? {})) {
    const entry = typeof value === 'string' ? value : value.import
    const specifier = key === '.' ? name : name + key.slice(1)
    if (entry) alias.push({ find: specifier, replacement: join(directory, entry) })
    if (typeof value === 'object' && value.types) typePaths[specifier] = [join(directory, value.types)]
  }
}
alias.sort((a, b) => b.find.length - a.find.length)
alias.push({ find: 'react', replacement: join(modules, 'react') }, { find: 'react-dom', replacement: join(modules, 'react-dom') })
const ts = (await import(pathToFileURL(join(modules, 'typescript/lib/typescript.js')).href)).default
const program = ts.createProgram([join(editorRoot, 'src/main.tsx'), join(editorRoot, 'src/bridge.ts'), join(editorRoot, 'src/documents/main.tsx')], {
  noEmit: true, strict: true, skipLibCheck: true, allowSyntheticDefaultImports: true,
  jsx: ts.JsxEmit.ReactJSX, target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext,
  moduleResolution: ts.ModuleResolutionKind.Bundler, lib: ['lib.es2022.d.ts', 'lib.dom.d.ts', 'lib.dom.iterable.d.ts'],
  baseUrl: editorRoot, paths: typePaths, types: []
})
const diagnostics = ts.getPreEmitDiagnostics(program)
if (diagnostics.length) {
  process.stderr.write(ts.formatDiagnosticsWithColorAndContext(diagnostics, { getCanonicalFileName: name => name, getCurrentDirectory: () => root, getNewLine: () => '\n' }))
  process.exit(1)
}
if (process.argv.includes('--check')) { process.stdout.write('WebEditor typecheck passed.\n'); process.exit(0) }
await build({
  configFile: false,
  root: editorRoot,
  base: './',
  resolve: { alias },
  esbuild: { jsx: 'automatic' },
  build: {
    outDir: join(root, 'App/Resources/Editor'), emptyOutDir: true, target: 'safari17', sourcemap: false,
    rollupOptions: { input: { editor: join(editorRoot, 'index.html'), documents: join(editorRoot, 'documents.html') } }
  }
})
