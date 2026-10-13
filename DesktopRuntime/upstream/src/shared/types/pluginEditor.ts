export interface PluginEditorRequest {
  requestId: string
  pluginId: string
  action: 'getSelection' | 'replaceSelection'
  token?: string
  text?: string
}

export interface PluginEditorSelection {
  token: string
  courseId: string
  relPath: string
  text: string
  from: number
  to: number
}
