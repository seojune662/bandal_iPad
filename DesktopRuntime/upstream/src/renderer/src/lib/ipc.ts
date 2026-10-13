/**
 * Typed IPC client for renderer code. Always import from here rather than
 * touching `window.bandal` directly — this is the single seam for mocking
 * in tests.
 */

import type { IpcChannel, IpcRequest, IpcResponse } from '../../../shared/ipc/contract'
import type { PushChannel, PushPayload } from '../../../shared/ipc/events'

export type Unsubscribe = () => void

/**
 * [P2-D] The seam a fake transport plugs into.
 *
 * P2-D is built against a scripted mock so the group UI is fully exercisable
 * without a Supabase session or a signed-in account. Injecting at THIS level
 * — rather than mocking each hook — means the components, the reducer and the
 * seq/batch plumbing under test are byte-for-byte the ones that ship
 * (docs/phase2-community.md §7 P2-D).
 */
export interface IpcAdapter {
  invoke<K extends IpcChannel>(
    channel: K,
    req: IpcRequest<K>
  ): Promise<IpcResponse<K>>
  on<K extends PushChannel>(
    channel: K,
    cb: (payload: PushPayload<K>) => void
  ): Unsubscribe
}

let adapter: IpcAdapter | null = null

/** Installs (or with `null`, removes) a transport override. Dev/test only. */
export function setIpcAdapter(next: IpcAdapter | null): void {
  adapter = next
}

export function invoke<K extends IpcChannel>(
  channel: K,
  req: IpcRequest<K>
): Promise<IpcResponse<K>> {
  return adapter === null
    ? window.bandal.invoke(channel, req)
    : adapter.invoke(channel, req)
}

export function onPush<K extends PushChannel>(
  channel: K,
  cb: (payload: PushPayload<K>) => void
): Unsubscribe {
  return adapter === null ? window.bandal.on(channel, cb) : adapter.on(channel, cb)
}

/**
 * [M5] Absolute filesystem path of a dropped File (Finder drag & drop).
 * Empty string when the File has no backing path.
 */
export function pathForFile(file: File): string {
  return window.bandal.pathForFile(file)
}

/** 자료 행 드래그를 OS 네이티브 파일 드래그로 승격한다(발사 후 망각). */
export function startMaterialDrag(courseId: string, relPath: string): void {
  window.bandal.startMaterialDrag(courseId, relPath)
}
