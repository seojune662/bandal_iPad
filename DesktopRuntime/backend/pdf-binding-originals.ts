import { env, native } from './native'
import { join } from './shims/path'
import { createPDFOriginalPreserver as createPreserver } from '../upstream/src/main/features/pdf/pdfOriginals'

export function createPDFOriginalPreserver(pathFor: (courseId: string, relPath: string) => string) {
  return createPreserver(join(env().userDataPath, 'PDFOriginals'), pathFor, path => native<string>('fs.sha256', { path }))
}
