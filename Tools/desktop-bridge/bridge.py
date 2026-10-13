#!/usr/bin/env python3
"""Local desktop adapter and Supabase sync client; no third-party Python packages.

Export reads desktop data without mutations. Import is explicit and preserves
unrecognized desktop columns/shape fields. Watch is an explicitly invoked process,
not an installed background service. Credentials are read from environment only.
"""
from __future__ import annotations
import argparse
import base64
import contextlib
import datetime as dt
import hashlib
import json
import mimetypes
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

KINDS = {"course", "material", "note", "drawing", "annotation", "board", "task",
         "calendarEvent", "recording", "favorite", "chat", "learningEvent",
         "vocabulary", "flashcard", "quiz", "artifact"}
COORDINATES = "unrotated-crop-box-top-left-normalized"


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(part)
    return hasher.hexdigest()


def inside(root, relative):
    root = Path(root).resolve()
    value = (root / relative).resolve()
    if value == root or root not in value.parents:
        raise ValueError(f"Unsafe material path: {relative}")
    return value


def open_desktop(path, write=False):
    path = Path(path).resolve()
    if not path.is_file():
        raise ValueError("Desktop database does not exist")
    db = sqlite3.connect(path.as_uri() + ("?mode=rw" if write else "?mode=ro"), uri=True, timeout=10)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    return db


def table_exists(db, name):
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def rows(db, table, where="", parameters=()):
    if not table_exists(db, table):
        return []
    return [dict(row) for row in db.execute(f'SELECT * FROM "{table}" {where}', parameters)]


