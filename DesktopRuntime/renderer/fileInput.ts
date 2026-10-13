/** Stage browser File bytes before the desktop's synchronous pathForFile call. */
export function installFileInputAdapter(onFailure: (error: unknown) => void): void {
  const replayed = new WeakSet<Event>()
  const selections = new WeakMap<HTMLInputElement, symbol>()
  const paths = window.__bandalFilePaths
  if (!paths) throw new Error('Native file paths are not initialized')

  const invoke = (channel: string, request: Record<string, unknown>) => window.webkit!.messageHandlers!.bandal!.postMessage({ channel, request }) as Promise<Record<string, unknown>>
  class StaleSelection extends Error {}
  async function stage(files: File[], current: () => boolean): Promise<{ paths: string[]; cancel: () => Promise<void> }> {
    const ids: string[] = [], staged: string[] = []
    const check = () => { if (!current()) throw new StaleSelection() }
    const cancel = async () => { for (const id of ids) await invoke('runtime:stageFileCancel', { id }).catch(onFailure) }
    try {
      for (const file of files) {
        check()
        const begin = await invoke('runtime:stageFileBegin', { name: file.name, size: file.size })
        if (typeof begin.id !== 'string' || !begin.id) throw new Error('파일 가져오기 작업을 시작하지 못했습니다.')
        const id = begin.id; ids.push(id)
        for (let offset = 0; offset < file.size;) {
          check()
          const bytes = new Uint8Array(await file.slice(offset, offset + 256 * 1024).arrayBuffer())
          if (bytes.length !== Math.min(256 * 1024, file.size - offset)) throw new Error('파일 조각을 끝까지 읽지 못했습니다.')
          check()
          const parts: string[] = []
          for (let part = 0; part < bytes.length; part += 32768) parts.push(String.fromCharCode(...bytes.subarray(part, part + 32768)))
          const written = await invoke('runtime:stageFileWrite', { id, offset, data: btoa(parts.join('')) })
          offset += bytes.length
          if (written.offset !== offset) throw new Error('파일 조각의 저장 위치가 일치하지 않습니다.')
        }
        check()
        const reply = await invoke('runtime:stageFileFinish', { id })
        if (typeof reply.path !== 'string' || !reply.path) throw new Error(`${file.name}: 가져온 파일의 위치를 확인하지 못했습니다.`)
        staged.push(reply.path)
      }
      check()
      return { paths: staged, cancel }
    } catch (error) { await cancel(); throw error }
  }

  window.addEventListener('change', event => {
    const target = event.target
    if (replayed.has(event) || !(target instanceof HTMLInputElement) || target.type !== 'file') return
    const files = Array.from(target.files ?? [])
    const selection = Symbol(); selections.set(target, selection)
    if (!files.length) return
    event.stopImmediatePropagation()
    void (async () => {
      const current = () => selections.get(target) === selection && target.isConnected && Array.from(target.files ?? []).every((file, index) => file === files[index]) && target.files?.length === files.length
      const staged = await stage(files, current)
      if (!current()) { await staged.cancel(); return }
      files.forEach((file, index) => paths.set(file, staged.paths[index]!))
      const replay = new Event('change', { bubbles: true, cancelable: true, composed: true })
      replayed.add(replay)
      target.dispatchEvent(replay)
    })().catch(error => { if (!(error instanceof StaleSelection)) onFailure(error) })
  }, true)

  window.addEventListener('drop', event => {
    if (replayed.has(event) || !event.dataTransfer) return
    const files = Array.from(event.dataTransfer.files)
    if (!files.length) return
    const target = event.target
    if (!(target instanceof Node)) return
    event.preventDefault()
    event.stopImmediatePropagation()
    // Preserve protected drag data synchronously; it may be emptied after await.
    const transfer = new DataTransfer()
    for (const type of event.dataTransfer.types) {
      if (type !== 'Files') transfer.setData(type, event.dataTransfer.getData(type))
    }
    for (const file of files) transfer.items.add(file)
    transfer.dropEffect = event.dataTransfer.dropEffect
    transfer.effectAllowed = event.dataTransfer.effectAllowed
    const coordinates = { clientX: event.clientX, clientY: event.clientY, screenX: event.screenX, screenY: event.screenY, ctrlKey: event.ctrlKey, shiftKey: event.shiftKey, altKey: event.altKey, metaKey: event.metaKey, button: event.button, buttons: event.buttons }
    void (async () => {
      const staged = await stage(files, () => target.isConnected)
      if (!target.isConnected) { await staged.cancel(); return }
      Array.from(transfer.files).forEach((file, index) => paths.set(file, staged.paths[index]!))
      const replay = new DragEvent('drop', { ...coordinates, dataTransfer: transfer, bubbles: true, cancelable: true, composed: true })
      replayed.add(replay)
      target.dispatchEvent(replay)
    })().catch(error => { if (!(error instanceof StaleSelection)) onFailure(error) })
  }, true)
}
