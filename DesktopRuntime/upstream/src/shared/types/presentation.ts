import type { MaterialFileContent } from './materials'
export interface PresentationRef { courseId: string; relPath: string }
export interface ConversionRuntimeState {
  status: 'missing' | 'downloading' | 'installing' | 'ready' | 'unsupported' | 'error'
  version: string
  receivedBytes: number
  totalBytes: number
  message: string | null
}
export interface PresentationTextRun { text: string; x: number; y: number; width: number; height: number; fontSize: number; rotation: number }
export interface PresentationPdfPage {
  sessionId: string; index: number; width: number; height: number; pngBase64: string; text: PresentationTextRun[]
}
export interface PresentationIpcContract {
  'presentation:runtime': { req: Record<string, never>; res: ConversionRuntimeState }
  'presentation:installRuntime': { req: Record<string, never>; res: ConversionRuntimeState }
  'presentation:cancelRuntime': { req: Record<string, never>; res: { ok: true } }
  'presentation:prepare': { req: PresentationRef & { requestId: string }; res: MaterialFileContent }
  'presentation:cancelPrepare': { req: { requestId: string }; res: { ok: true } }
  'presentation:pdfStart': { req: PresentationRef & { pageCount: number; includeInk: boolean }; res: { sessionId: string } }
  'presentation:pdfPage': { req: PresentationPdfPage; res: { ok: true } }
  'presentation:pdfFinish': { req: { sessionId: string }; res: PresentationRef }
  'presentation:pdfCancel': { req: { sessionId: string }; res: { ok: true } }
}
