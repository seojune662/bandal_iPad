import { env } from '../native'
export const homedir = (): string => env().homePath
export const tmpdir = (): string => env().tempPath
