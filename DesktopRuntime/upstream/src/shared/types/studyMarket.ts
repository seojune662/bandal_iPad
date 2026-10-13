/** Study materials commerce. Distinct from the plugin marketplace. */
export const STUDY_MARKET_LIMITS = { fileBytes: 50 * 1024 * 1024, bundleBytes: 200 * 1024 * 1024, files: 100, previews: 3 } as const
export const STUDY_MARKET_EXTENSIONS = ['pdf', 'md', 'txt', 'png', 'jpg', 'jpeg', 'webp', 'docx', 'pptx', 'xlsx'] as const
export interface StudyMarketUniversity { id: string; name: string }
export interface StudyMarketCourse { id: string; universityId: string; name: string }
export interface StudyMarketFile { id: string; path: string; bytes: number; sha256: string; mime: string; preview?: boolean }
export interface StudyMarketPreparedBundle { id: string; courseId: string; files: StudyMarketFile[]; warnings: string[]; totalBytes: number }
export interface StudyMarketPreviewInput { bundleId: string; fileId: string; page?: number; text?: string; dataUrl?: string }
export interface StudyMarketPreview { file: StudyMarketFile; dataUrl: string }
export interface StudyMarketListing {
  id: string; versionId: string; universityId: string; course: StudyMarketCourse;
  sellerId: string; sellerName: string; title: string; description: string;
  price: number; professor: string; semester: string;
  status: 'draft' | 'sealing' | 'published' | 'withdrawn' | 'blocked';
  files: StudyMarketFile[]; previewUrls: string[]; createdAt: string; updatedAt: string;
  owned?: boolean;
}
export interface StudyMarketDraftInput {
  id?: string; universityId: string; courseId: string; title: string; description: string;
  price: number; professor: string; semester: string; files: StudyMarketFile[]; rightsConfirmed: boolean;
}
export interface StudyMarketOrder {
  id: string; listingId: string; versionId: string; title: string; courseName: string;
  amount: number; fee: number; sellerAmount: number;
  status: 'pending' | 'paid' | 'refund_pending' | 'refunded' | 'failed' | 'cancelled';
  createdAt: string; paidAt: string | null; supplyStartedAt: string | null;
  receiptUrl: string | null; checkoutUrl?: string; refundReason?: string;
}
export interface StudyMarketSeller {
  status: 'unregistered' | 'pending' | 'ready' | 'verification_required' | 'suspended';
  displayName: string; bankLast4?: string; reason?: string;
}
export interface StudyMarketPayout {
  id: string; amount: number; status: 'pending' | 'reserved' | 'paid' | 'failed' | 'held';
  scheduledAt: string | null; paidAt: string | null; reason: string;
}
export interface StudyMarketDashboard {
  configured: boolean; tradingEnabled: boolean; signedIn: boolean; operator: boolean;
  seller: StudyMarketSeller; listings: StudyMarketListing[]; purchases: StudyMarketOrder[];
  payouts: StudyMarketPayout[]; salesCount: number; pendingAmount: number; paidAmount: number;
  notice: string;
}
export interface StudyMarketDownload {
  orderId: string; title: string; courseName: string;
  files: Array<StudyMarketFile & { url: string }>;
}
export interface StudyMarketOperatorCase {
  id: string; kind: 'report' | 'refund' | 'payout' | 'receivable' | 'school';
  subjectId: string; reason: string; status: string; createdAt: string; amount?: number;
}
export interface StudyMarketApi {
  context: { req: { universityId?: string }; res: { universities: StudyMarketUniversity[]; tradingEnabled: boolean; notice: string } };
  requestUniversity: { req: { name: string }; res: { ok: true } };
  courses: { req: { universityId: string; q?: string }; res: StudyMarketCourse[] };
  createCourse: { req: { universityId: string; name: string }; res: StudyMarketCourse };
  listings: { req: { universityId: string; q?: string; courseIds?: string[]; sort?: 'newest' | 'price'; cursor?: string }; res: { listings: StudyMarketListing[]; nextCursor: string | null } };
  listing: { req: { id: string }; res: StudyMarketListing };
  dashboard: { req: Record<string, never>; res: StudyMarketDashboard };
  saveDraft: { req: StudyMarketDraftInput; res: StudyMarketListing };
  uploadGrant: { req: { versionId: string; fileId: string }; res: { url: string; token: string; bucket: string; objectPath: string; resumableUrl: string; alreadyVerified?: boolean } };
  finalizeFile: { req: { versionId: string; fileId: string }; res: { ok: true } };
  publish: { req: { versionId: string }; res: StudyMarketListing };
  withdraw: { req: { listingId: string }; res: { ok: true } };
  order: { req: { listingId: string }; res: StudyMarketOrder };
  orderStatus: { req: { orderId: string; refreshCheckout?: boolean }; res: StudyMarketOrder };
  download: { req: { orderId: string; acceptSupply: boolean }; res: StudyMarketDownload };
  downloadComplete: { req: { orderId: string; success: boolean; reason?: string }; res: { ok: true } };
  refund: { req: { orderId: string; reason: string }; res: StudyMarketOrder };
  report: { req: { listingId: string; reason: string }; res: { ok: true } };
  registerSeller: { req: { displayName: string; name: string; email: string; phone: string; bankCode: string; accountNumber: string; holderName: string }; res: StudyMarketSeller };
  operatorDashboard: { req: Record<string, never>; res: { cases: StudyMarketOperatorCase[]; audit: Array<{ id: string; action: string; reason: string; createdAt: string }> } };
  operatorAction: { req: { action: 'block' | 'restore' | 'refund' | 'rejectRefund' | 'holdSeller' | 'releaseSeller' | 'resolveReport' | 'addUniversity'; id: string; reason: string; amount?: number; name?: string }; res: { ok: true } };
}
export type StudyMarketAction = keyof StudyMarketApi
export type StudyMarketRequest = { [K in StudyMarketAction]: { action: K; input: StudyMarketApi[K]['req'] } }[StudyMarketAction]
export const STUDY_MARKET_ACTIONS: readonly StudyMarketAction[] = ['context', 'requestUniversity', 'courses', 'createCourse', 'listings', 'listing', 'dashboard', 'saveDraft', 'uploadGrant', 'finalizeFile', 'publish', 'withdraw', 'order', 'orderStatus', 'download', 'downloadComplete', 'refund', 'report', 'registerSeller', 'operatorDashboard', 'operatorAction']
export function studyMarketFee(amount: number): number { return Math.floor(amount / 10) }
export function normalizeMarketCourseName(value: string): string { return value.normalize('NFC').trim().replace(/\s+/g, ' ').toLocaleLowerCase('ko-KR') }
