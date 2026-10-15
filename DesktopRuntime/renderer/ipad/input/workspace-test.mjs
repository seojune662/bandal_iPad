/** Real Dockview and original workspace queue: focus-only persistence and the
 * native lifecycle barrier, with only the IPC/disk boundary replaced. */
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { dependencies, runtime } from '../../../scripts/dependencies.mjs'
import { adaptInputSource } from './index.mjs'
await import('./test-save-barrier.mjs')
const { require } = dependencies(), { webkit } = require('@playwright/test')
const { build } = createRequire(require.resolve('vite'))('esbuild')
const built = await build({ stdin: { resolveDir: runtime, loader: 'tsx', contents: `
import React from 'react';import {createRoot} from 'react-dom/client';import {DockviewReact} from 'dockview';
import {useWorkspaceStore} from './upstream/src/renderer/src/stores/workspaceStore';
import {descriptorFor,tabPanelId} from './upstream/src/renderer/src/features/workspace/tabIdentity';
import {setIpcAdapter} from './upstream/src/renderer/src/lib/ipc';
import {DEFAULT_SETTINGS} from './upstream/src/shared/types/settings';
import {ensureSettingsLoaded} from './upstream/src/renderer/src/stores/settingsSnapshot';
import {flushIPadWorkspaceLayout} from './renderer/ipad/input/workspacePersistence';
import {installNativeLifecycle} from './renderer/lifecycle';
import {bindIpadWorkspace} from './renderer/ipad/layout/layout';
const courseId='00000000-0000-4000-8000-000000000001',key='ipad-active-layout';
const pdf=descriptorFor('pdf',{courseId,relPath:'lecture.pdf'}),note=descriptorFor('note',{courseId,relPath:'note.md'});
const calls=[],acks=[];let deferred=false,fail=false,api;
const nextFrame=()=>new Promise(resolve=>requestAnimationFrame(resolve));
const saved=()=>JSON.parse(localStorage.getItem(key)||'null');
function activeIn(layout){if(!layout)return null;const walk=node=>node.type==='leaf'?(node.data.id===layout.activeGroup?node.data.activeView:null):node.data.map(walk).find(Boolean);return walk(layout.grid.root)}
setIpcAdapter({on:()=>()=>{},invoke:async(channel,request)=>{
 if(channel==='settings:get')return structuredClone(DEFAULT_SETTINGS);
 if(channel==='layout:get')return {layout:saved()};
 if(channel==='layout:save'){
  calls.push(structuredClone(request));
  if(fail)throw new Error('fixture layout disk failure');
  if(deferred)await new Promise(resolve=>acks.push(resolve));
  localStorage.setItem(key,JSON.stringify(request.layout));return {ok:true};
 }
 throw new Error('Unexpected workspace fixture IPC '+channel);
}});
const body=()=> <div />;
const fixture={ready:false,calls,acks,saved,activeIn,
 state:()=>({active:api.activePanel?.id,store:useWorkspaceStore.getState().activePanelId,groups:api.groups.length,maximized:api.hasMaximizedGroup(),layout:api.toJSON()}),
 ids:{pdf:tabPanelId(pdf),note:tabPanelId(note)},
 create:()=>{useWorkspaceStore.getState().openTab(pdf);useWorkspaceStore.getState().openTab(note)},
 select:id=>api.getPanel(id).api.setActive(),
 defer:value=>{deferred=value},fail:value=>{fail=value},ack:()=>acks.shift()?.(),
 flush:flushIPadWorkspaceLayout,
 split:()=>useWorkspaceStore.getState().openTab(descriptorFor('note',{courseId,relPath:'split.md'}),{beside:true}),
 compact:()=>{document.getElementById('workspace').style.width='500px'},
 wide:()=>{document.getElementById('workspace').style.width='1200px'},
 nativeFlush:()=>window.__bandalFlushNative()
};
window.workspaceFixture=fixture;installNativeLifecycle();
(async()=>{
 await ensureSettingsLoaded();useWorkspaceStore.getState().setActiveCourse(courseId);
 createRoot(document.getElementById('root')).render(<div id="workspace" style={{width:1200,height:800}}><DockviewReact components={{pdf:body,note:body}} onReady={event=>{
  api=event.api;
  let scheduled=false;api.onDidLayoutChange(()=>{if(scheduled)return;scheduled=true;requestAnimationFrame(()=>{scheduled=false;useWorkspaceStore.getState().notifyLayoutChanged()})});
  useWorkspaceStore.getState().attachApi(api);bindIpadWorkspace(api,document.getElementById('workspace'));
 }}/></div>);
 for(let i=0;i<100&&(!api||useWorkspaceStore.getState().hydration!=='ready');i++)await nextFrame();
 if(!api||useWorkspaceStore.getState().hydration!=='ready')throw new Error('Workspace hydration failed');
 fixture.ready=true;
})();
` }, bundle: true, write: false, format: 'iife', platform: 'browser', jsx: 'automatic',
  define: { 'process.env.NODE_ENV': '"test"' }, loader: { '.css': 'empty' }, plugins: [{ name: 'ipad-input-fixture', setup(builder) {
    builder.onLoad({ filter: /\.(ts|tsx)$/ }, async ({ path }) => {
      const original = await readFile(path, 'utf8'), transformed = adaptInputSource(original, path)
      return transformed ? { contents: transformed.code, loader: path.endsWith('.tsx') ? 'tsx' : 'ts' } : undefined
    })
  } }] })
