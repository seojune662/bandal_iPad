import { setTimeout } from 'node:timers/promises'

const RETRY_DELAYS_MS = [50, 100, 200, 400, 800] as const

export interface WindowsFileRetryOptions {
  platform?: NodeJS.Platform
  wait?: (milliseconds: number) => Promise<void>
  beforeAttempt?: () => void | Promise<void>
  /** Transactions may retry only after fully restoring their original state. */
  shouldRetry?: (error: unknown) => boolean
}

/** Yield only for Windows EPERM/EBUSY; EACCES and missing paths fail immediately. */
export async function retryWindowsFileOperation<T>(
  operation: () => T | Promise<T>,
  options: WindowsFileRetryOptions = {}
): Promise<T> {
  const wait = options.wait ?? ((milliseconds: number) => setTimeout(milliseconds))
  const windows = (options.platform ?? process.platform) === 'win32'
  for (let attempt = 0; ; attempt += 1) {
    if (options.beforeAttempt !== undefined) await options.beforeAttempt()
    try {
      return await operation()
    } catch (error) {
      const code = (error as NodeJS.ErrnoException | null)?.code
      const delay = RETRY_DELAYS_MS[attempt]
      if (
        !windows || (code !== 'EPERM' && code !== 'EBUSY') || delay === undefined ||
        options.shouldRetry?.(error) === false
      ) throw error
      await wait(delay)
    }
  }
}
