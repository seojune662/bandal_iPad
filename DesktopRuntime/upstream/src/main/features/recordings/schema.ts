export const RECORDING_SCHEMA = `
  CREATE TABLE IF NOT EXISTS recording_sessions (
    id TEXT PRIMARY KEY,
    course_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    payload TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS recording_sessions_course ON recording_sessions(course_id, created_at);
  CREATE TABLE IF NOT EXISTS recording_segments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
    start_sample INTEGER NOT NULL,
    end_sample INTEGER NOT NULL,
    text TEXT NOT NULL,
    UNIQUE(session_id, start_sample, end_sample)
  );
  CREATE INDEX IF NOT EXISTS recording_segments_session ON recording_segments(session_id, id);
  CREATE TABLE IF NOT EXISTS recording_anchors (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
    payload TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS recording_anchors_session ON recording_anchors(session_id);
`
