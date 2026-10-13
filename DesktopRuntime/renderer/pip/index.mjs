export default function nativeMiniPlayerPlugin() {
  return { name: 'ipad-mini-player-source-identity', enforce: 'pre', transform(source, id) {
    if (!id.endsWith('/renderer/src/features/browser/videoBridge.ts')) return null
    const anchor = "      kind: 'web',\n"
    if (source.split(anchor).length !== 2) throw new Error('Original web PiP source identity anchor changed')
    return { code: source.replace(anchor, anchor + '      nativeTabId: tabId,\n'), map: null }
  } }
}