class Exchange:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.assets = self.root / "assets"
        self.assets.mkdir(exist_ok=True)
        self.db = sqlite3.connect(self.root / "bandal.sqlite")
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
          PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
          CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY,kind TEXT NOT NULL,payload BLOB NOT NULL,
            revision INTEGER NOT NULL,deleted INTEGER NOT NULL,format_version INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS outbox(sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,
            record_id TEXT NOT NULL,operation BLOB NOT NULL);
          CREATE INDEX IF NOT EXISTS outbox_record ON outbox(record_id);
          CREATE TABLE IF NOT EXISTS conflicts(id TEXT PRIMARY KEY,value BLOB NOT NULL);
          CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS desktop_map(record_id TEXT PRIMARY KEY,source BLOB NOT NULL,baseline TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS asset_metadata(hash TEXT PRIMARY KEY,metadata BLOB NOT NULL);
        """)
        with self.db:
            if not self.db.execute("SELECT 1 FROM metadata WHERE key='projection_recovery_version'").fetchone():
                if self.db.execute("SELECT 1 FROM records LIMIT 1").fetchone(): self.begin_projection()
                self.db.execute("INSERT INTO metadata VALUES('projection_recovery_version','1')")

    def get(self, record_id):
        row = self.db.execute("SELECT * FROM records WHERE id=?", (record_id,)).fetchone()
        return dict(row) if row else None

    def records(self, kind=None):
        return [dict(row) for row in self.db.execute("SELECT * FROM records" + (" WHERE kind=?" if kind else ""),
                                                   (kind,) if kind else ())]

    def projection_pending(self):
        return self.db.execute("SELECT 1 FROM metadata WHERE key='pending_projection'").fetchone() is not None

    def begin_projection(self):
        self.db.execute("INSERT INTO metadata VALUES('pending_projection','1') ON CONFLICT(key) DO UPDATE SET value='1'")

    def finish_projection(self):
        with self.db:
            self.db.execute("DELETE FROM metadata WHERE key='pending_projection'")

    def mapping(self, record_id):
        row = self.db.execute("SELECT source,baseline FROM desktop_map WHERE record_id=?", (record_id,)).fetchone()
        return (json.loads(row[0]), row[1]) if row else (None, None)

    def remember(self, record_id, source, payload):
        self.db.execute("INSERT INTO desktop_map VALUES(?,?,?) ON CONFLICT(record_id) DO UPDATE SET source=excluded.source,baseline=excluded.baseline",
                        (record_id, encoded(source), digest(encoded(payload))))

    def set_record(self, record):
        self.db.execute("INSERT INTO records VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,payload=excluded.payload,revision=excluded.revision,deleted=excluded.deleted,format_version=excluded.format_version",
                        (record["id"], record["kind"], base64.b64decode(record["payload"], validate=True),
                         record["revision"], record["deleted"], record["formatVersion"]))

    def export_record(self, record_id, kind, payload, source, deleted=False):
        old_source, baseline = self.mapping(record_id)
        previous = self.get(record_id)
        # The desktop hasn't changed since the last export/import: don't replace
        # a newer remote record that is waiting to be applied locally.
        if kind == "drawing" and previous and old_source and source.get("inkFingerprint") == old_source.get("inkFingerprint"):
            return
        if baseline == digest(encoded(payload)) and previous and previous["deleted"] == deleted:
            return
        if previous and json.loads(previous["payload"]) == payload and bool(previous["deleted"]) == deleted:
            self.remember(record_id, source, payload)
            return
        revision = previous["revision"] if previous else 0
        record = {"id": record_id, "kind": kind, "payload": base64.b64encode(encoded(payload)).decode(),
                  "revision": revision + 1, "deleted": bool(deleted), "formatVersion": 1}
        operation = {"id": str(uuid.uuid4()), "baseRevision": revision, "record": record}
        with self.db:
            self.set_record(record)
            self.db.execute("INSERT INTO outbox(id,record_id,operation) VALUES(?,?,?)",
                            (operation["id"], record_id, encoded(operation)))
            self.remember(record_id, source, payload)

    def asset(self, source):
        sha = file_hash(source)
        target = self.assets / sha
        if not target.exists():
            temporary = self.assets / (str(uuid.uuid4()) + ".partial")
            try:
                shutil.copyfile(source, temporary)
                if file_hash(temporary) != sha:
                    raise ValueError("Source changed while snapshotting asset")
                os.replace(temporary, target)
            finally:
                temporary.unlink(missing_ok=True)
        metadata = {"sha256": sha, "byteCount": target.stat().st_size, "originalName": Path(source).name,
                    "contentType": mimetypes.guess_type(source)[0] or "application/octet-stream"}
        self.db.execute("INSERT OR REPLACE INTO asset_metadata VALUES(?,?)", (sha, encoded(metadata)))
        return sha


def geometry_for(path, exchange):
    sha = file_hash(path)
    cache = exchange.root / ("geometry-" + sha + ".json")
    if cache.exists():
        return json.loads(cache.read_bytes())
    helper = Path(__file__).with_name("pdf_geometry.swift")
    result = subprocess.run(["swift", str(helper), str(path)], capture_output=True, check=True)
    geometry = json.loads(result.stdout)
    cache.write_bytes(encoded(geometry))
    return geometry


def rotate_point(x, y, rotation, inverse=False):
    rotation = rotation % 360
    if inverse:
        rotation = (-rotation) % 360
    if rotation == 0: return x, y
    if rotation == 90: return y, 1 - x
    if rotation == 180: return 1 - x, 1 - y
    if rotation == 270: return 1 - y, x
    raise ValueError("Unsupported PDF rotation")


def convert_box(box, rotation, inverse=False):
    corners = [rotate_point(x, y, rotation, inverse) for x, y in
               [(box["x"], box["y"]), (box["x"] + box["width"], box["y"] + box["height"])]]
    x, y = min(p[0] for p in corners), min(p[1] for p in corners)
    return {"x": x, "y": y, "width": abs(corners[1][0] - corners[0][0]), "height": abs(corners[1][1] - corners[0][1])}


def convert_shape(shape, geometry, inverse=False):
    shape = json.loads(json.dumps(shape))
    rotation = geometry["rotation"]
    data, style = shape["data"], shape["style"]
    for point in data.get("points", []):
        point["x"], point["y"] = rotate_point(point["x"], point["y"], rotation, inverse)
    if "box" in data:
        data["box"] = convert_box(data["box"], rotation, inverse)
    if rotation in (90, 270):
        ratio = geometry["height"] / geometry["width"]
        style["width"] *= (1 / ratio if inverse else ratio)
    return shape


def ink_fingerprint(drawings, annotations):
    def normalize(row):
        return {key: json.loads(value) if key.endswith("_json") else value
                for key, value in row.items() if key not in ("created_at", "updated_at")}
    return digest(encoded({"drawings": sorted([normalize(row) for row in drawings], key=lambda r: r["id"]),
                           "annotations": sorted([normalize(row) for row in annotations], key=lambda r: r["id"])}))


def bound_pdf_identity(db, course_id, relative, revision):
    """Honor the canonical revision even in the old projector migration path.

    This fallback is read-only: it cannot invent historical evidence for old
    path-only drawings. The current TypeScript projector owns new bindings.
    """
    identity = None
    revisions = set()
    if table_exists(db, "pdf_document_aliases") and table_exists(db, "pdf_document_bindings"):
        binding = db.execute("""SELECT b.material_id,b.bound_sha FROM pdf_document_aliases a
            JOIN pdf_document_bindings b ON b.material_id=a.material_id
            WHERE a.course_id=? AND a.rel_path=?""", (course_id, relative)).fetchone()
        if binding:
            identity = binding["material_id"]; revisions.add(binding["bound_sha"])
    if table_exists(db, "drawing_create_receipts"):
        for receipt in db.execute("""SELECT r.request_json FROM drawing_create_receipts r
                JOIN pdf_drawings d ON d.id=r.drawing_id WHERE d.course_id=? AND d.rel_path=?""", (course_id, relative)):
            value = json.loads(receipt["request_json"]).get("documentRevision")
            if value is not None: revisions.add(value)
    if any(not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value) for value in revisions):
        raise ValueError("Invalid preserved PDF revision; recovery records were retained")
    if revisions and revisions != {revision}:
        raise ValueError("PDF revision differs from its preserved ink; original files and drawings were retained")
    return identity


@contextlib.contextmanager
def material_path_lock(desktop):
    # Same OS-released SQLite lock as the application and current projector.
    # Legacy migration must never scan half of a live rename into tombstones.
    lock = sqlite3.connect(Path(desktop).parent / "material-path-lock.db", timeout=0, isolation_level=None)
    try:
        lock.execute("BEGIN EXCLUSIVE")
        yield
    finally:
        if lock.in_transaction: lock.execute("ROLLBACK")
        lock.close()


def require_settled_material_paths(db):
    if table_exists(db, "material_path_intents") and db.execute("SELECT 1 FROM material_path_intents LIMIT 1").fetchone():
        raise ValueError("Recover interrupted material paths in Bandal before using the legacy bridge; files and records were retained")


def export_desktop(desktop, exchange, geometry_reader=geometry_for, use_projector=True):
    if exchange.projection_pending(): raise ValueError("Recover pending desktop import before exporting local documents")
    if use_projector and os.environ.get("BANDAL_DESKTOP_PROJECTOR"):
        return projector_export(desktop, exchange)
    counts = {"courses": 0, "materials": 0, "pages": 0, "tasks": 0}
    with material_path_lock(desktop), contextlib.closing(open_desktop(desktop)) as db:
        # A consistent DB read snapshot; each source file is hash-checked separately.
        db.execute("BEGIN")
        require_settled_material_paths(db)
        for course in rows(db, "courses"):
            cid = course["id"]
            course_payload = {"id": cid, "name": course["name"], "color": course["color"]}
            exchange.export_record("course:" + cid, "course", course_payload, course, bool(course.get("deleted_at")))
            counts["courses"] += 1
            if course.get("deleted_at"): continue
            root = Path(course["folder_path"])
            if not root.is_dir():
                raise ValueError(f"Course folder is unavailable: {root}")
            indexed = {row["rel_path"]: row for row in rows(db, "materials_index", "WHERE course_id=?", (cid,))}
            # Files are authoritative; include uncached recent notes/imports and
            # preserve image/other assets rather than skipping unrecognized types.
            paths = [p for p in root.rglob("*") if p.is_file() and not any(part.startswith(".") for part in p.relative_to(root).parts)]
            for path in sorted(paths):
                relative = path.relative_to(root).as_posix()
                path = inside(root, relative)
                item = indexed.get(relative)
                material_id = item["id"] if item else str(uuid.uuid5(uuid.UUID(cid), relative))
                # Reuse identity from previous exports even if the rebuildable index changed.
                for mapped in exchange.db.execute("SELECT record_id,source FROM desktop_map WHERE record_id LIKE 'material:%'"):
                    source = json.loads(mapped["source"])
                    if source.get("course_id") == cid and source.get("rel_path") == relative:
                        material_id = mapped["record_id"].removeprefix("material:"); break
                extension = path.suffix.lower()
                kind = "pdf" if extension == ".pdf" else "note" if extension in (".md", ".markdown") else "image" if extension in (".png", ".jpg", ".jpeg", ".heic", ".webp", ".gif") else "file"
                sha = exchange.asset(path)
                if kind == "pdf":
                    material_id = bound_pdf_identity(db, cid, relative, sha) or material_id
                source = dict(item or {}); source.update(course_id=cid, rel_path=relative, hash=sha)
                previous_material = exchange.get("material:" + material_id)
                if kind == "pdf" and previous_material and json.loads(previous_material["payload"])["revision"] != sha:
                    if rows(db, "pdf_drawings", "WHERE course_id=? AND rel_path=?", (cid, relative)) or rows(db, "annotations", "WHERE course_id=? AND rel_path=?", (cid, relative)):
                        raise ValueError("PDF revision changed since the previous ink export; old ink was not relabeled")
                # Desktop has no folder/page-note columns. Retain all unprojected
                # fields so a roundtrip cannot detach iPad relationships.
                payload = json.loads(previous_material["payload"]) if previous_material else {}
                payload.update({"id": material_id, "courseID": cid, "title": path.stem, "fileName": path.name,
                           "revision": sha, "kind": kind, "byteCount": path.stat().st_size,
                           "createdAt": source.get("created_at", course["created_at"])})
                exchange.export_record("material:" + material_id, "material", payload, source)
                counts["materials"] += 1
                if kind == "note":
                    content = {"materialID": material_id, "markdown": path.read_text(encoding="utf-8")}
                    exchange.export_record("note:" + material_id, "note", content, source)
                if kind != "pdf": continue
                drawings = rows(db, "pdf_drawings", "WHERE course_id=? AND rel_path=? AND deleted_at IS NULL", (cid, relative))
                annotations = rows(db, "annotations", "WHERE course_id=? AND rel_path=? AND deleted_at IS NULL", (cid, relative))
                known_pages = set(row["page"] for row in drawings + annotations)
                # Include previously exported pages that were cleared on desktop.
                prefix = f"drawing:{material_id}:{sha}:"
                for record in exchange.records("drawing"):
                    if record["id"].startswith(prefix): known_pages.add(int(record["id"].split(":")[-1]))
                if not known_pages: continue
                geometry = geometry_reader(path, exchange)
                for page in sorted(known_pages):
                    if page < 1 or page > len(geometry):
                        raise ValueError(f"Annotation page is missing from PDF: {relative}, page {page}")
                    bounds = geometry[page - 1]
                    objects = []
                    for drawing in drawings:
                        if drawing["page"] != page: continue
                        shape = {"id": drawing["id"], "kind": drawing["kind"], "data": json.loads(drawing["data_json"]),
                                 "style": json.loads(drawing["style_json"]), "createdAt": drawing["created_at"], "updatedAt": drawing["updated_at"]}
                        if shape["kind"] == "image" and shape["data"].get("image"):
                            image = shape["data"]["image"]
                            source_material = indexed.get(image["relPath"])
                            image["assetId"] = source_material["id"] if source_material else str(uuid.uuid5(uuid.UUID(cid), image["relPath"]))
                        objects.append(convert_shape(shape, bounds))
                    highlights = []
                    for annotation in annotations:
                        if annotation["page"] != page: continue
                        anchor = json.loads(annotation["anchor_json"])
                        highlights.append({"id": annotation["id"], **anchor,
                                           "rects": [convert_box(rect, bounds["rotation"]) for rect in json.loads(annotation["rects_json"])],
                                           "color": annotation["color"], "comment": annotation["comment"],
                                           "createdAt": annotation["created_at"], "updatedAt": annotation["updated_at"]})
                    portable = {"schemaVersion": 1, "materialID": material_id, "documentRevision": sha,
                                "page": page, "coordinateSpace": COORDINATES, "geometry": bounds,
                                "objects": objects, "highlights": highlights}
                    prior_record = exchange.get(prefix + str(page))
                    if prior_record:
                        prior = json.loads(base64.b64decode(json.loads(prior_record["payload"])["data"], validate=True))
                        for collection, deleted_key in [("objects", "deletedObjectIDs"), ("highlights", "deletedHighlightIDs")]:
                            active = {item["id"] for item in portable[collection]}
                            removed = {item["id"] for item in prior.get(collection, [])} - active
                            portable[deleted_key] = sorted(set(prior.get(deleted_key, [])) | removed)
                    wrapper = {"materialID": material_id, "documentRevision": sha, "page": page,
                               "data": base64.b64encode(encoded(portable)).decode()}
                    fingerprint = ink_fingerprint([row for row in drawings if row["page"] == page],
                                                  [row for row in annotations if row["page"] == page])
                    exchange.export_record(prefix + str(page), "drawing", wrapper,
                                           {**source, "geometry": bounds, "inkFingerprint": fingerprint})
                    counts["pages"] += 1
        for task in rows(db, "board_tasks"):
            if not task.get("course_id"): continue  # Global tasks have no iPad course yet; remain untouched.
            payload = {"id": task["id"], "courseID": task["course_id"], "title": task["title"], "completed": task["status"] == "done"}
            if task.get("due_at"): payload["due"] = task["due_at"]
            exchange.export_record("task:" + task["id"], "task", payload, task, bool(task.get("deleted_at")))
            counts["tasks"] += 1
    exchange.db.commit()
    return counts


def upsert_desktop(db, table, values):
    # Preserve columns added by newer desktop versions, and omit only unknown
    # incoming columns rather than reconstructing an existing row from scratch.
    columns = {row[1] for row in db.execute(f'PRAGMA table_info("{table}")')}
    values = {key: value for key, value in values.items() if key in columns}
    keys = list(values)
    insert_columns = ",".join('"' + key + '"' for key in keys)
    updates = ",".join('"' + key + '"=excluded."' + key + '"' for key in keys if key != "id")
    db.execute(f'INSERT INTO "{table}" ({insert_columns}) VALUES ({",".join("?" for _ in keys)}) ON CONFLICT(id) DO UPDATE SET {updates}', list(values.values()))


def recover_import(db, exchange):
    journal_path = exchange.root / "import-journal.json"
    if not journal_path.exists(): return
    journal = json.loads(journal_path.read_bytes())
    committed = table_exists(db, "_bandal_bridge_commits") and db.execute("SELECT 1 FROM _bandal_bridge_commits WHERE id=?", (journal["id"],)).fetchone()
    for item in reversed(journal["files"]):
        target, backup = Path(item["target"]), Path(item["backup"])
        if not committed:
            if item["existed"] and backup.exists(): os.replace(backup, target)
            elif not item["existed"]: target.unlink(missing_ok=True)
        # Successful imports keep immutable recovery copies; never discard the
        # only copy of a file changed concurrently by a desktop editor.
        if not committed: backup.unlink(missing_ok=True)
    journal_path.unlink()


def import_desktop(desktop, exchange, course_root=None, use_projector=True):
    if use_projector and os.environ.get("BANDAL_DESKTOP_PROJECTOR"):
        return projector_import(desktop, exchange, course_root)
    counts = {"courses": 0, "materials": 0, "pages": 0, "tasks": 0}
    with material_path_lock(desktop), contextlib.closing(open_desktop(desktop, write=True)) as db:
        require_settled_material_paths(db)
        recover_import(db, exchange)
        db.execute("CREATE TABLE IF NOT EXISTS _bandal_bridge_commits(id TEXT PRIMARY KEY)")
        db.commit()
        changes = []
        files = []
        material_map = {}
        checked_pages = []
        timestamp = now()
        for record in exchange.records("course"):
            payload = json.loads(record["payload"]); cid = payload["id"]
            existing = db.execute("SELECT * FROM courses WHERE id=?", (cid,)).fetchone()
            if existing:
                values = dict(existing)
                _, baseline = exchange.mapping(record["id"])
                current_payload = {"id": cid, "name": values["name"], "color": values["color"]}
                if baseline and digest(encoded(current_payload)) != baseline and current_payload != payload:
                    raise ValueError("Desktop course changed since export")
            else:
                if not course_root: raise ValueError("New courses require --course-root; existing course folders are never guessed")
                folder = inside(course_root, cid)
                values = {"id": cid, "slug": cid, "folder_path": str(folder), "archived": 0, "sort_order": 0, "created_at": timestamp}
            values.update(name=payload["name"], color=payload["color"], updated_at=timestamp,
                          deleted_at=timestamp if record["deleted"] else None)
            changes.append(("courses", values)); counts["courses"] += 1
        course_folders = {values["id"]: values["folder_path"] for table, values in changes if table == "courses"}
        for record in exchange.records("material"):
            payload = json.loads(record["payload"]); mid = payload["id"]
            source, _ = exchange.mapping(record["id"])
            source = source or {"course_id": payload["courseID"], "rel_path": f"iPad/{mid}/{payload['fileName']}"}
            folder = course_folders.get(payload["courseID"])
            if folder is None: raise ValueError("Material course is missing")
            target = inside(folder, source["rel_path"])
            existing_material = db.execute("SELECT rel_path FROM materials_index WHERE id=?", (mid,)).fetchone()
            if existing_material and existing_material[0] != source["rel_path"]:
                raise ValueError("Desktop material moved since export; import preserved its location")
            material_map[mid] = (payload, source, target)
            if record["deleted"]:
                if target.exists():
                    if source.get("hash") != file_hash(target): raise ValueError("Deleted material changed locally; retained for recovery")
                    files.append((target, None))
                if existing_material:
                    old = dict(db.execute("SELECT * FROM materials_index WHERE id=?", (mid,)).fetchone())
                    old.update(deleted_at=timestamp, updated_at=timestamp); changes.append(("materials_index", old))
                continue
            identity = bound_pdf_identity(db, payload["courseID"], source["rel_path"], payload["revision"])
            if identity is not None and (identity != mid or payload["kind"] != "pdf"):
                raise ValueError("PDF material identity or kind differs from its preserved binding")
            if identity is not None and target.exists():
                bound_pdf_identity(db, payload["courseID"], source["rel_path"], file_hash(target))
            if payload["kind"] == "whiteboard": continue
            if payload["kind"] == "note" and target.suffix.lower() not in (".md", ".markdown"):
                raise ValueError("A note cannot overwrite a non-Markdown material")
            note = exchange.get("note:" + mid) if payload["kind"] == "note" else None
            content = json.loads(note["payload"])["markdown"].encode() if note and not note["deleted"] else None
            asset = exchange.assets / payload["revision"]
            if content is None:
                if not asset.is_file() or file_hash(asset) != payload["revision"]:
                    raise ValueError(f"Verified material asset is unavailable: {mid}")
                content = asset.read_bytes()
            if target.exists() and target.read_bytes() != content:
                baseline = source.get("hash")
                if baseline is None or file_hash(target) != baseline:
                    raise ValueError(f"Desktop file changed since export; import preserved it: {target}")
            if not target.exists() or target.read_bytes() != content:
                files.append((target, content))
            values = {**source, "id": mid, "course_id": payload["courseID"], "rel_path": source["rel_path"],
                      "kind": payload["kind"], "size": len(content), "mtime": int(time.time() * 1000),
                      "created_at": source.get("created_at", timestamp), "updated_at": timestamp, "deleted_at": None}
            changes.append(("materials_index", values)); counts["materials"] += 1
        for record in exchange.records("drawing"):
            if record["deleted"]: continue
            wrapper = json.loads(record["payload"])
            portable = json.loads(base64.b64decode(wrapper["data"], validate=True))
            if portable.get("schemaVersion") != 1 or portable.get("coordinateSpace") != COORDINATES:
                raise ValueError("Unknown ink format preserved; no desktop import performed")
            mid = portable["materialID"]
            if mid not in material_map: raise ValueError("Ink material is missing")
            material, source, target = material_map[mid]
            if portable["documentRevision"] != material["revision"]:
                continue  # Historical revision retained in exchange, not applied to another PDF.
            geometry = portable["geometry"]
            page = portable["page"]
            cid, relative = material["courseID"], source["rel_path"]
            original, _ = exchange.mapping(record["id"])
            original_drawings = rows(db, "pdf_drawings", "WHERE course_id=? AND rel_path=? AND page=? AND deleted_at IS NULL", (cid, relative, page))
            original_annotations = rows(db, "annotations", "WHERE course_id=? AND rel_path=? AND page=? AND deleted_at IS NULL", (cid, relative, page))
            current_fingerprint = ink_fingerprint(original_drawings, original_annotations)
            if original and original.get("inkFingerprint") and original["inkFingerprint"] != current_fingerprint:
                raise ValueError("Desktop ink changed since export; import preserved both versions")
            if not original and (original_drawings or original_annotations):
                raise ValueError("Cannot overwrite untracked desktop ink")
            checked_pages.append((cid, relative, page, current_fingerprint))
            shape_ids = set()
            for shape in portable["objects"]:
                shape = convert_shape(shape, geometry, inverse=True)
                image = shape["data"].get("image")
                if image and image.get("assetId") in material_map:
                    image["relPath"] = material_map[image["assetId"]][1]["rel_path"]
                    # Desktop validators only accept assetId for shared assets;
                    # personal assets use course-relative paths.
                    image.pop("assetId", None); image.pop("storage", None)
                shape_ids.add(shape["id"])
                existing = db.execute("SELECT * FROM pdf_drawings WHERE id=?", (shape["id"],)).fetchone()
                values = dict(existing) if existing else {}
                # Unknown fields from the original geometry/style survive an iPad
                # edit even if an older native decoder didn't understand them.
                old_data = json.loads(values.get("data_json", "{}")); old_data.update(shape["data"])
                old_style = json.loads(values.get("style_json", "{}")); old_style.update(shape["style"])
                values.update(id=shape["id"], course_id=cid, rel_path=relative, page=page, kind=shape["kind"],
                              data_json=encoded(old_data).decode(), style_json=encoded(old_style).decode(),
                              created_at=shape["createdAt"], updated_at=shape["updatedAt"], deleted_at=None)
                changes.append(("pdf_drawings", values))
            # Page payloads represent a full page. Remove only known IDs previously
            # exported, never unrecognized concurrent desktop additions.
            old_page = original_drawings
            for old in old_page:
                if old["id"] not in shape_ids:
                    if original is None: raise ValueError("Cannot infer deletion of untracked desktop ink")
                    old.update(deleted_at=timestamp, updated_at=timestamp); changes.append(("pdf_drawings", old))
            highlight_ids = set()
            for highlight in portable.get("highlights", []):
                highlight_ids.add(highlight["id"])
                existing = db.execute("SELECT * FROM annotations WHERE id=?", (highlight["id"],)).fetchone()
                values = dict(existing) if existing else {}
                old_anchor = json.loads(values.get("anchor_json", "{}"))
                anchor = {key: highlight.get(key, old_anchor.get(key, "")) for key in ("quote", "prefix", "suffix")}
                values.update(id=highlight["id"], course_id=cid, rel_path=relative, page=page, color=highlight["color"],
                              rects_json=encoded([convert_box(rect, geometry["rotation"], True) for rect in highlight["rects"]]).decode(),
                              anchor_json=encoded(anchor).decode(), comment=highlight.get("comment", values.get("comment")),
                              created_at=highlight["createdAt"], updated_at=highlight.get("updatedAt", timestamp), deleted_at=None)
                changes.append(("annotations", values))
            for old in original_annotations:
                if old["id"] not in highlight_ids:
                    if original is None: raise ValueError("Cannot infer deletion of untracked desktop annotation")
                    old.update(deleted_at=timestamp, updated_at=timestamp); changes.append(("annotations", old))
            counts["pages"] += 1
        for record in exchange.records("task"):
            payload = json.loads(record["payload"])
            existing = db.execute("SELECT * FROM board_tasks WHERE id=?", (payload["id"],)).fetchone()
            values = dict(existing) if existing else {"id": payload["id"], "notes": "", "sort_order": 0, "created_at": timestamp}
            if existing:
                _, baseline = exchange.mapping(record["id"])
                current_payload = {"id": values["id"], "courseID": values["course_id"], "title": values["title"], "completed": values["status"] == "done"}
                if values.get("due_at"): current_payload["due"] = values["due_at"]
                if baseline and digest(encoded(current_payload)) != baseline and current_payload != payload:
                    raise ValueError("Desktop task changed since export")
            values.update(course_id=payload["courseID"], title=payload["title"], due_at=payload.get("due"),
                          status="done" if payload["completed"] else "todo", updated_at=timestamp,
                          deleted_at=timestamp if record["deleted"] else None)
            changes.append(("board_tasks", values)); counts["tasks"] += 1

        journal = {"id": str(uuid.uuid4()), "files": []}
        journal_path = exchange.root / "import-journal.json"
        for target, _ in files:
            target.parent.mkdir(parents=True, exist_ok=True)
            backup = exchange.root / "backups" / journal["id"] / (digest(str(target).encode()) + "-" + target.name)
            backup.parent.mkdir(parents=True, exist_ok=True)
            existed = target.exists()
            if existed: shutil.copy2(target, backup)
            journal["files"].append({"target": str(target), "backup": str(backup), "existed": existed})
        journal_path.write_bytes(encoded(journal))
        with open(journal_path, "rb") as handle: os.fsync(handle.fileno())
        try:
            db.execute("BEGIN IMMEDIATE")
            for cid, relative, page, fingerprint in checked_pages:
                fresh = ink_fingerprint(rows(db, "pdf_drawings", "WHERE course_id=? AND rel_path=? AND page=? AND deleted_at IS NULL", (cid, relative, page)),
                                        rows(db, "annotations", "WHERE course_id=? AND rel_path=? AND page=? AND deleted_at IS NULL", (cid, relative, page)))
                if fresh != fingerprint: raise ValueError("Desktop ink changed while preparing import")
            for table, values in changes: upsert_desktop(db, table, values)
            for target, content in files:
                if content is None:
                    target.unlink(missing_ok=True)
                    continue
                temporary = target.with_name(".bandal-write-" + str(uuid.uuid4()))
                try:
                    with open(temporary, "wb") as handle:
                        handle.write(content); handle.flush(); os.fsync(handle.fileno())
                    os.replace(temporary, target)
                finally: temporary.unlink(missing_ok=True)
            db.execute("INSERT INTO _bandal_bridge_commits VALUES(?)", (journal["id"],))
            db.commit()
        except BaseException:
            db.rollback(); recover_import(db, exchange); raise
        recover_import(db, exchange)
        # After import, refresh source baselines so our next scan cannot echo the
        # remote write back as a new local edit or resurrect a deleted shape.
        for mid, (material, source, target) in material_map.items():
            if target.exists(): source["hash"] = file_hash(target)
            exchange.remember("material:" + mid, source, material)
            note = exchange.get("note:" + mid)
            if note: exchange.remember("note:" + mid, source, json.loads(note["payload"]))
        for record in exchange.records("drawing"):
            source, _ = exchange.mapping(record["id"])
            source = source or {}
            wrapper = json.loads(record["payload"])
            mid = wrapper["materialID"]
            if mid in material_map:
                material, mapped, _ = material_map[mid]
                source.update(mapped)
                cid, relative, page = material["courseID"], mapped["rel_path"], wrapper["page"]
                source["inkFingerprint"] = ink_fingerprint(rows(db, "pdf_drawings", "WHERE course_id=? AND rel_path=? AND page=? AND deleted_at IS NULL", (cid, relative, page)),
                                                            rows(db, "annotations", "WHERE course_id=? AND rel_path=? AND page=? AND deleted_at IS NULL", (cid, relative, page)))
            exchange.remember(record["id"], source, wrapper)
        exchange.db.commit()
    exchange.finish_projection()
    return counts


def projector_call(desktop, exchange, action, request=None, course_root=None):
    helper = Path(os.environ["BANDAL_DESKTOP_PROJECTOR"]).resolve()
    runtime = os.environ.get("BANDAL_DESKTOP_RUNTIME")
    module_root = os.environ.get("BANDAL_DESKTOP_MODULE_ROOT")
    if not runtime or not module_root or not helper.is_file():
        raise ValueError("Desktop projector requires the app's Electron runtime and module root")
    bundle = Path(os.environ.get("BANDAL_DESKTOP_BACKEND", helper.with_name("backend.js")))
    if not bundle.is_file(): raise ValueError("Desktop projection backend bundle is missing")
    seed = []
    for row in exchange.db.execute("SELECT record_id,source FROM desktop_map"):
        record = exchange.get(row["record_id"])
        if record:
            seed.append({"record": {"id": record["id"], "kind": record["kind"], "payload": json.loads(record["payload"]),
                                    "deleted": bool(record["deleted"]), "formatVersion": record["format_version"]},
                         "source": json.loads(row["source"])})
    value = {"action": action, "database": str(Path(desktop).resolve()), "exchange": str(exchange.root),
             "courseRoot": str(Path(course_root or Path(desktop).parent / "iPad Courses").resolve()),
             "moduleRoot": module_root, "bundle": str(bundle), "request": request or {}, "seed": seed}
    if os.environ.get("BANDAL_DESKTOP_SQLITE_MODULE"): value["sqliteModule"] = os.environ["BANDAL_DESKTOP_SQLITE_MODULE"]
    environment = {key: item for key, item in os.environ.items() if key not in
                   {"BANDAL_ACCESS_TOKEN", "BANDAL_SUPABASE_KEY", "BANDAL_USER_ID", "BANDAL_SUPABASE_URL"}}
    environment["ELECTRON_RUN_AS_NODE"] = "1"
    result = subprocess.run([runtime, str(helper)], input=encoded(value), capture_output=True, env=environment, timeout=180)
    if result.returncode:
        raise ValueError("Desktop projection failed: " + result.stderr.decode("utf8", errors="replace")[-2000:])
    return json.loads(result.stdout)


def projector_export(desktop, exchange):
    if exchange.projection_pending(): raise ValueError("Recover pending desktop import before exporting local documents")
    marker = exchange.db.execute("SELECT value FROM metadata WHERE key='typescript-projector-v1'").fetchone()
    if not marker:
        # Finish the previous mapper's pending materialization using its original
        # optimistic guards before changing projection implementations. A local
        # conflict aborts here, retaining every queued operation and old baseline.
        if exchange.db.execute("SELECT 1 FROM desktop_map LIMIT 1").fetchone():
            export_desktop(desktop, exchange, use_projector=False)
            import_desktop(desktop, exchange, use_projector=False)
        exchange.db.execute("INSERT INTO metadata VALUES('typescript-projector-v1','ready')")
        exchange.db.commit()
    snapshot = projector_call(desktop, exchange, "export")
    for asset in snapshot["assets"]:
        actual = exchange.asset(asset["path"])
        if actual != asset["sha256"] or (exchange.assets / actual).stat().st_size != asset["byteCount"]:
            raise ValueError("Desktop source changed during projection snapshot")
    for record in snapshot["records"]:
        source, _ = exchange.mapping(record["id"])
        source = source or {}
        if record["kind"] == "drawing": source["inkFingerprint"] = digest(encoded(record["payload"]))
        exchange.export_record(record["id"], record["kind"], record["payload"], source, record["deleted"])
    exchange.db.commit()
    return {"records": len(snapshot["records"]), "assets": len(snapshot["assets"]), "projector": "desktop-typescript"}


def projector_import(desktop, exchange, course_root=None):
    records = [{"id": row["id"], "kind": row["kind"], "payload": json.loads(row["payload"]),
                "deleted": bool(row["deleted"]), "formatVersion": row["format_version"]} for row in exchange.records()]
    assets = [{"sha256": file.name, "path": str(file)} for file in exchange.assets.iterdir()
              if file.is_file() and len(file.name) == 64 and all(c in "0123456789abcdef" for c in file.name)]
    conflicts = []
    for row in exchange.db.execute("SELECT value FROM conflicts"):
        conflict = json.loads(row["value"])
        if not isinstance(conflict.get("local"), dict) or not isinstance(conflict.get("remote"), dict): continue
        for variant in ("local", "remote"):
            conflict[variant] = {**conflict[variant], "payload": json.loads(base64.b64decode(conflict[variant]["payload"], validate=True))}
        conflicts.append(conflict)
    result = projector_call(desktop, exchange, "import", {"records": records, "assets": assets, "conflicts": conflicts}, course_root)
    # The original documents or their visible conflict copies are now durable.
    # Unresolved projector records stay excluded from subsequent local exports.
    exchange.finish_projection()
    if result["conflicts"]:
        # Conflict entries and originals are durable in desktop SQLite/Recovery;
        # expose attention instead of declaring a successful invisible overwrite.
        raise ValueError(f"{len(result['conflicts'])} desktop sync conflicts are preserved for review")
    return result


class Supabase:
    def __init__(self, url, key, user_id, token):
        from urllib.parse import urlparse
        parsed = urlparse(url)
        if parsed.scheme != "https" and not (parsed.scheme == "http" and parsed.hostname in ("localhost", "127.0.0.1")):
            raise ValueError("Supabase requires HTTPS except localhost")
        self.url, self.key, self.user_id, self.token = url.rstrip("/"), key, str(uuid.UUID(user_id)), token
        subject = json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "==")).get("sub")
        if subject != self.user_id: raise ValueError("Access token belongs to another account")

    def request(self, path, body=None, method=None, content_type="application/json"):
        request = urllib.request.Request(self.url + "/" + path, data=body, method=method,
                                         headers={"apikey": self.key, "Authorization": "Bearer " + self.token,
                                                  "Content-Type": content_type, "x-upsert": "false"})
        try:
            class RejectRedirect(urllib.request.HTTPRedirectHandler):
                def redirect_request(self, req, fp, code, msg, headers, newurl):
                    raise RuntimeError("Refused authenticated request redirect")
            opener = urllib.request.build_opener(RejectRedirect())
            with opener.open(request, timeout=60) as response: return response.read()
        except urllib.error.HTTPError as error:
            # HTTP codes are actionable; server error bodies may contain private data.
            raise RuntimeError(f"Supabase HTTP {error.code}") from None

    def rpc(self, name, value):
        return json.loads(self.request("rest/v1/rpc/" + name, encoded(value), "POST"))


def merge_drawing(local, remote):
    if local["kind"] != "drawing" or remote["kind"] != "drawing" or local["deleted"] or remote["deleted"]: return None
    left_wrapper = json.loads(base64.b64decode(local["payload"]))
    right_wrapper = json.loads(base64.b64decode(remote["payload"]))
    if any(left_wrapper.get(key) != right_wrapper.get(key) for key in ("materialID", "documentRevision", "page")): return None
    try:
        left = json.loads(base64.b64decode(left_wrapper["data"]))
        right = json.loads(base64.b64decode(right_wrapper["data"]))
    except (KeyError, ValueError): return None
    if left.get("schemaVersion") != 1 or right.get("schemaVersion") != 1 or left.get("coordinateSpace") != COORDINATES: return None
    if any(left.get(key) != right.get(key) for key in ("geometry", "coordinateSpace")): return None
    for collection, tombstones in [("objects", "deletedObjectIDs"), ("highlights", "deletedHighlightIDs")]:
        a, b = left.get(collection, []), right.get(collection, [])
        ad, bd = set(left.get(tombstones, [])), set(right.get(tombstones, []))
        deleted = ad | bd
        if any(obj["id"] in ad - bd for obj in b) or any(obj["id"] in bd - ad for obj in a): return None
        merged = {obj["id"]: obj for obj in b if obj["id"] not in deleted}
        if len({obj["id"] for obj in a}) != len(a) or len({obj["id"] for obj in b}) != len(b): return None
        def semantic(obj): return {k: v for k, v in obj.items() if k not in ("nativeKey", "createdAt", "updatedAt")}
        for obj in a:
            if obj["id"] in deleted: continue
            if obj["id"] in merged and semantic(merged[obj["id"]]) != semantic(obj): return None
            merged.setdefault(obj["id"], obj)
        right[collection] = sorted(merged.values(), key=lambda obj: (obj.get("createdAt", ""), obj["id"]))
        right[tombstones] = sorted(deleted)
    right.pop("nativeCache", None)
    for obj in right["objects"]: obj.pop("nativeKey", None)
    right_wrapper["data"] = base64.b64encode(encoded(right)).decode()
    payload = encoded(right_wrapper)
    # A union may exceed the RPC cap even when both input pages are valid.
    # Preserve the normal local/remote conflict instead of queuing an invalid page.
    if len(payload) > 4 * 1024 * 1024: return None
    return {**remote, "payload": base64.b64encode(payload).decode(), "revision": remote["revision"] + 1}


def sync_exchange(exchange, remote):
    if exchange.projection_pending(): raise ValueError("Recover pending desktop import before sending another exchange")
    account = exchange.db.execute("SELECT value FROM metadata WHERE key='sync_account'").fetchone()
    if account and account[0] != remote.user_id: raise ValueError("Exchange belongs to another account")
    exchange.db.execute("INSERT OR IGNORE INTO metadata VALUES('sync_account',?)", (remote.user_id,))
    # Push conflicts can change accepted records just like a pull page. Persist
    # intent before either can run, not after downloading the last asset.
    exchange.begin_projection()
    exchange.db.commit()
    # Upload immutable assets before any record references are published.
    for asset in exchange.db.execute("SELECT hash,metadata FROM asset_metadata"):
        marker = "asset_uploaded:" + asset["hash"]
        if exchange.db.execute("SELECT 1 FROM metadata WHERE key=?", (marker,)).fetchone(): continue
        path = "storage/v1/object/bandal-assets/" + remote.user_id + "/" + asset["hash"]
        data = (exchange.assets / asset["hash"]).read_bytes()
        if digest(data) != asset["hash"]: raise ValueError("Local asset changed")
        try: remote.request(path, data, "POST", json.loads(asset["metadata"])["contentType"])
        except RuntimeError as error:
            if str(error) not in ("Supabase HTTP 400", "Supabase HTTP 409"): raise
            if digest(remote.request(path.replace("/object/", "/object/authenticated/"))) != asset["hash"]: raise ValueError("Remote asset hash mismatch")
        exchange.db.execute("INSERT INTO metadata VALUES(?,?)", (marker, "1")); exchange.db.commit()
    pushed = conflicts = merged_count = 0
    for _ in range(1000):
        row = exchange.db.execute("SELECT * FROM outbox ORDER BY sequence LIMIT 1").fetchone()
        if not row: break
        operation = json.loads(row["operation"])
        if operation["record"]["kind"] not in KINDS: raise ValueError("Local-only record in outbox")
        result = remote.rpc("bandal_push", {"p_operation": operation})
        with exchange.db:
            if result["status"] == "conflict":
                local = exchange.get(row["record_id"])
                merged = merge_drawing(envelope(local), result["record"])
                if merged:
                    exchange.db.execute("DELETE FROM outbox WHERE record_id=?", (row["record_id"],))
                    exchange.set_record(merged)
                    retry = {"id": str(uuid.uuid4()), "baseRevision": result["record"]["revision"], "record": merged}
                    exchange.db.execute("INSERT INTO outbox(id,record_id,operation) VALUES(?,?,?)", (retry["id"], row["record_id"], encoded(retry)))
                    merged_count += 1
                    continue
                conflict = {"id": str(uuid.uuid4()), "local": envelope(local), "remote": result["record"],
                            "createdAt": time.time() - 978307200}
                exchange.db.execute("INSERT INTO conflicts VALUES(?,?)", (conflict["id"], encoded(conflict)))
                exchange.db.execute("DELETE FROM outbox WHERE record_id=?", (row["record_id"],))
                exchange.set_record(result["record"]); conflicts += 1
            elif result["status"] == "accepted" and result["record"] == operation["record"]:
                exchange.db.execute("DELETE FROM outbox WHERE id=?", (row["id"],)); pushed += 1
            else: raise ValueError("Invalid push response")
    row = exchange.db.execute("SELECT value FROM metadata WHERE key='sync_cursor'").fetchone()
    cursor = int(row[0]) if row else 0
    while True:
        page = remote.rpc("bandal_pull", {"p_after": cursor, "p_limit": 200})
        if page["cursor"] < cursor or (page["hasMore"] and page["cursor"] <= cursor): raise ValueError("Invalid remote cursor")
        with exchange.db:
            for record in page["records"]:
                if record["formatVersion"] != 1 or record["kind"] not in KINDS: raise ValueError("Unsupported remote record")
                if exchange.db.execute("SELECT 1 FROM outbox WHERE record_id=?", (record["id"],)).fetchone(): continue
                local = exchange.get(record["id"])
                if not local or record["revision"] > local["revision"]: exchange.set_record(record)
            cursor = page["cursor"]
            exchange.db.execute("INSERT INTO metadata VALUES('sync_cursor',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (str(cursor),))
        if not page["hasMore"]: break
    ensure_remote_assets(exchange, remote)
    return {"pushed": pushed, "conflicts": conflicts, "merged": merged_count, "cursor": cursor}


def ensure_remote_assets(exchange, remote=None):
    account = exchange.db.execute("SELECT value FROM metadata WHERE key='sync_account'").fetchone()
    if remote and account and account[0] != remote.user_id: raise ValueError("Exchange belongs to another account")
    seen = set()
    for _, sha, _, count in asset_references(exchange, include_conflicts=True):
        if sha in seen: continue
        seen.add(sha)
        if len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha): raise ValueError("Invalid asset hash")
        target = exchange.assets / sha
        if target.exists() and file_hash(target) == sha and (count is None or target.stat().st_size == count): continue
        if remote is None: raise ValueError("Pending import asset is missing; reconnect the bound account before exporting")
        data = remote.request("storage/v1/object/authenticated/bandal-assets/" + remote.user_id + "/" + sha)
        if digest(data) != sha or (count is not None and len(data) != count): raise ValueError("Downloaded asset hash or length mismatch")
        temporary = target.with_suffix(".partial")
        with open(temporary, "wb") as output:
            output.write(data); output.flush(); os.fsync(output.fileno())
        os.replace(temporary, target)


def recover_projection(desktop, exchange, remote=None, course_root=None):
    if not exchange.projection_pending(): return
    ensure_remote_assets(exchange, remote)
    import_desktop(desktop, exchange, course_root)


def envelope(row):
    return {"id": row["id"], "kind": row["kind"], "payload": base64.b64encode(row["payload"]).decode(),
            "revision": row["revision"], "deleted": bool(row["deleted"]), "formatVersion": row["format_version"]}


def asset_references(exchange, include_notes=True, include_conflicts=False):
    """Asset identifiers exactly match App/Services/Exchange.swift, including recordings."""
    records = exchange.records()
    if include_conflicts:
        for row in exchange.db.execute("SELECT value FROM conflicts"):
            conflict = json.loads(row[0])
            for variant in ("local", "remote"):
                value = conflict.get(variant)
                if isinstance(value, dict): records.append({**value, "payload": base64.b64decode(value["payload"], validate=True)})
    for record in records:
        if record["deleted"]: continue
        payload = json.loads(record["payload"])
        if record["kind"] == "material" and payload["kind"] != "whiteboard":
            if not include_notes and payload["kind"] == "note": continue
            yield payload["id"], payload["revision"], payload["fileName"], payload.get("byteCount")
        elif record["kind"] == "recording" and payload.get("assetRevision"):
            yield "recording:" + payload["id"], payload["assetRevision"], payload["fileName"], payload.get("byteCount")
        elif record["kind"] == "artifact" and payload.get("recordType") == "desktop-learning-file":
            yield record["id"], payload["assetRevision"], payload["fileName"], payload.get("byteCount")
        elif record["kind"] == "artifact" and payload.get("recordType") == "desktop-learning-project":
            for file in payload.get("files", []):
                yield record["id"] + ":" + file["relPath"], file["assetRevision"], Path(file["relPath"]).name, file["byteCount"]


def write_pack(exchange, path):
    records = [envelope(row) for row in exchange.records() if row["kind"] in KINDS]
    assets = []
    raw_size = 0
    for identifier, sha, name, expected_count in asset_references(exchange):
        asset = exchange.assets / sha
        if not asset.is_file(): raise ValueError("Material asset is missing from exchange")
        raw_size += asset.stat().st_size
        if raw_size > 64 * 1024 * 1024: raise ValueError("Package assets exceed 64 MiB; use account synchronization")
        data = asset.read_bytes()
        if digest(data) != sha or (expected_count is not None and expected_count != len(data)): raise ValueError("Asset integrity check failed")
        assets.append({"materialID": identifier, "sha256": sha, "byteCount": len(data),
                       "fileName": name, "data": base64.b64encode(data).decode()})
    pack = {"format": "bandal-exchange", "version": 1, "records": records, "assets": assets}
    package_bytes = encoded(pack)
    if len(package_bytes) > 100 * 1024 * 1024: raise ValueError("Package exceeds 100 MiB; use account synchronization")
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name("." + path.name + ".partial")
    try:
        with open(temporary, "wb") as output:
            output.write(package_bytes); output.flush(); os.fsync(output.fileno())
        os.replace(temporary, path)
    finally: temporary.unlink(missing_ok=True)


def read_pack(exchange, path):
    if Path(path).stat().st_size > 100 * 1024 * 1024: raise ValueError("Package exceeds 100 MiB; use account synchronization")
    pack = json.loads(Path(path).read_bytes())
    if pack.get("format") != "bandal-exchange" or pack.get("version") != 1:
        raise ValueError("Unsupported exchange package")
    records, assets, seen = [], [], set()
    for record in pack["records"]:
        if record["id"] in seen or record["kind"] not in KINDS or record["formatVersion"] != 1:
            raise ValueError("Duplicate or unsupported record in package")
        seen.add(record["id"])
        payload = json.loads(base64.b64decode(record["payload"], validate=True))
        records.append((record, payload))
    raw_size = 0
    for asset in pack["assets"]:
        data = base64.b64decode(asset["data"], validate=True)
        raw_size += len(data)
        if raw_size > 64 * 1024 * 1024: raise ValueError("Package assets exceed 64 MiB")
        if digest(data) != asset["sha256"] or len(data) != asset["byteCount"]:
            raise ValueError("Package asset hash or length mismatch")
        if asset["materialID"].startswith("recording:"):
            recording_id = asset["materialID"].removeprefix("recording:")
            uuid.UUID(recording_id)
            if asset["fileName"] != f"Recordings/{recording_id}.wav": raise ValueError("Unsafe recording path")
        elif Path(asset["fileName"]).name != asset["fileName"] or "\\" in asset["fileName"]:
            raise ValueError("Unsafe asset name")
        assets.append((asset, data))
    # Validation completes before any records or existing files are changed.
    if exchange.projection_pending(): raise ValueError("Recover pending desktop import before opening another package")
    with exchange.db:
        exchange.begin_projection()
        for record, payload in records:
            current = exchange.get(record["id"])
            if current and json.loads(current["payload"]) != payload:
                backup = {"id": str(uuid.uuid4()), "local": envelope(current), "remote": record,
                          "createdAt": time.time() - 978307200}
                exchange.db.execute("INSERT INTO conflicts VALUES(?,?)", (backup["id"], encoded(backup)))
            # Package import is a local mutation, not an authoritative server revision.
            base = current["revision"] if current else 0
            imported = {**record, "revision": base + 1}
            operation = {"id": str(uuid.uuid4()), "baseRevision": base, "record": imported}
            exchange.set_record(imported)
            exchange.db.execute("INSERT INTO outbox(id,record_id,operation) VALUES(?,?,?)",
                                (operation["id"], record["id"], encoded(operation)))
        for asset, data in assets:
            target = exchange.assets / asset["sha256"]
            if target.exists() and file_hash(target) != asset["sha256"]: raise ValueError("Existing asset is corrupt")
            if not target.exists():
                temporary = target.with_suffix(".partial")
                with open(temporary, "wb") as output:
                    output.write(data); output.flush(); os.fsync(output.fileno())
                os.replace(temporary, target)
            metadata = {"sha256": asset["sha256"], "byteCount": asset["byteCount"], "originalName": asset["fileName"],
                        "contentType": mimetypes.guess_type(asset["fileName"])[0] or "application/octet-stream"}
            exchange.db.execute("INSERT OR REPLACE INTO asset_metadata VALUES(?,?)", (asset["sha256"], encoded(metadata)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("export", "import", "sync", "cycle", "watch"))
    parser.add_argument("--desktop-db", type=Path)
    parser.add_argument("--exchange", type=Path, required=True)
    parser.add_argument("--course-root", type=Path)
    parser.add_argument("--interval", type=float, default=10)
    parser.add_argument("--pack", type=Path, help="Write export / read import as a .bandalpack JSON file")
    args = parser.parse_args()
    if args.command in ("export", "import", "cycle", "watch") and not args.desktop_db: parser.error("--desktop-db is required")
    exchange = Exchange(args.exchange)
    remote = None
    if args.command in ("sync", "cycle", "watch"):
        required = ["BANDAL_SUPABASE_URL", "BANDAL_SUPABASE_KEY", "BANDAL_USER_ID", "BANDAL_ACCESS_TOKEN"]
        if any(not os.environ.get(key) for key in required): parser.error("Set Supabase URL, public key, user ID and access token in BANDAL_* environment variables")
        remote = Supabase(*(os.environ[key] for key in required))
    while True:
        if args.desktop_db: recover_projection(args.desktop_db, exchange, remote, args.course_root)
        if args.pack and args.command == "import": read_pack(exchange, args.pack)
        if args.command in ("export", "cycle", "watch"): print(json.dumps(export_desktop(args.desktop_db, exchange)))
        if args.pack and args.command == "export": write_pack(exchange, args.pack)
        if remote: print(json.dumps(sync_exchange(exchange, remote)))
        if args.command in ("import", "cycle", "watch"): print(json.dumps(import_desktop(args.desktop_db, exchange, args.course_root)))
        if args.command != "watch": break
        time.sleep(max(2, args.interval))


if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: pass
    except Exception as error:
        print(f"Bridge stopped without discarding pending work: {error}", file=sys.stderr)
        sys.exit(1)
