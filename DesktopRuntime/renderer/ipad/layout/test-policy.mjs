import assert from 'node:assert/strict'
import vm from 'node:vm'
import { readFile } from 'node:fs/promises'
import { dependencies } from '../../../scripts/dependencies.mjs'
const ts = dependencies().require('typescript')
async function load(name) {
  const source = await readFile(new URL(name, import.meta.url), 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, { exports, localStorage: { getItem: () => null }, Set, JSON })
  return exports
}
const { ipadLayout, minimumSplitWidth } = await load('policy.ts')
const { readPanelModes } = await load('coordination.ts')
const auto = { left: 'auto', materials: 'auto', assistant: 'auto' }
const modes = values => JSON.parse(JSON.stringify(readPanelModes({ getItem: key => values[key] ?? null })))
assert.deepEqual(modes({}), auto)
assert.deepEqual(modes({ 'bandal:ipad:pinned-panel:v1': 'left', 'bandal:ipad:assistant-pin:v1': 'false' }), { ...auto, assistant: 'overlay' })
assert.deepEqual(modes({ 'bandal:ipad:panel-modes:v2': JSON.stringify({ left: 'overlay', materials: 'overlay', assistant: 'auto' }), 'bandal:ipad:assistant-pin:v1': 'false' }), { left: 'overlay', materials: 'overlay', assistant: 'auto' })
assert.deepEqual(modes({ 'bandal:ipad:panel-modes:v2': 'corrupt' }), auto)
assert.equal(ipadLayout(1366, { left: true, materials: true }, auto, 'materials').pinned, 'both')
assert.equal(ipadLayout(1216, { left: true, materials: true }, auto, 'left').pinned, 'both')
assert.equal(ipadLayout(935, { left: false, materials: true }, auto, 'materials').panels.materials, 'overlay', 'Persistent navigation width is reserved before docking')
assert.equal(ipadLayout(936, { left: false, materials: true }, auto, 'materials').panels.materials, 'docked')
assert.equal(ipadLayout(1366, { left: false, materials: false }, auto, 'left').leftInset, 56)
assert.equal(ipadLayout(1194, { left: true, materials: true }, auto, 'materials').panels.left, 'suspended')
assert.equal(ipadLayout(1194, { left: true, materials: true }, auto, 'left').panels.materials, 'suspended')
assert.equal(ipadLayout(834, { left: true, materials: true }, auto, 'materials').overlayOwner, 'materials')
assert.equal(ipadLayout(1366, { left: true, materials: true, assistantWidth: 320 }, auto, 'assistant').panels.materials, 'closed')
assert.equal(ipadLayout(1366, { left: true, materials: false, assistantWidth: 320 }, auto, 'assistant').panels.assistant, 'docked')
assert.equal(ipadLayout(1366, { left: true, materials: false, assistantWidth: 320 }, { ...auto, assistant: 'overlay' }, 'assistant').panels.left, 'docked')
const tree = { grid: { orientation: 'HORIZONTAL', root: { type: 'branch', data: [{ type: 'leaf', size: 2, data: { id: 'a' } }, { type: 'leaf', size: 1, data: { id: 'b' } }] } } }
assert.equal(minimumSplitWidth(tree), 1688)
assert.equal(minimumSplitWidth(tree, { b: 320 }), 2648)
assert.equal(minimumSplitWidth(tree, { a: 320 }), 1688)
console.log('PASS iPad policy: independent panel modes/migration, dual docks, priority suspension, per-leaf AI split budget')
