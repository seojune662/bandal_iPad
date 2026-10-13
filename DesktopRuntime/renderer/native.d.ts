interface Window {
  webkit?: { messageHandlers?: { bandal?: { postMessage(message: { channel: string; request: unknown }): Promise<unknown> } } }
  __bandalFilePaths?: WeakMap<File, string>
}
