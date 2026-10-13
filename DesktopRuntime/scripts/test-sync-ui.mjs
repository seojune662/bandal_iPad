import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { resolve } from 'node:path'
import { dependencies, runtime } from './dependencies.mjs'
const { require } = dependencies()
const { build } = createRequire(require.resolve('vite'))('esbuild')
const { webkit } = require('@playwright/test')
const compiled = await build({ stdin: { contents: "import React from 'react';import{createRoot}from'react-dom/client';import{SyncPanel}from'./renderer/sync/SyncPanel';createRoot(document.getElementById('root')).render(<SyncPanel/>);", loader: 'tsx', resolveDir: runtime }, bundle: true, write: false, format: 'iife', platform: 'browser', jsx: 'automatic', loader: { '.css': 'empty' } })
const browser = await webkit.launch()
try {
  const page = await browser.newPage()
  await page.setContent('<div id="root"></div>')
  await page.evaluate(() => {
    const local = { id: 'note:1', kind: 'note', deleted: false, payload: { markdown: '이 기기의 필기 <script>window.compromised=true</script>' } }
    const remote = { ...local, payload: { markdown: '다른 기기의 필기' } }
    window.fixture = { calls: [], failRestore: true, conflicts: [{ id: 'conflict', recordID: 'note:1', label: '역학 / 강의.md', createdAt: '2026-10-13T00:00:00Z', local, remote }] }
    window.bandal = {
      on: () => () => {},
      async invoke(channel, request) {
        window.fixture.calls.push({ channel, request })
        if (channel === 'settings:get') return { locale: 'ko-KR' }
        if (channel === 'runtime:syncState') return { phase: 'idle', conflicts: window.fixture.conflicts.length }
        if (channel === 'runtime:syncConflicts') return window.fixture.conflicts
        if (channel === 'runtime:syncExport') return { saved: false }
        if (channel === 'runtime:syncRestore') {
          if (window.fixture.failRestore) throw new Error('기기 저장 공간이 부족합니다.')
          window.fixture.conflicts = []; return { ok: true }
        }
        throw new Error('Unexpected channel ' + channel)
      }
    }
  })
  await page.addScriptTag({ content: compiled.outputFiles[0].text })
  await page.getByText('역학 / 강의.md', { exact: false }).click()
  assert.equal(await page.locator('pre').count(), 2)
  assert.equal(await page.evaluate(() => window.compromised), undefined)
  await page.getByRole('button', { name: '두 사본 내보내기', exact: true }).click()
  await page.getByRole('button', { name: '이 버전 사용', exact: true }).nth(1).click()
  await page.getByRole('alertdialog').waitFor()
  assert.equal((await page.evaluate(() => window.fixture.calls)).filter(call => call.channel === 'runtime:syncRestore').length, 0)
  await page.getByRole('button', { name: '취소', exact: true }).click()
  assert.equal(await page.getByRole('alertdialog').count(), 0)
  await page.getByRole('button', { name: '이 버전 사용', exact: true }).nth(1).click()
  await page.getByRole('button', { name: '선택한 버전 적용', exact: true }).click()
  await page.getByRole('alert').filter({ hasText: '기기 저장 공간이 부족합니다.' }).waitFor()
  assert.equal(await page.locator('pre').count(), 2, 'A failed apply keeps both visible copies')
  assert.equal(await page.getByRole('alertdialog').count(), 1)
  await page.evaluate(() => { window.fixture.failRestore = false })
  await page.getByRole('button', { name: '선택한 버전 적용', exact: true }).click()
  await page.waitForFunction(() => !document.querySelector('details'))
  const calls = await page.evaluate(() => window.fixture.calls)
  assert.deepEqual(calls.filter(call => call.channel === 'runtime:syncRestore').map(call => call.request), [{ id: 'conflict', variant: 'remote' }, { id: 'conflict', variant: 'remote' }])
  console.log('Original settings sync card: escaped previews, export cancel, explicit choice, failed restore retention, successful refresh passed in WebKit')
} finally { await browser.close() }
