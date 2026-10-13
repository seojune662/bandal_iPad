import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'
const { require } = dependencies(), { build } = createRequire(require.resolve('vite'))('esbuild')
const { webkit } = require('@playwright/test')
const built=await build({stdin:{resolveDir:runtime,loader:'tsx',contents:"import {runNativeHistoryFixture} from './renderer/nativePDF/history-fixture';window.runNativeHistoryFixture=runNativeHistoryFixture"},bundle:true,write:false,format:'iife',platform:'browser',jsx:'automatic',define:{'process.env.NODE_ENV':'"test"'}})
const browser=await webkit.launch()
try{
 const page=await browser.newPage(),errors=[];page.on('pageerror',error=>errors.push(error.message))
 await page.route('https://native-history.test/',route=>route.fulfill({status:200,contentType:'text/html',body:'<main></main>'}))
 await page.goto('https://native-history.test/')
 await page.addScriptTag({content:built.outputFiles[0].text})
 for(const pass of await page.evaluate(()=>window.runNativeHistoryFixture()))console.log('PASS '+pass)
 assert.deepEqual(errors,[])
}finally{await browser.close()}
