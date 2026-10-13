/** Actual desktop workspace store, descriptor validator and Dockview restore.
 * Tab contents are inert boundaries: this does not test PDF/WebKit/audio
 * engines, OS memory pressure, or real learning-file persistence. */
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { dependencies, runtime } from './dependencies.mjs'
const { require }=dependencies(),{build}=createRequire(require.resolve('vite'))('esbuild')
const {webkit}=require('@playwright/test')
const built=await build({stdin:{resolveDir:runtime,loader:'tsx',contents:`
import React from 'react';import {createRoot} from 'react-dom/client';import {DockviewReact} from 'dockview';
import {useWorkspaceStore} from './upstream/src/renderer/src/stores/workspaceStore';
import {descriptorFor,tabPanelId,isTabDescriptor} from './upstream/src/renderer/src/features/workspace/tabIdentity';
import {validateLayout} from './upstream/src/renderer/src/features/workspace/layoutPersistence';
import {setIpcAdapter} from './upstream/src/renderer/src/lib/ipc';
import {DEFAULT_SETTINGS} from './upstream/src/shared/types/settings';
import {ensureSettingsLoaded} from './upstream/src/renderer/src/stores/settingsSnapshot';
const courseId='00000000-0000-4000-8000-000000000001';
const key='mixed-layout-fixture:'+courseId;const calls=[];let api;
setIpcAdapter({on:()=>()=>{},invoke:async(channel,request)=>{
 calls.push({channel,request});
 if(channel==='settings:get')return structuredClone(DEFAULT_SETTINGS);
 if(channel==='layout:get')return {layout:JSON.parse(localStorage.getItem('mixed-layout-fixture:'+request.courseId)||'null')};
 if(channel==='layout:save'){localStorage.setItem('mixed-layout-fixture:'+request.courseId,JSON.stringify(request.layout));return {ok:true}}
 if(channel==='layout:saveMany'){for(const item of request.layouts)localStorage.setItem('mixed-layout-fixture:'+item.courseId,JSON.stringify(item.layout));return {ok:true}}
 throw new Error('Unexpected mixed workspace boundary: '+channel);
}});
const body=({params})=><div data-kind={params.descriptor.kind}>{params.descriptor.kind}</div>;
const components={pdf:body,note:body,browser:body,whiteboard:body,recording:body,board:body};
const nextFrame=()=>new Promise(resolve=>requestAnimationFrame(resolve));
const snapshot=()=>({activePanel:api.activePanel?.id,activeGroup:api.activeGroup?.id,
 groups:api.groups.map(group=>({id:group.id,active:group.activePanel?.id,panels:group.panels.map(panel=>panel.id)})),
 panels:api.panels.map(panel=>({id:panel.id,title:panel.title,descriptor:panel.params.descriptor})).sort((a,b)=>a.id.localeCompare(b.id)),
 selectedInStore:useWorkspaceStore.getState().activePanelId,hydration:useWorkspaceStore.getState().hydration});
window.runMixedWorkspace=async(phase)=>{
 await ensureSettingsLoaded();useWorkspaceStore.getState().setActiveCourse(courseId);
 createRoot(document.getElementById('root')).render(<div style={{width:1200,height:800}}><DockviewReact components={components} onReady={event=>{
 api=event.api;api.onDidLayoutChange(()=>useWorkspaceStore.getState().notifyLayoutChanged());useWorkspaceStore.getState().attachApi(api);
 }}/></div>);
 for(let i=0;i<100&&(!api||useWorkspaceStore.getState().hydration!=='ready');i++)await nextFrame();
 if(!api||useWorkspaceStore.getState().hydration!=='ready')throw new Error('Real Dockview hydration did not finish');
 if(phase==='create'){
 const descriptors=[
  ...Array.from({length:5},(_,i)=>descriptorFor('pdf',{courseId,relPath:'lectures/unit-'+i+'.pdf'})),
  ...Array.from({length:5},(_,i)=>descriptorFor('note',{courseId,relPath:'notes/unit-'+i+'.md'})),
  ...Array.from({length:4},(_,i)=>descriptorFor('browser',{tabId:crypto.randomUUID(),profileId:'default',initialUrl:'https://example.test/course/'+i})),
  ...Array.from({length:3},()=>descriptorFor('whiteboard',{courseId,boardId:crypto.randomUUID()})),
  ...Array.from({length:2},(_,i)=>descriptorFor('recording',{courseId,sessionId:crypto.randomUUID(),title:'강의 녹음 '+i})),
  descriptorFor('board',{})];
 if(!descriptors.every(isTabDescriptor))throw new Error('The original tab contract rejects a descriptor');
 descriptors.forEach((descriptor,index)=>useWorkspaceStore.getState().openTab(descriptor,index===10?{beside:true}:undefined));
 const target=descriptors[12];useWorkspaceStore.getState().activatePanel(tabPanelId(target));
 // Remember the real browser navigation in the original retained layout path.
 useWorkspaceStore.getState().rememberDetachedBrowserPage(target.payload.tabId,'https://example.test/lesson/restored','Restored browser');
 const live=api.getPanel(tabPanelId(target));
 live.api.updateParameters({descriptor:{...target,payload:{...target.payload,initialUrl:'https://example.test/lesson/restored'}}});
 live.api.setTitle('Restored browser');
 useWorkspaceStore.getState().notifyLayoutChanged();useWorkspaceStore.getState().flushPendingSave();await nextFrame();
 const persisted=JSON.parse(localStorage.getItem(key)||'null'),validated=validateLayout(persisted);
 if(!validated||validated.droppedPanelIds.length||Object.keys(validated.tabs).length!==20)throw new Error('Original persistent layout did not retain all 20 valid mixed descriptors');
 return {state:snapshot(),persisted,channels:calls.map(call=>call.channel)};
 }
 return {state:snapshot(),persisted:JSON.parse(localStorage.getItem(key)||'null'),channels:calls.map(call=>call.channel)};
};
`},bundle:true,write:false,format:'iife',platform:'browser',jsx:'automatic',define:{'process.env.NODE_ENV':'"test"'},loader:{'.css':'empty'}})
const browser=await webkit.launch()
try{
 const page=await browser.newPage(),errors=[];page.on('pageerror',error=>errors.push(error.message))
 await page.route('https://mixed-workspace.test/',route=>route.fulfill({status:200,contentType:'text/html',body:'<div id="root"></div>'}))
 await page.goto('https://mixed-workspace.test/');await page.addScriptTag({content:built.outputFiles[0].text})
 const before=await page.evaluate(()=>window.runMixedWorkspace('create'))
 assert.equal(before.state.panels.length,20);assert.equal(before.state.groups.length,2)
 assert.deepEqual([...new Set(before.state.panels.map(panel=>panel.descriptor.kind))].sort(),['board','browser','note','pdf','recording','whiteboard'])
 assert.equal(before.state.selectedInStore,before.state.activePanel)
 assert.ok(before.channels.includes('layout:save'))
 await page.reload();await page.addScriptTag({content:built.outputFiles[0].text})
 const after=await page.evaluate(()=>window.runMixedWorkspace('restore'))
 assert.ok(after.channels.includes('layout:get'),'A fresh renderer must hydrate the persisted layout, not its old in-memory cache')
 assert.deepEqual(after.state,before.state,'Panel identity, payload, title, group order, split groups and selected tab must survive real Dockview fromJSON hydration')
 assert.deepEqual(after.persisted,before.persisted)
 assert.equal(after.state.panels.find(panel=>panel.id===after.state.activePanel).descriptor.payload.initialUrl,'https://example.test/lesson/restored')
 assert.deepEqual(errors,[])
 console.log('PASS real Dockview/store: 20 valid mixed PDF/note/browser/whiteboard/recording/board descriptors, two groups, active tab, title and browser URL survive fresh-renderer saved-layout hydration (content engines and physical memory pressure are outside this test)')
}finally{await browser.close()}
