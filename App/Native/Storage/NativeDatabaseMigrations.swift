import Foundation

/// Frozen desktop migrations, executed by Swift SQLite. Existing version rows
/// are authoritative; no table is rebuilt merely to adopt the native runtime.
enum NativeDatabaseMigrations {
    struct Migration { let version: Int; let name: String; let statements: [String] }
    static func apply(to db: DesktopSQLite) throws {
        try db.exec("CREATE TABLE IF NOT EXISTS migrations(version INTEGER PRIMARY KEY,name TEXT NOT NULL,applied_at TEXT NOT NULL)")
        let applied = Set(try db.query("SELECT version FROM migrations", params: []).compactMap { ($0["version"] as? NSNumber)?.intValue })
        for migration in migrations where !applied.contains(migration.version) {
            try db.exec("SAVEPOINT native_migration")
            do {
                for block in migration.statements {
                    let cleaned = block.replacingOccurrences(of: #"(?m)^\s*--[^\n]*$"#, with: "", options: .regularExpression)
                    for raw in cleaned.components(separatedBy: ";") {
                        let sql = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if sql.isEmpty || sql.uppercased().hasPrefix("PRAGMA ") { continue }
                        if let range = sql.range(of: #"(?i)ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(\w+)"#, options: .regularExpression) {
                            let words = sql[range].split(whereSeparator: { $0.isWhitespace })
                            let table = String(words[2]), column = String(words[5])
                            if try db.query("PRAGMA table_info(\(table))", params: []).contains(where: { $0["name"] as? String == column }) { continue }
                        }
                        try db.exec(sql)
                    }
                }
                try migrateData(version: migration.version, db: db)
                _ = try db.run("INSERT INTO migrations(version,name,applied_at) VALUES(?,?,?)", params: [migration.version, migration.name, NativeRepositoryContext.nowISO])
                try db.exec("RELEASE SAVEPOINT native_migration")
            } catch {
                try? db.exec("ROLLBACK TO SAVEPOINT native_migration; RELEASE SAVEPOINT native_migration")
                throw error
            }
        }
        try db.exec("""
        CREATE TABLE IF NOT EXISTS material_tree_snapshots(course_id TEXT PRIMARY KEY REFERENCES courses(id) ON DELETE CASCADE,folder TEXT NOT NULL,tree TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS material_path_intents(id TEXT PRIMARY KEY,course_id TEXT NOT NULL,folder_path TEXT NOT NULL,folder_identity TEXT NOT NULL,from_rel_path TEXT NOT NULL,to_rel_path TEXT NOT NULL,original_identity TEXT NOT NULL,moved_identity TEXT,created_at TEXT NOT NULL,note_writes TEXT);
        """)
        if try !db.query("PRAGMA table_info(material_path_intents)", params: []).contains(where: { $0["name"] as? String == "note_writes" }) { try db.exec("ALTER TABLE material_path_intents ADD COLUMN note_writes TEXT") }
    }
    private static func migrateData(version: Int, db: DesktopSQLite) throws {
        if version == 8 {
            var taken = Set<String>()
            for row in try db.query("SELECT course_id,descriptor_json FROM favorites WHERE deleted_at IS NULL", params: []) {
                let descriptor = (try? NativeRepositoryContext.jsonObject(row["descriptor_json"] as? String ?? "{}")) as? [String: Any]
                taken.insert((row["course_id"] as? String ?? "") + "\u{0}" + ((descriptor?["payload"] as? [String: Any])?["initialUrl"] as? String ?? ""))
            }
            for row in try db.query("SELECT course_id,label,url FROM course_links ORDER BY course_id,sort_order", params: []) {
                guard let course = row["course_id"] as? String, let url = row["url"] as? String else { continue }
                let key = course + "\u{0}" + url
                if taken.contains(key) { continue }
                let order = try db.query("SELECT COALESCE(MAX(sort_order),-1)+1 AS value FROM favorites WHERE course_id IS ? AND deleted_at IS NULL", params: [course]).first?["value"] ?? 0
                let descriptor = try NativeRepositoryContext.json(["kind": "browser", "payload": ["tabId": UUID().uuidString.lowercased(), "initialUrl": url]])
                let now = NativeRepositoryContext.nowISO
                _ = try db.run("INSERT INTO favorites(id,course_id,label,descriptor_json,sort_order,created_at,updated_at) VALUES(?,?,?,?,?,?,?)", params: [UUID().uuidString.lowercased(), course, row["label"] ?? "", descriptor, order, now, now]); taken.insert(key)
            }
        } else if version == 16 {
            for row in try db.query("SELECT id FROM agent_sessions WHERE title IS NULL AND deleted_at IS NULL", params: []) {
                guard let id = row["id"] as? String else { continue }
                let body = try db.query("SELECT b.payload_json AS payload FROM messages m JOIN message_blocks b ON b.message_id=m.id WHERE m.session_id=? AND m.role='user' AND m.deleted_at IS NULL AND b.deleted_at IS NULL AND b.kind='text' ORDER BY m.turn_seq,b.ord LIMIT 1", params: [id]).first?["payload"] as? String
                let payload = body.flatMap { try? NativeRepositoryContext.jsonObject($0) } as? [String: Any]
                let text = (payload?["text"] as? String ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { _ = try db.run("UPDATE agent_sessions SET title=? WHERE id=?", params: [String(text.prefix(60)), id]) }
            }
        } else if version == 23 {
            let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallback = ISO8601DateFormatter()
            let calendar = Calendar.current
            for row in try db.query("SELECT id,due_at FROM board_tasks WHERE all_day=1 AND due_at LIKE '%T%'", params: []) {
                guard let id = row["id"] as? String, let text = row["due_at"] as? String, let date = parser.date(from: text) ?? fallback.date(from: text) else { throw NativeRepositoryContext.validation("Invalid all-day due date; migration was rolled back") }
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                let value = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
                _ = try db.run("UPDATE board_tasks SET due_at=? WHERE id=?", params: [value, id])
            }
        }
    }

    static let migrations: [Migration] = [
        Migration(version: 1, name: "initial-schema", statements: [
            #"""
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
            """#,
        ]),
        Migration(version: 2, name: "agent-session-resume-record", statements: [
            #"""
            ALTER TABLE agent_sessions ADD COLUMN transcript_path TEXT;
                     ALTER TABLE agent_sessions ADD COLUMN launch_config_json TEXT;
            """#,
        ]),
        Migration(version: 3, name: "course-folder-source", statements: [
            #"""
            ALTER TABLE courses ADD COLUMN source TEXT NOT NULL DEFAULT 'managed';
                     CREATE INDEX IF NOT EXISTS idx_courses_folder_path
                       ON courses (folder_path) WHERE deleted_at IS NULL;
            """#,
        ]),
        Migration(version: 4, name: "course-links", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS course_links (
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
                       ON course_links (course_id, sort_order);
            """#,
        ]),
        Migration(version: 5, name: "phase2-group-links-and-cache", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS course_group_links (
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
                     );
            """#,
        ]),
        Migration(version: 6, name: "pdf-drawings", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS pdf_drawings (
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
                       ON pdf_drawings (course_id, rel_path, page) WHERE deleted_at IS NULL;
            """#,
        ]),
        Migration(version: 7, name: "favorites", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS favorites (
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
                       ON favorites (course_id, sort_order) WHERE deleted_at IS NULL;
            """#,
        ]),
        Migration(version: 8, name: "course-links-into-favorites", statements: [
        ]),
        Migration(version: 9, name: "activity-events", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS activity_events (
                       id         TEXT PRIMARY KEY,
                       course_id  TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
                       kind       TEXT NOT NULL,
                       rel_path   TEXT,
                       summary    TEXT NOT NULL,
                       created_at TEXT NOT NULL
                     );
                     CREATE INDEX IF NOT EXISTS idx_activity_course_time
                       ON activity_events (course_id, created_at DESC);
            """#,
        ]),
        Migration(version: 10, name: "whiteboard-local-mirror", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS whiteboard_shapes_cache (
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
                     );
            """#,
        ]),
        Migration(version: 11, name: "personal-whiteboards", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS whiteboards (
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
                       WHERE deleted_at IS NULL;
            """#,
        ]),
        Migration(version: 12, name: "board-task-kind-and-allday", statements: [
            #"""
            ALTER TABLE board_tasks ADD COLUMN kind TEXT NOT NULL DEFAULT 'task'
            """#,
            #"""
            ALTER TABLE board_tasks ADD COLUMN all_day INTEGER NOT NULL DEFAULT 0
            """#,
            #"""
            CREATE INDEX IF NOT EXISTS idx_board_tasks_due
                       ON board_tasks (due_at) WHERE deleted_at IS NULL AND due_at IS NOT NULL;
            """#,
        ]),
        Migration(version: 13, name: "whiteboard-background", statements: [
            #"""
            ALTER TABLE whiteboards ADD COLUMN background TEXT NOT NULL DEFAULT 'grid'
            """#,
            #"""
            ALTER TABLE whiteboards ADD COLUMN surface TEXT NOT NULL DEFAULT 'dark'
            """#,
        ]),
        Migration(version: 14, name: "whiteboard-pages", statements: [
            #"""
            ALTER TABLE whiteboards ADD COLUMN page_count INTEGER NOT NULL DEFAULT 1
            """#,
            #"""
            ALTER TABLE whiteboard_local_shapes ADD COLUMN page INTEGER NOT NULL DEFAULT 1
            """#,
            #"""
            CREATE INDEX IF NOT EXISTS idx_wb_local_board_page
                       ON whiteboard_local_shapes (board_id, page)
                       WHERE deleted_at IS NULL;
            """#,
        ]),
        Migration(version: 15, name: "agent-actions", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS agent_actions (
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
                       ON agent_actions (turn_id, created_at);
            """#,
        ]),
        Migration(version: 16, name: "agent-session-titles", statements: [
            #"""
            ALTER TABLE agent_sessions ADD COLUMN title TEXT
            """#,
            #"""
            CREATE INDEX IF NOT EXISTS idx_agent_sessions_course_recency
                       ON agent_sessions (course_id, last_used_at DESC)
                       WHERE deleted_at IS NULL;
            """#,
        ]),
        Migration(version: 17, name: "course-groups", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS course_groups (
                       id         TEXT PRIMARY KEY,
                       name       TEXT NOT NULL,
                       sort_order INTEGER NOT NULL DEFAULT 0,
                       created_at TEXT NOT NULL,
                       updated_at TEXT NOT NULL,
                       deleted_at TEXT
                     );
            """#,
            #"""
            ALTER TABLE courses ADD COLUMN group_id TEXT REFERENCES course_groups(id)
            """#,
            #"""
            CREATE INDEX IF NOT EXISTS idx_courses_group
                       ON courses (group_id, sort_order) WHERE deleted_at IS NULL;
            """#,
        ]),
        Migration(version: 18, name: "media-progress", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS media_progress (
                       course_id     TEXT NOT NULL REFERENCES courses(id),
                       rel_path      TEXT NOT NULL,
                       position_sec  REAL NOT NULL,
                       duration_sec  REAL,
                       playback_rate REAL NOT NULL DEFAULT 1,
                       updated_at    TEXT NOT NULL,
                       PRIMARY KEY (course_id, rel_path)
                     );
            """#,
        ]),
        Migration(version: 19, name: "browser-history", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS browser_history (
                       url             TEXT PRIMARY KEY,
                       title           TEXT NOT NULL,
                       host            TEXT NOT NULL,
                       course_id       TEXT,
                       visit_count     INTEGER NOT NULL DEFAULT 1,
                       last_visited_at TEXT NOT NULL
                     );
            """#,
            #"""
            CREATE INDEX IF NOT EXISTS idx_browser_history_visited
                       ON browser_history (last_visited_at DESC);
            """#,
            #"""
            CREATE INDEX IF NOT EXISTS idx_browser_history_host
                       ON browser_history (host);
            """#,
        ]),
        Migration(version: 20, name: "browser-agent-grants-audit", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS browser_grants (
                       id           TEXT PRIMARY KEY,
                       course_id    TEXT NOT NULL,
                       origin       TEXT NOT NULL,
                       capability   TEXT NOT NULL,
                       created_at   TEXT NOT NULL,
                       expires_at   TEXT NOT NULL,
                       revoked_at   TEXT,
                       last_used_at TEXT
                     );
            """#,
            #"""
            CREATE INDEX IF NOT EXISTS idx_browser_grants_lookup
                       ON browser_grants (course_id, origin);
            """#,
            #"""
            CREATE TABLE IF NOT EXISTS browser_audit (
                       id         TEXT PRIMARY KEY,
                       course_id  TEXT NOT NULL,
                       run_id     TEXT NOT NULL,
                       action     TEXT NOT NULL,
                       url        TEXT NOT NULL,
                       detail     TEXT NOT NULL,
                       created_at TEXT NOT NULL
                     );
            """#,
            #"""
            CREATE INDEX IF NOT EXISTS idx_browser_audit_course
                       ON browser_audit (course_id, created_at DESC);
            """#,
            #"""
            CREATE TABLE IF NOT EXISTS browser_seen (
                       course_id  TEXT NOT NULL,
                       list_key   TEXT NOT NULL,
                       item_key   TEXT NOT NULL,
                       title      TEXT NOT NULL,
                       first_seen TEXT NOT NULL,
                       PRIMARY KEY (course_id, list_key, item_key)
                     );
            """#,
        ]),
        Migration(version: 21, name: "browser-site-permissions", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS browser_permissions (
                       id         TEXT PRIMARY KEY,
                       origin     TEXT NOT NULL,
                       permission TEXT NOT NULL,
                       decision   TEXT NOT NULL,
                       decided_at TEXT NOT NULL,
                       UNIQUE (origin, permission)
                     );
            """#,
        ]),
        Migration(version: 22, name: "desktop-surface-and-mcp", statements: [
            #"""
            ALTER TABLE agent_sessions ADD COLUMN surface TEXT NOT NULL DEFAULT 'app'
            """#,
            #"""
            CREATE INDEX IF NOT EXISTS idx_agent_sessions_surface
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
                       ON desktop_audit (course_id, created_at DESC);
            """#,
        ]),
        Migration(version: 23, name: "all-day-due-date", statements: [
        ]),
        Migration(version: 24, name: "material-links", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS material_links (
                       id          TEXT PRIMARY KEY,
                       course_id   TEXT NOT NULL,
                       source_json TEXT NOT NULL,
                       target_json TEXT NOT NULL,
                       label       TEXT NOT NULL DEFAULT '',
                       created_at  TEXT NOT NULL
                     );
                     CREATE INDEX IF NOT EXISTS idx_material_links_course
                       ON material_links (course_id);
            """#,
        ]),
        Migration(version: 25, name: "pdf-view-state", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS pdf_view_state (
                       course_id  TEXT NOT NULL,
                       rel_path   TEXT NOT NULL,
                       page       INTEGER NOT NULL,
                       zoom       REAL NOT NULL DEFAULT 1,
                       updated_at TEXT NOT NULL,
                       PRIMARY KEY (course_id, rel_path)
                     )
            """#,
        ]),
        Migration(version: 26, name: "agent-usage-ledger", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS agent_usage (
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
                       ON agent_usage (provider, turn_at);
            """#,
        ]),
        Migration(version: 27, name: "whiteboard-shared-assets", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS whiteboard_assets_cache (
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
                       WHERE pending = 1;
            """#,
        ]),
        Migration(version: 28, name: "typed-material-links", statements: [
            #"""
            ALTER TABLE material_links
                         ADD COLUMN kind TEXT NOT NULL DEFAULT 'related'
            """#,
            #"""
            ALTER TABLE material_links ADD COLUMN metadata_json TEXT
            """#,
            #"""
            UPDATE material_links SET kind = 'sequence' WHERE label = 'next';
                     CREATE INDEX IF NOT EXISTS idx_material_links_kind
                       ON material_links (course_id, kind);
            """#,
        ]),
        Migration(version: 29, name: "friends-direct-chat-and-course-sharing-cache", statements: [
            #"""
            ALTER TABLE course_group_links ADD COLUMN kind_cache TEXT NOT NULL DEFAULT 'study'
            """#,
            #"""
            ALTER TABLE course_group_links ADD COLUMN direct_peer_id TEXT
            """#,
            #"""
            CREATE INDEX IF NOT EXISTS idx_course_group_links_kind
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
                     );
            """#,
        ]),
        Migration(version: 30, name: "board-task-colors", statements: [
            #"""
            ALTER TABLE board_tasks ADD COLUMN color TEXT NOT NULL DEFAULT 'none'
            """#,
        ]),
        Migration(version: 31, name: "friend-conversation-previews", statements: [
            #"""
            ALTER TABLE friends_cache ADD COLUMN last_message_preview TEXT
            """#,
            #"""
            ALTER TABLE friends_cache ADD COLUMN last_message_at TEXT
            """#,
        ]),
        Migration(version: 32, name: "lecture-recordings", statements: [
            #"""
            
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
            """#,
        ]),
        Migration(version: 33, name: "chat-reasoning-effort", statements: [
            #"""
            ALTER TABLE agent_sessions ADD COLUMN effort TEXT
            """#,
        ]),
        Migration(version: 34, name: "board-task-schedule-range", statements: [
            #"""
            ALTER TABLE board_tasks ADD COLUMN start_at TEXT
            """#,
        ]),
        Migration(version: 35, name: "conversation-access-policy", statements: [
            #"""
            ALTER TABLE agent_sessions ADD COLUMN access_policy TEXT
            """#,
        ]),
        Migration(version: 36, name: "course-workspace-kind", statements: [
            #"""
            ALTER TABLE courses ADD COLUMN workspace_kind TEXT NOT NULL DEFAULT 'course' CHECK (workspace_kind IN ('course','study-space'))
            """#,
        ]),
        Migration(version: 37, name: "material-added-state", statements: [
            #"""
            CREATE TABLE IF NOT EXISTS material_added_baselines (
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
                  WHERE deleted_at IS NULL;
            """#,
            #"""
            ALTER TABLE whiteboards ADD COLUMN added_at INTEGER
            """#,
        ]),
    ]
}
