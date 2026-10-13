import * as fs from './fs'
import { randomBytes } from './crypto'
export const copyFile = async (from:string,to:string,mode?:number):Promise<void>=>fs.copyFileSync(from,to,mode)
export const mkdtemp=async(prefix:string):Promise<string>=>{for(let i=0;i<10;i++){const path=prefix+randomBytes(6).toString('hex');try{fs.mkdirSync(path);return path}catch(error){if((error as any).code!=='EEXIST')throw error}}throw new Error('Unable to create temporary directory')}
export const readFile = async (path: string, options?: any): Promise<any> => fs.readFileSync(path, options)
export const writeFile = async (path: string, data: any, options?: any): Promise<void> => fs.writeFileSync(path, data, options)
export const mkdir = async (path: string, options?: any): Promise<void> => fs.mkdirSync(path, options)
export const readdir = async (path: string, options?: any): Promise<any[]> => fs.readdirSync(path, options)
export const rename = async (from: string, to: string): Promise<void> => fs.renameSync(from, to)
export const rm = async (path: string, options?: any): Promise<void> => fs.rmSync(path, options)
export const unlink = async (path: string): Promise<void> => fs.unlinkSync(path)
export const stat = async (path: string, options?: any): Promise<any> => fs.statSync(path, options)
export const lstat = async (path: string, options?: any): Promise<any> => fs.lstatSync(path, options)
export const realpath = async (path: string): Promise<string> => fs.realpathSync(path)
export async function opendir(path: string): Promise<any> {
  const values = fs.readdirSync(path, { withFileTypes: true }); let index = 0, closed = false
  return { read: async () => { if (closed) throw new Error('Directory closed'); return values[index++] ?? null }, close: async () => { closed = true } }
}
export async function open(path: string, flags: string | number, mode?: number): Promise<any> {
  const fd = fs.openSync(path, flags, mode); let closed = false
  const check=()=>{if(closed)throw new Error('File closed')}
  return { fd, writeFile: async (value: any, encoding?: string) => { check(); fs.writeFileSync(fd, value, encoding) },
    stat:async(options?:any)=>{check();return fs.fstatSync(fd,options)},
    read:async(buffer:Uint8Array,offset=0,length=buffer.length-offset,position:number|null=null)=>{check();return{bytesRead:fs.readSync(fd,buffer,offset,length,position),buffer}},
    createReadStream:(options:any={})=>{check();const stream=fs.createReadStream(path,{...options,fd});if(options.autoClose!==false){const original=stream[Symbol.asyncIterator].bind(stream);stream[Symbol.asyncIterator]=async function*(){try{yield*original()}finally{closed=true}}}return stream},
    sync: async () => { if (closed) throw new Error('File closed'); fs.fsyncSync(fd) },
    close: async () => { if (!closed) { closed = true; fs.closeSync(fd) } } }
}
