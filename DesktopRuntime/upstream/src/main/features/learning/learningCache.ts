import type { Database } from 'better-sqlite3'
import type { LearningProjectSnapshot, LearningProjectSummary } from '../../../shared/types/learning'

/** Derived only. A copied project restores itself without this database. */
export function createLearningCache(db: Database) {
  db.exec(`CREATE TABLE IF NOT EXISTS learning_projects_cache (
    course_id TEXT NOT NULL, root_rel_path TEXT NOT NULL, project_id TEXT NOT NULL,
    name TEXT NOT NULL, topic TEXT NOT NULL, updated_at TEXT NOT NULL,
    PRIMARY KEY(course_id, root_rel_path)
  ); CREATE TABLE IF NOT EXISTS learning_words_cache (
    course_id TEXT NOT NULL, root_rel_path TEXT NOT NULL, word_id TEXT NOT NULL,
    surface TEXT NOT NULL, meaning TEXT NOT NULL, status TEXT NOT NULL,
    PRIMARY KEY(course_id, root_rel_path, word_id)
  )`)
  const columns = new Set((db.prepare('PRAGMA table_info(learning_projects_cache)').all() as { name: string }[]).map(column => column.name))
  if (!columns.has('purpose')) db.exec("ALTER TABLE learning_projects_cache ADD COLUMN purpose TEXT NOT NULL DEFAULT 'unclassified'")
  if (!columns.has('linked_course_id')) db.exec('ALTER TABLE learning_projects_cache ADD COLUMN linked_course_id TEXT')
  const cacheRow = (project: LearningProjectSummary | LearningProjectSnapshot) => ({ ...project, ...project.binding, purpose: project.purpose ?? 'unclassified', linkedCourseId: project.linkedCourseId ?? null })
  const upsert = db.prepare(`INSERT INTO learning_projects_cache (course_id,root_rel_path,project_id,name,topic,updated_at,purpose,linked_course_id) VALUES (@courseId,@rootRelPath,@projectId,@name,@topic,@updatedAt,@purpose,@linkedCourseId)
    ON CONFLICT(course_id,root_rel_path) DO UPDATE SET project_id=excluded.project_id,name=excluded.name,topic=excluded.topic,updated_at=excluded.updated_at,purpose=excluded.purpose,linked_course_id=excluded.linked_course_id`)
  const removeWords = db.prepare('DELETE FROM learning_words_cache WHERE course_id=? AND root_rel_path=?')
  const insertWord = db.prepare('INSERT INTO learning_words_cache VALUES (?,?,?,?,?,?)')
  return {
    replaceCourse(courseId: string, projects: LearningProjectSummary[]) {
      db.transaction(() => {
        db.prepare('DELETE FROM learning_projects_cache WHERE course_id=?').run(courseId)
        for (const project of projects) if (!project.deletedAt) upsert.run(cacheRow(project))
        db.prepare(`DELETE FROM learning_words_cache WHERE course_id=? AND NOT EXISTS
          (SELECT 1 FROM learning_projects_cache p WHERE p.course_id=learning_words_cache.course_id AND p.root_rel_path=learning_words_cache.root_rel_path)`).run(courseId)
      })()
    },
    index(snapshot: LearningProjectSnapshot) {
      db.transaction(() => {
        removeWords.run(snapshot.binding.courseId, snapshot.binding.rootRelPath)
        if (snapshot.deletedAt) {
          db.prepare('DELETE FROM learning_projects_cache WHERE course_id=? AND root_rel_path=?').run(snapshot.binding.courseId, snapshot.binding.rootRelPath)
          return
        }
        upsert.run(cacheRow(snapshot))
        for (const word of snapshot.words) insertWord.run(snapshot.binding.courseId, snapshot.binding.rootRelPath, word.id, word.surface, word.meaning, word.status)
      })()
    }
  }
}