const browser = await webkit.launch()
try {
  const page = await browser.newPage(), errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.route('https://ipad-workspace.test/', route => route.fulfill({ contentType: 'text/html', body: '<div id="root"></div>' }))
  const start = async () => { await page.addScriptTag({ content: built.outputFiles[0].text }); await page.waitForFunction(() => window.workspaceFixture?.ready) }
  await page.goto('https://ipad-workspace.test/'); await start()
  await page.evaluate(() => window.workspaceFixture.create())
  await page.waitForFunction(() => { const f=window.workspaceFixture;return f.activeIn(f.saved())===f.ids.note })
  const baseline = await page.evaluate(() => window.workspaceFixture.calls.length)
  await page.evaluate(() => { const f=window.workspaceFixture;f.select(f.ids.pdf) })
  await page.waitForFunction(() => { const f=window.workspaceFixture;return f.activeIn(f.saved())===f.ids.pdf })
  assert.ok(await page.evaluate(count => window.workspaceFixture.calls.length > count, baseline), 'A focus-only change starts the existing save debounce')
  await page.reload(); await start() // No beforeunload handler or manual flush.
  assert.equal(await page.evaluate(() => window.workspaceFixture.state().active), await page.evaluate(() => window.workspaceFixture.ids.pdf))

  // The actual native lifecycle must wait for both an old IPC and the new
  // selection queued while that IPC is in flight, even before the 1s debounce.
  await page.evaluate(() => {
    const f=window.workspaceFixture;f.defer(true);f.select(f.ids.note)
    window.nativeFlushResult=null;void f.nativeFlush().then(value=>{window.nativeFlushResult=value})
  })
  await page.waitForFunction(() => window.workspaceFixture.acks.length===1)
  assert.equal(await page.evaluate(() => window.nativeFlushResult), null)
  await page.evaluate(() => { const f=window.workspaceFixture;f.select(f.ids.pdf) })
  await page.waitForFunction(() => window.workspaceFixture.state().store===window.workspaceFixture.ids.pdf)
  // Allow WorkspaceHost's same animation-frame relay to replace the pending snapshot.
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  await page.evaluate(() => window.workspaceFixture.ack())
  await page.waitForFunction(() => window.workspaceFixture.acks.length===1)
  assert.equal(await page.evaluate(() => window.nativeFlushResult), null, 'An older layout ACK cannot release the native lifecycle barrier')
  await page.evaluate(() => { const f=window.workspaceFixture;f.defer(false);f.ack() })
  await page.waitForFunction(() => window.nativeFlushResult!==null)
  assert.equal(await page.evaluate(() => window.nativeFlushResult.ok), true)
  assert.equal(await page.evaluate(() => { const f=window.workspaceFixture;return f.activeIn(f.saved()) }), await page.evaluate(() => window.workspaceFixture.ids.pdf))

  // Exhausted canonical retries reject recovery; a subsequent lifecycle flush
  // retries the retained layout through that same queue.
  await page.evaluate(() => { const f=window.workspaceFixture;f.fail(true);f.select(f.ids.note) })
  assert.equal(await page.evaluate(() => window.workspaceFixture.nativeFlush().then(report=>report.ok)), false)
  await page.evaluate(() => window.workspaceFixture.fail(false))
  assert.equal(await page.evaluate(() => window.workspaceFixture.nativeFlush().then(report=>report.ok)), true)

  // Responsive maximization is temporary; its original two-group tree and
  // latest focused PDF must survive the same persisted snapshot and restore.
  await page.evaluate(() => { const f=window.workspaceFixture;f.split();f.compact() })
  await page.waitForFunction(() => window.workspaceFixture.state().maximized)
  await page.evaluate(() => { const f=window.workspaceFixture;f.select(f.ids.pdf) })
  assert.equal(await page.evaluate(() => window.workspaceFixture.flush()), true)
  assert.equal(await page.evaluate(() => window.workspaceFixture.saved().grid.maximizedNode), undefined)
  await page.reload(); await start()
  const restored = await page.evaluate(() => window.workspaceFixture.state())
  assert.equal(restored.groups, 2);assert.equal(restored.maximized, false)
  assert.equal(restored.active, await page.evaluate(() => window.workspaceFixture.ids.pdf))
  assert.deepEqual(errors, [])
  console.log('PASS real Dockview iPad focus-only save/cold restore, native lifecycle latest-ACK barrier and retry, compact split restore without temporary maximization')
} finally { await browser.close() }
