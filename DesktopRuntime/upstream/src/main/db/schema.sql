-- [C5] Bandal SQLite schema (v1).
-- Conventions:
--   * ids are UUID strings (TEXT PRIMARY KEY)
--   * created_at / updated_at are ISO-8601 TEXT
--   * deleted_at is NULL for live rows (soft delete)

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS courses (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  slug        TEXT NOT NULL UNIQUE,
  color       TEXT NOT NULL,
  folder_path TEXT NOT NULL,
  archived    INTEGER NOT NULL DEFAULT 0,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  deleted_at  TEXT
);

-- Cached index of files inside each course folder (source of truth is disk).
CREATE TABLE IF NOT EXISTS materials_index (
  id         TEXT PRIMARY KEY,
  course_id  TEXT NOT NULL REFERENCES courses(id),
  rel_path   TEXT NOT NULL,
  kind       TEXT NOT NULL,            -- 'pdf' | 'note' | 'image' | 'other'
  size       INTEGER NOT NULL,
  mtime      INTEGER NOT NULL,         -- epoch ms
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  UNIQUE (course_id, rel_path)
);

CREATE TABLE IF NOT EXISTS annotations (
  id          TEXT PRIMARY KEY,
  course_id   TEXT NOT NULL REFERENCES courses(id),
  rel_path    TEXT NOT NULL,
  page        INTEGER NOT NULL,        -- 1-based
  color       TEXT NOT NULL,           -- 'yellow' | 'green' | 'pink' | 'blue'
  rects_json  TEXT NOT NULL,           -- AnnotationRect[] JSON
  anchor_json TEXT NOT NULL,           -- AnnotationAnchor JSON
  comment     TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  deleted_at  TEXT
);

CREATE TABLE IF NOT EXISTS board_tasks (
  id         TEXT PRIMARY KEY,
  course_id  TEXT REFERENCES courses(id),  -- NULL = global task
  title      TEXT NOT NULL,
  notes      TEXT NOT NULL DEFAULT '',
  status     TEXT NOT NULL DEFAULT 'todo', -- 'todo' | 'in-progress' | 'done'
  due_at     TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS agent_sessions (
  id             TEXT PRIMARY KEY,
  course_id      TEXT NOT NULL REFERENCES courses(id),
  provider       TEXT NOT NULL,        -- 'claude-code' | 'codex' | 'gemini'
  cli_session_id TEXT,
  model          TEXT,
  status         TEXT NOT NULL,        -- 'idle' | 'running' | 'error' | 'closed'
  last_used_at   TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL,
  deleted_at     TEXT
);

CREATE TABLE IF NOT EXISTS messages (
  id         TEXT PRIMARY KEY,
  course_id  TEXT NOT NULL REFERENCES courses(id),
  session_id TEXT NOT NULL REFERENCES agent_sessions(id),
  role       TEXT NOT NULL,            -- 'user' | 'assistant'
  turn_seq   INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS message_blocks (
  id           TEXT PRIMARY KEY,
  message_id   TEXT NOT NULL REFERENCES messages(id),
  ord          INTEGER NOT NULL,
  kind         TEXT NOT NULL,          -- 'text' | 'thinking' | 'tool' | 'permission'
  payload_json TEXT NOT NULL,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  deleted_at   TEXT,
  UNIQUE (message_id, ord)
);

-- Remembered agent permission rules per course.
CREATE TABLE IF NOT EXISTS permission_grants (
  id         TEXT PRIMARY KEY,
  course_id  TEXT NOT NULL REFERENCES courses(id),
  rule       TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

-- Persisted dockview layout per course.
CREATE TABLE IF NOT EXISTS tabs_layout (
  course_id   TEXT PRIMARY KEY REFERENCES courses(id),
  layout_json TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

-- Indexes ------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_courses_sort
  ON courses (archived, sort_order) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_materials_course
  ON materials_index (course_id) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_annotations_file_page
  ON annotations (course_id, rel_path, page) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_board_tasks_course_status
  ON board_tasks (course_id, status, sort_order) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_agent_sessions_course
  ON agent_sessions (course_id, last_used_at) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_messages_course_turn
  ON messages (course_id, turn_seq) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_message_blocks_message
  ON message_blocks (message_id, ord) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_permission_grants_course
  ON permission_grants (course_id) WHERE deleted_at IS NULL;
