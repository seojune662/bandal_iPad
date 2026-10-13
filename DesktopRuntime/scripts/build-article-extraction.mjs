import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import vm from 'node:vm'
import { dependencies, runtime } from './dependencies.mjs'
const { require } = dependencies()
const source = await readFile(resolve(runtime, 'upstream/src/main/features/learning/articleExtractor.ts'), 'utf8')
const start = source.indexOf('export const ARTICLE_EXTRACTION_SOURCE = `')
const end = source.indexOf('\nexport type ArticlePageContents', start)
if (start < 0 || end < 0) throw new Error('Original article extraction boundary changed')
const expression = source.slice(start, end).replace('export const ARTICLE_EXTRACTION_SOURCE = ', '')
const script = vm.runInNewContext(expression, { readabilitySource: await readFile(require.resolve('@mozilla/readability/Readability.js'), 'utf8'), MAX_PAGE_ELEMENTS: 30_000 })
if (typeof script !== 'string' || !script.includes('new Readability(page')) throw new Error('Article extraction bundle is invalid')
const target = resolve(runtime, '../App/Resources/DesktopNative')
await mkdir(target, { recursive: true })
await writeFile(resolve(target, 'article-extraction.js'), script)
await writeFile(resolve(target, 'Readability-LICENSE'), await readFile(require.resolve('@mozilla/readability/LICENSE.md')))
console.log('Bundled original Readability article extraction and license')
