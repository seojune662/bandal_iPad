import type { MaterialWalk } from '../features/materials/scanMaterialTree'
import type { MaterialsScanLimits } from '../features/materials/materialsRepo'
import type { SearchHit } from '../../shared/types/search'
export interface BackgroundTasks {
  migrate: { input: { dbPath: string }; output: null }
  checkpoint: { input: { dbPath: string }; output: null }
  scan: { input: { folder: string; limits: MaterialsScanLimits }; output: MaterialWalk }
  searchRefresh: { input: { dbPath: string; courseId: string; folder: string }; output: null }
  searchIndexPdf: { input: { dbPath: string; courseId: string; folder: string; relPath: string; pages: { page: number; text: string }[] }; output: null }
  searchQuery: { input: { dbPath: string; courseId: string; folder: string; query: string; limit?: number; fresh?: boolean }; output: SearchHit[] }
}
