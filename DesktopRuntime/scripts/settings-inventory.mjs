import { readFile, writeFile, access } from 'node:fs/promises'
import { resolve, dirname, relative, isAbsolute } from 'node:path'
import { createHash } from 'node:crypto'
import { dependencies, runtime } from './dependencies.mjs'
import { adaptPlatformSource } from '../renderer/platform/index.mjs'
import nativeRecordingPlugin from '../renderer/recording/index.mjs'
import nativePDFPlugin from '../renderer/nativePDF/index.mjs'

const ts = dependencies().require('typescript'), recording = nativeRecordingPlugin(), nativePDF = nativePDFPlugin()
const base = resolve(runtime, 'upstream/src/renderer/src/features/settings')
const entries = [
  ['ai', 'SettingsPanels', 'AiPanel'], ['assistant', 'assistant/AssistantPanel', 'AssistantPanel'],
  ['account', 'AccountPanel', 'AccountPanel'], ['general', 'SettingsPanels', 'GeneralPanel'],
  ['university', 'UniversitySettingsPanel', 'UniversitySettingsPanel'], ['packs', 'PluginsCategoryPanel', 'PluginsCategoryPanel'],
  ['calendar', '../calendar/CalendarSettingsPanel', 'CalendarSettingsPanel'], ['browser', 'browser/BrowserSettingsPanel', 'BrowserSettingsPanel'],
  ['appearance', 'AppearancePanel', 'AppearancePanel'], ['tabs', 'TabsSettingsPanel', 'TabsSettingsPanel'],
  ['widgets', 'WidgetSettingsPanel', 'WidgetSettingsPanel'], ['notifications', 'notifications/NotificationsPanel', 'NotificationsPanel'],
  ['shortcuts', 'shortcuts/ShortcutsPanel', 'ShortcutsPanel'], ['usage', 'usage/UsagePanel', 'UsagePanel'],
  ['permissions', 'permissions/PermissionsPanel', 'PermissionsPanel'], ['privacy', 'privacy/PrivacyPanel', 'PrivacyPanel'],
  ['advanced', 'advanced/AdvancedPanel', 'AdvancedPanel'], ['experimental', 'advanced/ExperimentalPanel', 'ExperimentalPanel'],
  ['courses', 'SettingsPanels', 'CoursesPanel'], ['about', 'SettingsPanels', 'AboutPanel']
]
const cache = new Map(), sources = new Map()
async function resolveModule(file, name) {
  if (!name.startsWith('.') && !isAbsolute(name)) return null
  const root = resolve(dirname(file), name)
  for (const candidate of [root, root + '.tsx', root + '.ts', resolve(root, 'index.tsx'), resolve(root, 'index.ts')]) {
    try { await access(candidate); return candidate } catch {}
  }
  return null
}
async function module(file) {
  if (cache.has(file)) return cache.get(file)
  const raw = await readFile(file, 'utf8')
  const platform = adaptPlatformSource(raw, file)?.code ?? raw
  const recorded = recording.transform(platform, file)?.code ?? platform
  const source = nativePDF.transform(recorded, file)?.code ?? recorded
  const ast = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
  const result = { ast, source, functions: new Map(), imports: new Map() }
  cache.set(file, result)
  sources.set(relative(runtime, file), createHash('sha256').update(source).digest('hex'))
  for (const node of ast.statements) {
    if (ts.isFunctionDeclaration(node) && node.name) result.functions.set(node.name.text, node)
    if (ts.isVariableStatement(node)) for (const declaration of node.declarationList.declarations) {
      if (ts.isIdentifier(declaration.name) && declaration.initializer) result.functions.set(declaration.name.text, declaration.initializer)
    }
    if (ts.isImportDeclaration(node) && ts.isStringLiteral(node.moduleSpecifier)) {
      const target = await resolveModule(file, node.moduleSpecifier.text)
      if (!target) continue
      const bindings = node.importClause?.namedBindings
      if (bindings && ts.isNamedImports(bindings)) for (const item of bindings.elements) result.imports.set(item.name.text, [target, item.propertyName?.text ?? item.name.text])
      if (node.importClause?.name) result.imports.set(node.importClause.name.text, [target, 'default'])
    }
  }
  return result
}
const controls = [], unresolved = []
const compact = value => value.replace(/\s+/g, ' ').trim().slice(0, 500)
async function walk(route, file, component, visited) {
  const key = file + ':' + component
  if (visited.has(key)) return
  visited.add(key)
  const data = await module(file), node = data.functions.get(component)
  if (!node) { unresolved.push({ route, file: relative(runtime, file), component }); return }
  const nested = new Set()
  function visit(item) {
    if (ts.isJsxSelfClosingElement(item) || ts.isJsxOpeningElement(item)) {
      const tag = item.tagName.getText(data.ast)
      const attributes = Object.fromEntries(item.attributes.properties.filter(ts.isJsxAttribute).map(a => [a.name.text, a.initializer?.getText(data.ast) ?? 'true']))
      if (['button', 'input', 'select', 'textarea', 'ToggleRow'].includes(tag)) {
        const element = ts.isJsxOpeningElement(item) && ts.isJsxElement(item.parent) ? item.parent : item
        const labelParent = item.parent?.parent
        const label = attributes['aria-label'] ?? attributes.label ?? (tag === 'button' ? element.getText(data.ast).replace(/^<button[^>]*>/s, '').replace(/<\/button>$/, '') : labelParent && ts.isJsxElement(labelParent) && labelParent.openingElement.tagName.getText(data.ast) === 'label' ? labelParent.getText(data.ast) : attributes.title ?? attributes.placeholder ?? attributes.id ?? '')
        const handler = Object.entries(attributes).filter(([name]) => /^on(?:Click|Change|Blur|KeyDown|Submit)$/.test(name)).map(([name, value]) => `${name}=${value}`).join(' ')
        const line = data.ast.getLineAndCharacterOfPosition(item.getStart()).line + 1
        controls.push({ id: `${route}:${relative(base, file)}:${component}:${line}`, route, file: relative(runtime, file), adaptedLine: line, component, control: tag, label: compact(label), handler: compact(handler), dynamic: /\.map\(/.test(node.getText(data.ast)), behaviorStatus: 'unverified', evidence: [] })
      } else if (/^[A-Z]/.test(tag) && !['SettingsCard', 'Icon', 'BandalMark', 'ProviderMark', 'TabKindIcon'].includes(tag)) nested.add(tag)
    }
    ts.forEachChild(item, visit)
  }
  visit(node)
  for (const name of nested) {
    if (data.functions.has(name)) await walk(route, file, name, visited)
    else if (data.imports.has(name)) { const [target, imported] = data.imports.get(name); await walk(route, target, imported, visited) }
  }
}
for (const [route, path, component] of entries) {
  const visited = new Set()
  await walk(route, resolve(base, path + '.tsx'), component, visited)
  if (route === 'experimental') {
    // The iPad-only DEBUG comparison control is composed at the actual route,
    // not inside the byte-preserved desktop ExperimentalPanel component.
    const app = await module(resolve(base, 'SettingsApp.tsx'))
    const setting = app.imports.get('NativePDFDevelopmentSetting')
    if (!setting || !app.source.includes('<NativePDFDevelopmentSetting />')) throw new Error('Native PDF comparison setting is no longer connected to SettingsApp')
    await walk(route, setting[0], setting[1], visited)
  }
}
const snapshot = JSON.parse(await readFile(resolve(runtime, 'upstream/manifest.json'), 'utf8'))
const result = {
  format: 'bandal-settings-control-inventory', version: 1, sourceCommit: snapshot.sourceCommit,
  method: 'Reachable JSX control declarations from the 20 actual settings roots, after iPad platform/recording/native-PDF transforms, including the DEBUG-only comparison control composed at the experimental route. Dynamic loops are declarations, not a claim that every data-dependent row has been exercised. adaptedLine refers to transformed source; handlers remain original except explicit iPad adapters.',
  acceptance: ['render and reach control', 'change or invoke', 'verify returned/saved value', 'verify actual consumer effect', 'reopen runtime', 'cancel/fail/recover', 'touch/keyboard/accessibility'],
  routes: entries.map(([id]) => ({ id, declarations: controls.filter(control => control.route === id).length, behaviorStatus: 'unverified' })),
  subtabs: ['note', 'browser', 'chat', 'recording', 'whiteboard', 'board'],
  unresolvedComponents: unresolved,
  adaptedSources: Object.fromEntries([...sources].sort(([a], [b]) => a.localeCompare(b))),
  controls
}
const output = resolve(runtime, '../docs/settings-control-inventory.json')
if (process.argv.includes('--check')) {
  const existing = await readFile(output, 'utf8')
  if (existing !== JSON.stringify(result, null, 2) + '\n') throw new Error('Settings controls changed. Regenerate inventory, assess new controls, and update acceptance evidence.')
} else await writeFile(output, JSON.stringify(result, null, 2) + '\n')
console.log(`Settings inventory: ${entries.length} routes, 6 subtabs, ${controls.length} reachable control declarations; ${unresolved.length} unresolved components; behavior status is explicitly unverified`)
