import { env } from '../native'
import { join } from '../shims/path'
export const nativeFontPath=(file:string)=>join((env() as any).pdfFontPath??join(env().userDataPath,'PDF','fonts'),file)
