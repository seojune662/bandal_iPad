import { rename } from 'node:fs/promises'
import { retryWindowsFileOperation } from '../../lib/retryWindowsFileOperation'

interface RenameRetryOptions {
  platform?: NodeJS.Platform
  rename?: typeof rename
  wait?: (milliseconds: number) => Promise<void>
}

/** Windows can briefly refuse a rename while a scanner holds a directory handle. */
export async function renameWithRetry(
  sourcePath: string,
  destinationPath: string,
  beforeAttempt: () => void | Promise<void>,
  options: RenameRetryOptions = {}
): Promise<void> {
  const operation = options.rename ?? rename
  // An external change during the wait must not bypass path/collision guards.
  return retryWindowsFileOperation(() => operation(sourcePath, destinationPath), {
    ...options,
    beforeAttempt
  })
}
