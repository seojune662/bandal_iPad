export type TrayAction = 'open' | 'quit'
export interface TrayMenuItem { id?: TrayAction; label?: string; type?: 'separator' }
export function buildTrayMenu(): TrayMenuItem[] {
  return [{ id: 'open', label: '반달 열기' }, { type: 'separator' }, { id: 'quit', label: '종료' }]
}
