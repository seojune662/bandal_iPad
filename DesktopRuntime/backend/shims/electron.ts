import { emit, env, native } from '../native'
import { Buffer } from './buffer'
export const app = {
  getPath(name: string): string { const environment = env(); if (name === 'userData') return environment.userDataPath; if (name === 'home') return environment.homePath; if (name === 'temp') return environment.tempPath; throw new Error(`Unsupported app path: ${name}`) },
  getVersion(): string { return env().version ?? '1.0.0' }
}
export const BrowserWindow = { getAllWindows: () => [{ isDestroyed: () => false, webContents: { send: emit } }] }
export const nativeImage = { createFromBuffer(bytes: Uint8Array) {
  let png: Buffer | undefined
  const converted = () => png ??= Buffer.from(native('image.png', { data: Buffer.from(bytes).toString('base64') }), 'base64')
  return { isEmpty: () => converted().length === 0, toPNG: converted }
} }
