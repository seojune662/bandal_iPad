import { fileURLToPath } from 'node:url'
const adapter = fileURLToPath(new URL('./nativeSurfaces.ts', import.meta.url))
export function adaptNativeSurfacesSource(source, id) {
  if (!id.endsWith('/renderer/src/features/browser/nativeHostVisibility.ts')) return null
  if (!source.includes('export function setNativeHostBlocked(')) throw new Error('Native host visibility adapter anchor changed')
  return { code: `export { isNativeHostBlocked, onNativeHostBlocked, setNativeHostBlocked } from ${JSON.stringify(adapter)}\n`, map: null }
}
export default function nativeSurfacesPlugin() {
  return { name: 'bandal-ipad-native-surfaces', enforce: 'pre', transform: adaptNativeSurfacesSource }
}
