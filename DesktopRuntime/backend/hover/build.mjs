import {createRequire} from 'node:module'
import {fileURLToPath} from 'node:url'
import {dirname,resolve} from 'node:path'
import {readFile,mkdir,writeFile,copyFile} from 'node:fs/promises'
import {createHash} from 'node:crypto'
import {dependencies} from '../../scripts/dependencies.mjs'
const here=dirname(fileURLToPath(import.meta.url)),{require}=dependencies(),esbuild=createRequire(require.resolve('vite'))('esbuild')
const conversion=await readFile(resolve(here,'../../upstream/src/main/features/presentation/conversionRuntime.ts'),'utf8')
const version=/export const OFFICE_RUNTIME_VERSION = '([^']+)'/.exec(conversion)?.[1]
if(!version)throw new Error('Original Office version export changed')
const output=resolve(here,'../dist/hover-worker.js'),buffer=createRequire(require.resolve('exceljs')).resolve('buffer/'),pako=createRequire(require.resolve('jszip')).resolve('pako')
const result=await esbuild.build({entryPoints:[resolve(here,'worker/entry.ts')],outfile:output,bundle:true,format:'iife',platform:'browser',target:'es2020',metafile:true,define:{__BANDAL_OFFICE_RUNTIME_VERSION__:JSON.stringify(version)},plugins:[{name:'snapshot-worker',setup(build){
  build.onLoad({filter:/\/hoverPreviewExtract\.ts$/},async args=>{
    const source=await readFile(args.path,'utf8'),needle="await entry.async('nodebuffer')",workbook="if (ext === '.xlsx') await boundedZip(bytes)"
    if(source.split(needle).length!==2||source.split(workbook).length!==2)throw new Error('Original hover ZIP read boundary changed')
    return{contents:`import {readWorkerZipEntry,validateWorkerWorkbookZip} from ${JSON.stringify(resolve(here,'worker/zip.ts'))};\n`+source.replace(needle,'await readWorkerZipEntry(entry, limit, () => new PreviewLimitError())').replace(workbook,"if (ext === '.xlsx') await validateWorkerWorkbookZip(await boundedZip(bytes), () => new PreviewLimitError())"),loader:'ts',resolveDir:dirname(args.path)}
  })
  build.onResolve({filter:/^node:/},args=>{const file={'node:fs/promises':'worker/files.ts','node:crypto':'worker/files.ts','node:path':'../shims/path.ts','node:zlib':'worker/zlib.ts'}[args.path];if(!file)throw new Error('Unexpected worker Node capability '+args.path);return{path:resolve(here,file)}})
  build.onResolve({filter:/conversionRuntime$/},()=>({path:resolve(here,'worker/version.ts')}))
  build.onResolve({filter:/^(buffer|pako|jszip|xlsx)$/},args=>({path:args.path==='buffer'?buffer:args.path==='pako'?pako:args.path==='jszip'?require.resolve('jszip/dist/jszip.min.js'):resolve(dirname(require.resolve('xlsx')),'xlsx.mjs')}))
}}]})
const destination=resolve(here,'../../../App/Resources/DesktopNative')
const bytes=await readFile(output)
const manifest=JSON.stringify({source:'desktop hoverPreviewExtract/hoverPreviewImage with bounded worker ZIP IO',runtimeVersion:version,byteCount:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex'),modules:Object.keys(result.metafile.inputs).length},null,2)+'\n'
await writeFile(resolve(here,'../dist/hover-worker.manifest.json'),manifest)
if(process.env.BANDAL_SKIP_EMBED!=='1'){
  await mkdir(destination,{recursive:true});await copyFile(output,resolve(destination,'hover-worker.js'))
  await writeFile(resolve(destination,'hover-worker.manifest.json'),manifest)
}
console.log(`Hover parser worker built: ${bytes.length} bytes, ${Object.keys(result.metafile.inputs).length} modules`)
