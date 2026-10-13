export function macPanelOptions(): { type?: 'panel'; hiddenInMissionControl?: boolean } {
  return process.platform === 'darwin' ? { type: 'panel', hiddenInMissionControl: true } : {}
}
