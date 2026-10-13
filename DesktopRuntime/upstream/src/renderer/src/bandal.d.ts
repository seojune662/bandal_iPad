/**
 * Global typing for the preload bridge exposed as `window.bandal`.
 */

import type { IpcChannel, IpcRequest, IpcResponse } from '../../shared/ipc/contract'
import type { PushChannel, PushPayload } from '../../shared/ipc/events'

declare global {
  interface Window {
    bandal: {
      invoke<K extends IpcChannel>(
        channel: K,
        req: IpcRequest<K>
      ): Promise<IpcResponse<K>>
      on<K extends PushChannel>(
        channel: K,
        cb: (payload: PushPayload<K>) => void
      ): () => void
      /** [M5] Absolute path of a dropped File ('' when unavailable). */
      pathForFile(file: File): string
      /** 자료 행 드래그를 OS 네이티브 파일 드래그로 승격(발사 후 망각). */
      startMaterialDrag(courseId: string, relPath: string): void
      /** [M9] 'darwin' | 'win32' | 'linux' — drives the traffic-light inset. */
      readonly platform: string
      readonly browserAuthProbe?: 'product' | 'clean'
      /** Temporary M0 helper — opens the settings window. */
      openSettings(): Promise<void>
    }
  }
}

export {}
