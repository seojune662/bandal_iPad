import assert from 'node:assert/strict'
import vm from 'node:vm'
import { readFile } from 'node:fs/promises'
import { dependencies } from '../../../scripts/dependencies.mjs'

const ts = dependencies().require('typescript')
const source = await readFile(new URL('sidebarSwipePolicy.ts', import.meta.url), 'utf8')
const exports = {}
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, { exports })
const { beginSidebarSwipe, moveSidebarSwipe, shouldCommitSidebarSwipe } = exports
const start = open => beginSidebarSwipe(open, 100, 100, 0)
const move = (swipe, x, y = 100, time = 200) => moveSidebarSwipe(swipe, x, y, time)

assert.equal(move(start(false), 107).phase, 'pending', 'Small tap jitter is not a swipe')
assert.equal(move(start(false), 108, 100, 1).phase, 'dragging', 'Horizontal drag begins immediately without a hold')
assert.equal(shouldCommitSidebarSwipe(move(start(false), 148), 200), true, 'Swipe right opens the closed sidebar')
assert.equal(shouldCommitSidebarSwipe(move(start(true), 52), 200), true, 'Swipe left closes the open sidebar')
assert.equal(shouldCommitSidebarSwipe(move(start(false), 124, 100, 40), 45), true, 'Short fast flick commits')
assert.equal(shouldCommitSidebarSwipe(move(start(false), 124, 100, 300), 305), false, 'Short slow movement returns to rest')
assert.equal(shouldCommitSidebarSwipe(move(start(false), 124, 100, 40), 200), false, 'A held short drag is not a flick')
assert.equal(shouldCommitSidebarSwipe(move(start(false), 123, 100, 10), 10), false, 'Tiny high-speed movement never commits')
assert.equal(move(start(false), 103, 108).phase, 'cancelled', 'Vertical motion yields to scrolling')
assert.equal(move(start(false), 110, 109).phase, 'cancelled', 'Diagonal movement does not hijack scrolling')
assert.equal(move(start(false), 92).phase, 'cancelled', 'Wrong opening direction cancels')
assert.equal(move(start(true), 108).phase, 'cancelled', 'Wrong closing direction cancels')
const vertical = move(start(false), 103, 108)
assert.equal(move(vertical, 180).phase, 'cancelled', 'A cancelled gesture stays cancelled')
const reversed = move(move(start(false), 140, 100, 40), 128, 100, 60)
assert.equal(shouldCommitSidebarSwipe(reversed, 60), false, 'A reverse movement cannot finish as a quick flick')
assert.equal(shouldCommitSidebarSwipe(start(false), 1000), false, 'A long hold alone never toggles the sidebar')
console.log('PASS iPad sidebar swipe: immediate horizontal recognition, directional commit, flick, scroll and reversal cancellation')
