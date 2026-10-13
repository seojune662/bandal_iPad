/** PDF 마지막 열람 위치 — 로컬 SQLite 파생 뷰 상태 (Supabase 아님). */
export interface PdfViewState {
  courseId: string
  relPath: string
  /** 1-based 페이지 (뷰포트 중앙 기준). */
  page: number
  zoom: number
  updatedAt: string
}
