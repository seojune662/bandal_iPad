import type { StudyMarketPreparedBundle, StudyMarketPreview, StudyMarketPreviewInput, StudyMarketRequest, StudyMarketListing } from '../types/studyMarket'
export interface StudyMarketIpcContract {
  'studyMarket:request': { req: StudyMarketRequest; res: unknown };
  'studyMarket:prepare': { req: { courseId: string; relPaths: string[] }; res: StudyMarketPreparedBundle };
  'studyMarket:previewSource': { req: { bundleId: string; fileId: string; page?: number; text?: string }; res: { mime: string; base64?: string; text?: string } };
  'studyMarket:pickPreviewImage': { req: Record<string, never>; res: { dataUrl: string } | null };
  'studyMarket:preview': { req: StudyMarketPreviewInput; res: StudyMarketPreview };
  'studyMarket:upload': { req: { bundleId: string; versionId: string; fileIds: string[]; publish?: boolean }; res: StudyMarketListing };
  'studyMarket:import': { req: { orderId: string; courseId?: string; acceptSupply: boolean }; res: { courseId: string; relPath: string } };
  'studyMarket:discardPreview': { req: { bundleId: string; fileId: string }; res: { ok: true } };
  'studyMarket:discardBundle': { req: { bundleId: string }; res: { ok: true } };
  'studyMarket:openCheckout': { req: { orderId: string }; res: { ok: true } };
}
export const STUDY_MARKET_CHANNELS = ['studyMarket:request', 'studyMarket:prepare', 'studyMarket:previewSource', 'studyMarket:pickPreviewImage', 'studyMarket:preview', 'studyMarket:upload', 'studyMarket:import', 'studyMarket:discardPreview', 'studyMarket:discardBundle', 'studyMarket:openCheckout'] as const satisfies readonly (keyof StudyMarketIpcContract)[]
