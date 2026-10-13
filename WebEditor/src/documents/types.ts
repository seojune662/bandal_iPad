export interface MaterialFileContent { encoding: 'base64' | 'utf8'; data: string }
export interface OfficeDocument { version: 1; materialID: string; fileName: string; extension: string; source: string }
export interface SlideText { text: string; x: number; y: number; width: number; height: number; fontSize: number; rotation: number }
export type OfficeMessage =
  | { version: 1; type: 'ready' }
  | { version: 1; type: 'error'; materialID: string; message: string }
  | { version: 1; type: 'slide'; materialID: string; index: number; count: number; width: number; height: number; png: string; text: SlideText[] }
  | { version: 1; type: 'complete'; materialID: string; count: number }

export async function postOffice(message: OfficeMessage): Promise<void> {
  const handler = (window.webkit?.messageHandlers as unknown as { bandalDocument?: { postMessage: (message: OfficeMessage) => Promise<{ accepted: boolean }> } } | undefined)?.bandalDocument
  if (!handler) throw new Error('문서 뷰어가 앱에 연결되지 않았어요.')
  const result = await handler.postMessage(message)
  if (result.accepted !== true) throw new Error('문서 처리가 중단됐어요.')
}

export function base64(bytes: Uint8Array): string {
  let result = ''
  for (let offset = 0; offset < bytes.length; offset += 32768) result += String.fromCharCode(...bytes.subarray(offset, offset + 32768))
  return btoa(result)
}
