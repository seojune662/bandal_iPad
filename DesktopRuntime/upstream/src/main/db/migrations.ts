/**
 * Schema migrations.
 *
 * A `migrations` table records every applied migration (numbered, with a
 * human-readable name and timestamp). `runMigrations` applies pending
 * migrations in version order, each inside a transaction.
 *
 * Migration 001 executes schema.sql (the frozen C5 v1 schema). Later
 * milestones append new entries — never edit an applied migration.
 */

import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'
import { deriveConversationTitle } from '../features/agent/chatRepo'
import schemaSql from './schema.sql?raw'
import { RECORDING_SCHEMA } from '../features/recordings/schema'

export interface Migration {
  version: number
  /** Human-readable label for logs. */
  name: string
  up: (db: Database) => void
}

export const migrations: Migration[] = [
  {
    version: 1,
    name: 'initial-schema',
    up: (db) => {
      db.exec(schemaSql)
    }
  },
  {
    // [M4-H] Session resume record: the CLI transcript path can diverge from
    // cli_session_id across CLI versions, and respawning needs the original
    // launch configuration — persist both alongside the session row.
    version: 2,
    name: 'agent-session-resume-record',
    up: (db) => {
      db.exec(
        `ALTER TABLE agent_sessions ADD COLUMN transcript_path TEXT;
         ALTER TABLE agent_sessions ADD COLUMN launch_config_json TEXT;`
      )
    }
  },
  {
    // [M7] Folder-based courses: a course folder may now be an arbitrary
    // path the user pointed at. `source` distinguishes the folder Bandal
    // created under the data root ('managed') from a linked one ('linked');
    // every pre-existing row is managed by definition. The index backs the
    // duplicate-registration lookup by folder_path.
    version: 3,
    name: 'course-folder-source',
    up: (db) => {
      db.exec(
        `ALTER TABLE courses ADD COLUMN source TEXT NOT NULL DEFAULT 'managed';
         CREATE INDEX IF NOT EXISTS idx_courses_folder_path
           ON courses (folder_path) WHERE deleted_at IS NULL;`
      )
    }
  },
  {
    // [M8] Per-course shortcuts (docs/university-sites.md §6.4): the LMS
    // 강의실 page for this course, plus any other URL the student pins.
    // `raw_url` keeps exactly what was pasted so normalising to the course
    // root is always reversible; `lms_course_id` is set only when the URL
    // matched the school's CourseLinkSpec, which lets us rebuild the link if
    // the school moves hosts. Additive — nothing existing is touched.
    version: 4,
    name: 'course-links',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS course_links (
           id            TEXT PRIMARY KEY,
           course_id     TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
           label         TEXT NOT NULL,
           url           TEXT NOT NULL,
           raw_url       TEXT NOT NULL,
           kind          TEXT NOT NULL,
           lms_course_id TEXT,
           sort_order    INTEGER NOT NULL DEFAULT 0,
           created_at    TEXT NOT NULL,
           updated_at    TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_course_links_course
           ON course_links (course_id, sort_order);`
      )
    }
  },
  {
    // [P2-C] Phase-2 group binding + render cache
    // (docs/phase2-community.md §3.1–3.2).
    //
    // The truth model INVERTS here. For Phase 1 (courses/materials/notes/…)
    // SQLite *is* the truth. For Phase 2 the remote Postgres is the truth and
    // these tables are a render cache plus an outbox — the same relationship
    // `materials_index` has with the disk.
    //
    // `courses` itself is untouched: the binding lives in a mapping table, so
    // the Phase-1 offline guarantee holds STRUCTURALLY rather than by
    // argument, 1:N (전체방 + 우리조) is expressible, and rolling the whole
    // feature back is one DROP TABLE.
    version: 5,
    name: 'phase2-group-links-and-cache',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS course_group_links (
           id                 TEXT PRIMARY KEY,
           course_id          TEXT REFERENCES courses(id),
           remote_group_id    TEXT NOT NULL UNIQUE,
           name_cache         TEXT NOT NULL,
           color_cache        TEXT NOT NULL,
           member_count_cache INTEGER NOT NULL DEFAULT 0,
           unread_cache       INTEGER NOT NULL DEFAULT 0,
           last_msg_at_cache  TEXT,
           joined_at          TEXT NOT NULL,
           created_at         TEXT NOT NULL,
           updated_at         TEXT NOT NULL,
           deleted_at         TEXT
         );
         CREATE INDEX IF NOT EXISTS idx_course_group_links_course
           ON course_group_links (course_id) WHERE deleted_at IS NULL;

         CREATE TABLE IF NOT EXISTS group_messages_cache (
           id           TEXT PRIMARY KEY,
           group_id     TEXT NOT NULL,
           seq          INTEGER NOT NULL,
           author_id    TEXT NOT NULL,
           kind         TEXT NOT NULL,
           body         TEXT NOT NULL,
           reply_to     TEXT,
           author_json  TEXT NOT NULL DEFAULT '{}',
           created_at   TEXT NOT NULL,
           edited_at    TEXT,
           deleted_at   TEXT,
           UNIQUE (group_id, seq)
         );
         CREATE INDEX IF NOT EXISTS idx_gmc_group_seq
           ON group_messages_cache (group_id, seq DESC);

         CREATE TABLE IF NOT EXISTS group_outbox (
           id         TEXT PRIMARY KEY,
           group_id   TEXT NOT NULL,
           body       TEXT NOT NULL,
           reply_to   TEXT,
           state      TEXT NOT NULL DEFAULT 'pending',
           attempts   INTEGER NOT NULL DEFAULT 0,
           last_error TEXT,
           next_try_at TEXT,
           created_at TEXT NOT NULL,
           updated_at TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_group_outbox_state
           ON group_outbox (state, created_at);

         CREATE TABLE IF NOT EXISTS group_profiles_cache (
           user_id      TEXT PRIMARY KEY,
           nickname     TEXT NOT NULL,
           avatar_color TEXT NOT NULL,
           avatar_emoji TEXT NOT NULL,
           fetched_at   TEXT NOT NULL
         );

         CREATE TABLE IF NOT EXISTS group_members_cache (
           group_id  TEXT NOT NULL,
           user_id   TEXT NOT NULL,
           role      TEXT NOT NULL,
           joined_at TEXT NOT NULL,
           PRIMARY KEY (group_id, user_id)
         );`
      )
    }
  },
  {
    // [M9] Free-form PDF markup (pen / highlighter / shapes / text boxes).
    // Kept out of `annotations` on purpose: that table anchors to extracted
    // text so it can detect drift, and drawings have no text to anchor to.
    // All geometry in data_json is normalized 0..1 against the page box, so
    // zoom and DPI changes never need a migration.
    version: 6,
    name: 'pdf-drawings',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS pdf_drawings (
           id         TEXT PRIMARY KEY,
           course_id  TEXT NOT NULL REFERENCES courses(id),
           rel_path   TEXT NOT NULL,
           page       INTEGER NOT NULL,
           kind       TEXT NOT NULL,
           data_json  TEXT NOT NULL,
           style_json TEXT NOT NULL,
           created_at TEXT NOT NULL,
           updated_at TEXT NOT NULL,
           deleted_at TEXT
         );
         CREATE INDEX IF NOT EXISTS idx_pdf_drawings_file_page
           ON pdf_drawings (course_id, rel_path, page) WHERE deleted_at IS NULL;`
      )
    }
  },
  {
    // [M10] Favorites: left-rail pins for ANY tab, superseding course_links
    // (which only ever held LMS URLs). descriptor_json is the same
    // TabDescriptor the dockview layout persists, so opening a favorite is
    // just openTab(descriptor) — no second code path to keep in sync.
    // course_id is nullable: NULL pins app-wide instead of to one course.
    version: 7,
    name: 'favorites',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS favorites (
           id              TEXT PRIMARY KEY,
           course_id       TEXT REFERENCES courses(id) ON DELETE CASCADE,
           label           TEXT NOT NULL,
           descriptor_json TEXT NOT NULL,
           sort_order      INTEGER NOT NULL DEFAULT 0,
           created_at      TEXT NOT NULL,
           updated_at      TEXT NOT NULL,
           deleted_at      TEXT
         );
         CREATE INDEX IF NOT EXISTS idx_favorites_course
           ON favorites (course_id, sort_order) WHERE deleted_at IS NULL;`
      )
    }
  },
  {
    // [M11] Fold course_links into favorites.
    //
    // 링크 and 즐겨찾기 were two lists doing the same job under one course.
    // Favorites already stores a whole TabDescriptor, so an LMS URL is just a
    // browser descriptor — one concept instead of two.
    //
    // course_links is NOT dropped: this copies out of it and leaves it intact
    // so the change stays reversible, and the repo/IPC keep working until the
    // migration has been verified in the wild. Re-running is safe — a URL
    // already present as a favorite for that course is skipped.
    version: 8,
    name: 'course-links-into-favorites',
    up: (db) => {
      const links = db
        .prepare(
          `SELECT course_id, label, url, sort_order
             FROM course_links
            ORDER BY course_id, sort_order`
        )
        .all() as {
        course_id: string
        label: string
        url: string
        sort_order: number
      }[]
      if (links.length === 0) return

      const existing = db
        .prepare(
          `SELECT course_id, descriptor_json FROM favorites WHERE deleted_at IS NULL`
        )
        .all() as { course_id: string | null; descriptor_json: string }[]
      const taken = new Set(
        existing.map((row) => {
          let url = ''
          try {
            const parsed = JSON.parse(row.descriptor_json) as {
              payload?: { initialUrl?: unknown }
            }
            url =
              typeof parsed.payload?.initialUrl === 'string'
                ? parsed.payload.initialUrl
                : ''
          } catch {
            url = ''
          }
          return `${row.course_id ?? ''}\u0000${url}`
        })
      )

      const nextOrder = db.prepare(
        `SELECT COALESCE(MAX(sort_order), -1) + 1 AS next
           FROM favorites
          WHERE course_id IS ? AND deleted_at IS NULL`
      )
      const insert = db.prepare(
        `INSERT INTO favorites
           (id, course_id, label, descriptor_json, sort_order, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      )
      const now = new Date().toISOString()

      for (const link of links) {
        if (taken.has(`${link.course_id}\u0000${link.url}`)) continue
        const descriptor = JSON.stringify({
          kind: 'browser',
          payload: { tabId: randomUUID(), initialUrl: link.url }
        })
        const { next } = nextOrder.get(link.course_id) as { next: number }
        insert.run(
          randomUUID(),
          link.course_id,
          link.label,
          descriptor,
          next,
          now,
          now
        )
        taken.add(`${link.course_id}\u0000${link.url}`)
      }
    }
  },
  {
    // [M12] Course activity log.
    //
    // The AI tutor could always read the course FOLDER, but never what the
    // student did: which page they highlighted, which task they finished, what
    // they asked last week. That history simply did not exist anywhere — every
    // other table stores current state, not events. This is the missing half,
    // and it feeds the `.bandal/` dossier the agent reads.
    //
    // Deliberately append-only and summary-first: `summary` is a ready-to-read
    // line so building the dossier is a SELECT, not a join across six tables.
    version: 9,
    name: 'activity-events',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS activity_events (
           id         TEXT PRIMARY KEY,
           course_id  TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
           kind       TEXT NOT NULL,
           rel_path   TEXT,
           summary    TEXT NOT NULL,
           created_at TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_activity_course_time
           ON activity_events (course_id, created_at DESC);`
      )
    }
  },
  {
    // [M13] Local mirror of the group whiteboard.
    //
    // One table does both jobs. `pending = 1` means "drawn here, not yet
    // accepted by the server" (the outbox), `pending = 0` means "confirmed"
    // (the read cache). Keeping them separate would need a hand-off between
    // two tables at exactly the moment a write succeeds, which is where that
    // kind of design usually loses a stroke.
    //
    // Losing someone's drawing because the wifi dropped is not acceptable, so
    // a stroke is written here FIRST and uploaded after — the same
    // client-generated-id idempotency the chat outbox relies on.
    version: 10,
    name: 'whiteboard-local-mirror',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS whiteboard_shapes_cache (
           id         TEXT PRIMARY KEY,
           board_id   TEXT NOT NULL,
           group_id   TEXT NOT NULL,
           author_id  TEXT NOT NULL,
           kind       TEXT NOT NULL,
           data_json  TEXT NOT NULL,
           style_json TEXT NOT NULL,
           pending    INTEGER NOT NULL DEFAULT 0,
           attempts   INTEGER NOT NULL DEFAULT 0,
           created_at TEXT NOT NULL,
           updated_at TEXT NOT NULL,
           deleted_at TEXT
         );
         CREATE INDEX IF NOT EXISTS idx_wb_shapes_board
           ON whiteboard_shapes_cache (board_id, created_at)
           WHERE deleted_at IS NULL;
         CREATE INDEX IF NOT EXISTS idx_wb_shapes_pending
           ON whiteboard_shapes_cache (pending, attempts)
           WHERE pending = 1;

         CREATE TABLE IF NOT EXISTS whiteboard_boards_cache (
           id         TEXT PRIMARY KEY,
           group_id   TEXT NOT NULL UNIQUE,
           title      TEXT NOT NULL,
           synced_at  TEXT,
           created_at TEXT NOT NULL,
           updated_at TEXT NOT NULL
         );`
      )
    }
  },
  {
    // [M14] Personal whiteboards — the student's own canvas, local only.
    //
    // Separate from whiteboard_shapes_cache because that table mirrors a
    // REMOTE board: it carries board_id/group_id/author_id/pending and its
    // rows are owned by the server. A personal board has no server, no author
    // and nothing to sync, so reusing that table would mean every column
    // except the geometry is dead weight and every query needs a "is this the
    // local kind?" branch.
    version: 11,
    name: 'personal-whiteboards',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS whiteboards (
           id         TEXT PRIMARY KEY,
           course_id  TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
           title      TEXT NOT NULL,
           sort_order INTEGER NOT NULL DEFAULT 0,
           created_at TEXT NOT NULL,
           updated_at TEXT NOT NULL,
           deleted_at TEXT
         );
         CREATE INDEX IF NOT EXISTS idx_whiteboards_course
           ON whiteboards (course_id, sort_order) WHERE deleted_at IS NULL;

         CREATE TABLE IF NOT EXISTS whiteboard_local_shapes (
           id         TEXT PRIMARY KEY,
           board_id   TEXT NOT NULL REFERENCES whiteboards(id) ON DELETE CASCADE,
           kind       TEXT NOT NULL,
           data_json  TEXT NOT NULL,
           style_json TEXT NOT NULL,
           created_at TEXT NOT NULL,
           updated_at TEXT NOT NULL,
           deleted_at TEXT
         );
         CREATE INDEX IF NOT EXISTS idx_wb_local_board
           ON whiteboard_local_shapes (board_id, created_at)
           WHERE deleted_at IS NULL;`
      )
    }
  },
  {
    // [M15] Calendar-shaped board entries.
    //
    // A task, an assignment and an exam differ only in how they read on a
    // date, so they share one table — three tables would mean three queries to
    // draw one month and three copies of the due-date logic.
    //
    // `all_day` matters because "제출 마감 23:59" and "중간고사 (하루)" render
    // and sort differently, and guessing from the time component gets it wrong
    // for anything scheduled exactly at midnight.
    version: 12,
    name: 'board-task-kind-and-allday',
    up: (db) => {
      // SQLite has no `ADD COLUMN IF NOT EXISTS`, and the repo's rule is that
      // re-applying a migration must be safe. Check the table first so a
      // database whose bookkeeping row was lost — or replayed in a test —
      // does not die on "duplicate column name".
      const columns = new Set(
        (db.prepare('PRAGMA table_info(board_tasks)').all() as { name: string }[]).map(
          (column) => column.name
        )
      )
      if (!columns.has('kind')) {
        db.exec(
          `ALTER TABLE board_tasks ADD COLUMN kind TEXT NOT NULL DEFAULT 'task'`
        )
      }
      if (!columns.has('all_day')) {
        db.exec(
          `ALTER TABLE board_tasks ADD COLUMN all_day INTEGER NOT NULL DEFAULT 0`
        )
      }
      db.exec(
        `CREATE INDEX IF NOT EXISTS idx_board_tasks_due
           ON board_tasks (due_at) WHERE deleted_at IS NULL AND due_at IS NOT NULL;`
      )
    }
  },
  {
    version: 13,
    name: 'whiteboard-background',
    up: (db) => {
      const columns = new Set(
        (db.prepare('PRAGMA table_info(whiteboards)').all() as { name: string }[]).map(
          (column) => column.name
        )
      )
      // Existing boards keep exactly what their owner has been looking at.
      if (!columns.has('background')) {
        db.exec(
          `ALTER TABLE whiteboards ADD COLUMN background TEXT NOT NULL DEFAULT 'grid'`
        )
      }
      if (!columns.has('surface')) {
        db.exec(
          `ALTER TABLE whiteboards ADD COLUMN surface TEXT NOT NULL DEFAULT 'dark'`
        )
      }
    }
  },
  {
    version: 14,
    name: 'whiteboard-pages',
    up: (db) => {
      // A board used to be one surface stretched to whatever the panel happened
      // to be, so resizing the window distorted every stroke. It becomes a stack
      // of fixed-aspect pages instead: coordinates stay 0..1 *within a page*, so
      // all existing geometry keeps working and old shapes simply belong to
      // page 1.
      const boards = new Set(
        (db.prepare('PRAGMA table_info(whiteboards)').all() as { name: string }[]).map(
          (column) => column.name
        )
      )
      if (!boards.has('page_count')) {
        db.exec(
          'ALTER TABLE whiteboards ADD COLUMN page_count INTEGER NOT NULL DEFAULT 1'
        )
      }
      const shapes = new Set(
        (
          db
            .prepare('PRAGMA table_info(whiteboard_local_shapes)')
            .all() as { name: string }[]
        ).map((column) => column.name)
      )
      if (!shapes.has('page')) {
        db.exec(
          'ALTER TABLE whiteboard_local_shapes ADD COLUMN page INTEGER NOT NULL DEFAULT 1'
        )
      }
      db.exec(
        `CREATE INDEX IF NOT EXISTS idx_wb_local_board_page
           ON whiteboard_local_shapes (board_id, page)
           WHERE deleted_at IS NULL;`
      )
    }
  },
  {
    version: 15,
    name: 'agent-actions',
    up: (db) => {
      // What the assistant changed, so the student can see it and take it back.
      // Only creations are undoable: deletes and overwrites were confirmed
      // first and have nothing to restore from.
      db.exec(
        `CREATE TABLE IF NOT EXISTS agent_actions (
           id          TEXT PRIMARY KEY,
           course_id   TEXT NOT NULL REFERENCES courses(id),
           turn_id     TEXT NOT NULL,
           tool        TEXT NOT NULL,
           target_kind TEXT NOT NULL,
           target_id   TEXT NOT NULL,
           label       TEXT NOT NULL,
           undoable    INTEGER NOT NULL DEFAULT 1,
           undone_at   TEXT,
           created_at  TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_agent_actions_turn
           ON agent_actions (turn_id, created_at);`
      )
    }
  },
  {
    // [M16] Multiple conversations per course. A conversation IS an
    // agent_sessions row, so all this needs is a display title (first user
    // message, one line, ≤60 chars) and an index for the per-course list
    // ordered by recency. Existing rows get their title backfilled from the
    // earliest user message with exactly the rule new sends use.
    version: 16,
    name: 'agent-session-titles',
    up: (db) => {
      const columns = new Set(
        (
          db.prepare('PRAGMA table_info(agent_sessions)').all() as {
            name: string
          }[]
        ).map((column) => column.name)
      )
      if (!columns.has('title')) {
        db.exec(`ALTER TABLE agent_sessions ADD COLUMN title TEXT`)
      }
      db.exec(
        `CREATE INDEX IF NOT EXISTS idx_agent_sessions_course_recency
           ON agent_sessions (course_id, last_used_at DESC)
           WHERE deleted_at IS NULL;`
      )

      const sessions = db
        .prepare(
          `SELECT id FROM agent_sessions
           WHERE title IS NULL AND deleted_at IS NULL`
        )
        .all() as { id: string }[]
      const firstUserText = db.prepare(
        `SELECT b.payload_json AS payload
           FROM messages m
           JOIN message_blocks b ON b.message_id = m.id
          WHERE m.session_id = ? AND m.role = 'user'
            AND m.deleted_at IS NULL AND b.deleted_at IS NULL
            AND b.kind = 'text'
          ORDER BY m.turn_seq ASC, b.ord ASC
          LIMIT 1`
      )
      const setTitle = db.prepare(
        `UPDATE agent_sessions SET title = ? WHERE id = ?`
      )
      for (const { id } of sessions) {
        const row = firstUserText.get(id) as { payload: string } | undefined
        if (row === undefined) continue
        let text = ''
        try {
          const parsed = JSON.parse(row.payload) as { text?: unknown }
          text = typeof parsed.text === 'string' ? parsed.text : ''
        } catch {
          text = ''
        }
        const title = deriveConversationTitle(text)
        if (title !== '') {
          setTitle.run(title, id)
        }
      }
    }
  },
  {
    // [M17] 과목 그룹(학기). A group is a named bucket the sidebar renders as
    // a section header; membership lives on the course row itself so a course
    // is in at most one group and "ungrouped" is simply group_id NULL.
    // Deleting a group soft-deletes the group row and NULLs the members'
    // group_id — courses are never deleted by group operations.
    version: 17,
    name: 'course-groups',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS course_groups (
           id         TEXT PRIMARY KEY,
           name       TEXT NOT NULL,
           sort_order INTEGER NOT NULL DEFAULT 0,
           created_at TEXT NOT NULL,
           updated_at TEXT NOT NULL,
           deleted_at TEXT
         );`
      )
      // SQLite has no ADD COLUMN IF NOT EXISTS; guard so replaying (lost
      // bookkeeping row, tests) never dies on "duplicate column name".
      const columns = new Set(
        (db.prepare('PRAGMA table_info(courses)').all() as { name: string }[]).map(
          (column) => column.name
        )
      )
      if (!columns.has('group_id')) {
        db.exec(
          `ALTER TABLE courses ADD COLUMN group_id TEXT REFERENCES course_groups(id)`
        )
      }
      db.exec(
        `CREATE INDEX IF NOT EXISTS idx_courses_group
           ON courses (group_id, sort_order) WHERE deleted_at IS NULL;`
      )
    }
  },
  {
    // [M18] 영상 이어보기. Derived per-file view state (watch position +
    // playback rate) — no id / soft-delete: the (course, file) pair IS the
    // identity and losing a row only loses a resume point.
    version: 18,
    name: 'media-progress',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS media_progress (
           course_id     TEXT NOT NULL REFERENCES courses(id),
           rel_path      TEXT NOT NULL,
           position_sec  REAL NOT NULL,
           duration_sec  REAL,
           playback_rate REAL NOT NULL DEFAULT 1,
           updated_at    TEXT NOT NULL,
           PRIMARY KEY (course_id, rel_path)
         );`
      )
    }
  },
  {
    // [M19] Browser history. Derived from browsing, so no soft-delete: a row
    // is either there or forgotten, and losing the table only costs an
    // omnibox suggestion. Keyed by URL because "how often / how recently"
    // is the whole point — a second visit updates, it does not append.
    //
    // `course_id` records which course was open at the time, so history can
    // be scoped and deleted with the course. It is NOT a foreign key: a visit
    // outlives the course it happened in, and a FK would block course delete.
    version: 19,
    name: 'browser-history',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS browser_history (
           url             TEXT PRIMARY KEY,
           title           TEXT NOT NULL,
           host            TEXT NOT NULL,
           course_id       TEXT,
           visit_count     INTEGER NOT NULL DEFAULT 1,
           last_visited_at TEXT NOT NULL
         );`
      )
      db.exec(
        `CREATE INDEX IF NOT EXISTS idx_browser_history_visited
           ON browser_history (last_visited_at DESC);`
      )
      db.exec(
        `CREATE INDEX IF NOT EXISTS idx_browser_history_host
           ON browser_history (host);`
      )
    }
  },
  {
    // [M20] What the agent may do in the browser, and what it did.
    //
    // A grant is a TUPLE (course, exact origin, capability) with an expiry —
    // never a tool name, never course-wide, never permanent. The existing
    // tool-permission grant is all three of those and cannot be listed or
    // revoked (backlog §5.8); this deliberately inherits none of it.
    //
    // `browser_audit` is append-only. Values are redacted before they get
    // here (browserAgent/redact.ts): a password is absent rather than masked.
    version: 20,
    name: 'browser-agent-grants-audit',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS browser_grants (
           id           TEXT PRIMARY KEY,
           course_id    TEXT NOT NULL,
           origin       TEXT NOT NULL,
           capability   TEXT NOT NULL,
           created_at   TEXT NOT NULL,
           expires_at   TEXT NOT NULL,
           revoked_at   TEXT,
           last_used_at TEXT
         );`
      )
      db.exec(
        `CREATE INDEX IF NOT EXISTS idx_browser_grants_lookup
           ON browser_grants (course_id, origin);`
      )
      db.exec(
        `CREATE TABLE IF NOT EXISTS browser_audit (
           id         TEXT PRIMARY KEY,
           course_id  TEXT NOT NULL,
           run_id     TEXT NOT NULL,
           action     TEXT NOT NULL,
           url        TEXT NOT NULL,
           detail     TEXT NOT NULL,
           created_at TEXT NOT NULL
         );`
      )
      db.exec(
        `CREATE INDEX IF NOT EXISTS idx_browser_audit_course
           ON browser_audit (course_id, created_at DESC);`
      )
      // Diff ledger: which LMS items this course has already been told about.
      // The ONLY way "새 공지 있어?" is answerable rather than "여기 공지 30개".
      // Holds ids and titles, never page content, and dies with the course.
      db.exec(
        `CREATE TABLE IF NOT EXISTS browser_seen (
           course_id  TEXT NOT NULL,
           list_key   TEXT NOT NULL,
           item_key   TEXT NOT NULL,
           title      TEXT NOT NULL,
           first_seen TEXT NOT NULL,
           PRIMARY KEY (course_id, list_key, item_key)
         );`
      )
    }
  },
  {
    // [M21] What a WEBSITE may do — camera, location, notifications.
    //
    // Deliberately a different table from browser_grants: those are what the
    // AI agent may do in a course, these are what a site may do in the
    // browser. One table would make one revocation screen that lies about
    // both — "카메라 취소" would leave the student wondering why the
    // assistant still reads the page.
    //
    // No expiry, unlike agent grants. Chrome and Safari both remember a site
    // permission until it is revoked, and one that lapses silently mid-term
    // is worse than one the student can see and remove.
    version: 21,
    name: 'browser-site-permissions',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS browser_permissions (
           id         TEXT PRIMARY KEY,
           origin     TEXT NOT NULL,
           permission TEXT NOT NULL,
           decision   TEXT NOT NULL,
           decided_at TEXT NOT NULL,
           UNIQUE (origin, permission)
         );`
      )
    }
  },
  {
    version: 22,
    name: 'desktop-surface-and-mcp',
    up: (db) => {
      const columns = new Set(
        (
          db.prepare('PRAGMA table_info(agent_sessions)').all() as {
            name: string
          }[]
        ).map((column) => column.name)
      )
      if (!columns.has('surface')) {
        db.exec(
          `ALTER TABLE agent_sessions ADD COLUMN surface TEXT NOT NULL DEFAULT 'app'`
        )
      }
      db.exec(
        `CREATE INDEX IF NOT EXISTS idx_agent_sessions_surface
           ON agent_sessions (surface, course_id, last_used_at DESC)
           WHERE deleted_at IS NULL;
         CREATE TABLE IF NOT EXISTS desktop_grants (
           id TEXT PRIMARY KEY,
           course_id TEXT NOT NULL,
           capability TEXT NOT NULL,
           created_at TEXT NOT NULL,
           expires_at TEXT NOT NULL,
           revoked_at TEXT,
           last_used_at TEXT
         );
         CREATE INDEX IF NOT EXISTS idx_desktop_grants_course
           ON desktop_grants (course_id, capability);
         CREATE TABLE IF NOT EXISTS desktop_audit (
           id TEXT PRIMARY KEY,
           course_id TEXT NOT NULL,
           conversation_id TEXT NOT NULL,
           action TEXT NOT NULL,
           target TEXT NOT NULL,
           detail TEXT NOT NULL,
           created_at TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_desktop_audit_course
           ON desktop_audit (course_id, created_at DESC);`
      )
    }
  },
  {
    version: 23,
    name: 'all-day-due-date',
    up: (db) => {
      const migrateRows = db.transaction(() => {
        const rows = db
          .prepare(
            `SELECT id, due_at
               FROM board_tasks
              WHERE all_day = 1 AND due_at LIKE '%T%'`
          )
          .all() as { id: string; due_at: string }[]
        const update = db.prepare(
          'UPDATE board_tasks SET due_at = ? WHERE id = ?'
        )

        for (const row of rows) {
          const instant = new Date(row.due_at)
          if (Number.isNaN(instant.getTime())) {
            throw new TypeError(`Invalid all-day due_at for board task ${row.id}`)
          }
          const year = String(instant.getFullYear()).padStart(4, '0')
          const month = String(instant.getMonth() + 1).padStart(2, '0')
          const day = String(instant.getDate()).padStart(2, '0')
          update.run(`${year}-${month}-${day}`, row.id)
        }
      })
      migrateRows()
    }
  },
  {
    version: 24,
    name: 'material-links',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS material_links (
           id          TEXT PRIMARY KEY,
           course_id   TEXT NOT NULL,
           source_json TEXT NOT NULL,
           target_json TEXT NOT NULL,
           label       TEXT NOT NULL DEFAULT '',
           created_at  TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_material_links_course
           ON material_links (course_id);`
      )
    }
  },
  {
    // 마지막으로 보던 페이지/줌 — 재시작 후에도 그 자리에서 다시 연다.
    // 파생 뷰 상태라 소프트 삭제 없음(행 손실 = 위치만 잃음). media_progress
    // 와 같은 결.
    version: 25,
    name: 'pdf-view-state',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS pdf_view_state (
           course_id  TEXT NOT NULL,
           rel_path   TEXT NOT NULL,
           page       INTEGER NOT NULL,
           zoom       REAL NOT NULL DEFAULT 1,
           updated_at TEXT NOT NULL,
           PRIMARY KEY (course_id, rel_path)
         )`
      )
    }
  },
  {
    // [v0.39] Provider-independent turn usage survives conversation deletion.
    version: 26,
    name: 'agent-usage-ledger',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS agent_usage (
           id                 TEXT PRIMARY KEY,
           session_id         TEXT NOT NULL,
           course_id          TEXT NOT NULL,
           provider           TEXT NOT NULL,
           model              TEXT,
           turn_at            TEXT NOT NULL,
           input_tokens       INTEGER NOT NULL DEFAULT 0,
           output_tokens      INTEGER NOT NULL DEFAULT 0,
           cache_read_tokens  INTEGER NOT NULL DEFAULT 0,
           cache_write_tokens INTEGER NOT NULL DEFAULT 0,
           duration_ms        INTEGER
         );
         CREATE INDEX IF NOT EXISTS idx_agent_usage_turn_at
           ON agent_usage (turn_at);
         CREATE INDEX IF NOT EXISTS idx_agent_usage_provider_turn_at
           ON agent_usage (provider, turn_at);`
      )
    }
  },
  {
    // Optimized photos used by shared whiteboards. The bytes live on disk;
    // this table is a durable upload queue and metadata mirror. A shape is
    // not sent upstream until its referenced asset has reached storage.
    version: 27,
    name: 'whiteboard-shared-assets',
    up: (db) => {
      db.exec(
        `CREATE TABLE IF NOT EXISTS whiteboard_assets_cache (
           id          TEXT PRIMARY KEY,
           board_id    TEXT NOT NULL,
           group_id    TEXT NOT NULL,
           author_id   TEXT NOT NULL,
           label       TEXT NOT NULL,
           mime_type   TEXT NOT NULL,
           width_px    INTEGER NOT NULL,
           height_px   INTEGER NOT NULL,
           remote_path TEXT NOT NULL,
           pending     INTEGER NOT NULL DEFAULT 1,
           attempts    INTEGER NOT NULL DEFAULT 0,
           last_error  TEXT,
           created_at  TEXT NOT NULL,
           updated_at  TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_whiteboard_assets_board
           ON whiteboard_assets_cache (board_id, created_at);
         CREATE INDEX IF NOT EXISTS idx_whiteboard_assets_pending
           ON whiteboard_assets_cache (pending, attempts)
           WHERE pending = 1;`
      )
    }
  },
  {
    version: 28,
    name: 'typed-material-links',
    up: (db) => {
      const columns = new Set(
        (db.prepare('PRAGMA table_info(material_links)').all() as { name: string }[])
          .map((column) => column.name)
      )
      if (!columns.has('kind')) {
        db.exec(
          `ALTER TABLE material_links
             ADD COLUMN kind TEXT NOT NULL DEFAULT 'related'`
        )
      }
      if (!columns.has('metadata_json')) {
        db.exec('ALTER TABLE material_links ADD COLUMN metadata_json TEXT')
      }
      db.exec(
        `UPDATE material_links SET kind = 'sequence' WHERE label = 'next';
         CREATE INDEX IF NOT EXISTS idx_material_links_kind
           ON material_links (course_id, kind);`
      )
    }
  },
  {
    version: 29,
    name: 'friends-direct-chat-and-course-sharing-cache',
    up: (db) => {
      const columns = new Set(
        (db.prepare('PRAGMA table_info(course_group_links)').all() as { name: string }[])
          .map((column) => column.name)
      )
      if (!columns.has('kind_cache')) {
        db.exec("ALTER TABLE course_group_links ADD COLUMN kind_cache TEXT NOT NULL DEFAULT 'study'")
      }
      if (!columns.has('direct_peer_id')) {
        db.exec('ALTER TABLE course_group_links ADD COLUMN direct_peer_id TEXT')
      }
      db.exec(
        `CREATE INDEX IF NOT EXISTS idx_course_group_links_kind
           ON course_group_links (kind_cache, last_msg_at_cache DESC)
           WHERE deleted_at IS NULL;
         CREATE TABLE IF NOT EXISTS friends_cache (
           user_id       TEXT PRIMARY KEY,
           nickname      TEXT NOT NULL,
           avatar_color  TEXT NOT NULL,
           avatar_emoji  TEXT NOT NULL,
           status        TEXT NOT NULL,
           direction     TEXT NOT NULL,
           unread        INTEGER NOT NULL DEFAULT 0,
           fetched_at    TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS published_course_links (
           owner_id   TEXT NOT NULL,
           course_id  TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
           share_id   TEXT NOT NULL UNIQUE,
           updated_at TEXT NOT NULL,
           PRIMARY KEY (owner_id, course_id)
         );`
      )
    }
  },
  {
    version: 30,
    name: 'board-task-colors',
    up: (db) => {
      const columns = new Set(
        (db.prepare('PRAGMA table_info(board_tasks)').all() as { name: string }[])
          .map((column) => column.name)
      )
      if (!columns.has('color')) {
        db.exec(
          "ALTER TABLE board_tasks ADD COLUMN color TEXT NOT NULL DEFAULT 'none'"
        )
      }
    }
  },
  {
    version: 31,
    name: 'friend-conversation-previews',
    up: (db) => {
      const columns = new Set((db.prepare('PRAGMA table_info(friends_cache)').all() as { name: string }[]).map((column) => column.name))
      if (!columns.has('last_message_preview')) db.exec('ALTER TABLE friends_cache ADD COLUMN last_message_preview TEXT')
      if (!columns.has('last_message_at')) db.exec('ALTER TABLE friends_cache ADD COLUMN last_message_at TEXT')
    }
  },
  { version: 32, name: 'lecture-recordings', up: (db) => { db.exec(RECORDING_SCHEMA) } },
  {
    version: 33,
    name: 'chat-reasoning-effort',
    up: (db) => {
      const columns = db.prepare('PRAGMA table_info(agent_sessions)').all() as { name: string }[]
      if (!columns.some((column) => column.name === 'effort')) {
        db.exec('ALTER TABLE agent_sessions ADD COLUMN effort TEXT')
      }
    }
  },
  {
    version: 34,
    name: 'board-task-schedule-range',
    up: (db) => {
      const columns = db.prepare('PRAGMA table_info(board_tasks)').all() as { name: string }[]
      if (!columns.some((column) => column.name === 'start_at')) {
        db.exec('ALTER TABLE board_tasks ADD COLUMN start_at TEXT')
      }
    }
  },
  { version: 35, name: 'conversation-access-policy', up: (db) => {
    const columns = db.prepare('PRAGMA table_info(agent_sessions)').all() as { name: string }[]
    if (!columns.some(column => column.name === 'access_policy')) db.exec('ALTER TABLE agent_sessions ADD COLUMN access_policy TEXT')
  } },
  { version: 36, name: 'course-workspace-kind', up: (db) => {
    const columns = db.prepare('PRAGMA table_info(courses)').all() as { name: string }[]
    if (!columns.some(column => column.name === 'workspace_kind')) db.exec("ALTER TABLE courses ADD COLUMN workspace_kind TEXT NOT NULL DEFAULT 'course' CHECK (workspace_kind IN ('course','study-space'))")
  } },
  { version: 37, name: 'material-added-state', up: (db) => {
    db.exec(`CREATE TABLE IF NOT EXISTS material_added_baselines (
      course_id TEXT PRIMARY KEY REFERENCES courses(id) ON DELETE CASCADE,
      folder TEXT NOT NULL,
      completed INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS material_added_state (
      course_id TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      rel_path TEXT NOT NULL,
      added_at INTEGER,
      pending_children INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (course_id, rel_path)
    );
    CREATE INDEX IF NOT EXISTS idx_wb_local_preview
      ON whiteboard_local_shapes (board_id, page, created_at, id)
      WHERE deleted_at IS NULL;`)
    const columns = db.prepare('PRAGMA table_info(whiteboards)').all() as { name: string }[]
    if (!columns.some(column => column.name === 'added_at')) db.exec('ALTER TABLE whiteboards ADD COLUMN added_at INTEGER')
  } }

]

/** Creates the bookkeeping table if needed and returns applied versions. */
function appliedVersions(db: Database): Set<number> {
  db.exec(
    `CREATE TABLE IF NOT EXISTS migrations (
       version    INTEGER PRIMARY KEY,
       name       TEXT NOT NULL,
       applied_at TEXT NOT NULL
     )`
  )
  const rows = db.prepare('SELECT version FROM migrations').all() as {
    version: number
  }[]
  return new Set(rows.map((row) => row.version))
}

/** Applies pending migrations in version order, each in a transaction. */
export function runMigrations(db: Database): void {
  const applied = appliedVersions(db)
  const pending = [...migrations]
    .sort((a, b) => a.version - b.version)
    .filter((migration) => !applied.has(migration.version))

  for (const migration of pending) {
    const apply = db.transaction(() => {
      migration.up(db)
      db.prepare(
        'INSERT INTO migrations (version, name, applied_at) VALUES (?, ?, ?)'
      ).run(migration.version, migration.name, new Date().toISOString())
    })
    apply()
    console.log(`[db] applied migration ${migration.version} (${migration.name})`)
  }
}
