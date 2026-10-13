import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location("bridge", Path(__file__).with_name("bridge.py"))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.folder = self.root / "course"; self.folder.mkdir()
        self.dbpath = self.root / "desktop.sqlite"
        self.cid = str(uuid.uuid4()); self.pdfid = str(uuid.uuid4()); self.noteid = str(uuid.uuid4())
        self.db = sqlite3.connect(self.dbpath)
        self.db.executescript("""
          CREATE TABLE courses(id TEXT PRIMARY KEY,name TEXT,color TEXT,slug TEXT UNIQUE,folder_path TEXT,
            archived INTEGER,sort_order INTEGER,created_at TEXT,updated_at TEXT,deleted_at TEXT);
          CREATE TABLE materials_index(id TEXT PRIMARY KEY,course_id TEXT,rel_path TEXT,kind TEXT,size INTEGER,
            mtime INTEGER,created_at TEXT,updated_at TEXT,deleted_at TEXT,UNIQUE(course_id,rel_path));
          CREATE TABLE pdf_drawings(id TEXT PRIMARY KEY,course_id TEXT,rel_path TEXT,page INTEGER,kind TEXT,
            data_json TEXT,style_json TEXT,created_at TEXT,updated_at TEXT,deleted_at TEXT,extra_column TEXT);
          CREATE TABLE annotations(id TEXT PRIMARY KEY,course_id TEXT,rel_path TEXT,page INTEGER,color TEXT,
            rects_json TEXT,anchor_json TEXT,comment TEXT,created_at TEXT,updated_at TEXT,deleted_at TEXT);
          CREATE TABLE board_tasks(id TEXT PRIMARY KEY,course_id TEXT,title TEXT,notes TEXT,status TEXT,due_at TEXT,
            sort_order INTEGER,created_at TEXT,updated_at TEXT,deleted_at TEXT);
        """)
        timestamp = "2026-10-13T00:00:00Z"
        self.db.execute("INSERT INTO courses VALUES(?,?,?,?,?,?,?,?,?,?)",
                        (self.cid, "수업", "green", "course", str(self.folder), 0, 0, timestamp, timestamp, None))
        (self.folder / "slides.pdf").write_bytes(b"fixture-pdf")
        (self.folder / "note.md").write_text("# original\n", encoding="utf-8")
        for mid, name, kind in [(self.pdfid, "slides.pdf", "pdf"), (self.noteid, "note.md", "note")]:
            self.db.execute("INSERT INTO materials_index VALUES(?,?,?,?,?,?,?,?,?)",
                            (mid, self.cid, name, kind, 1, 1, timestamp, timestamp, None))
        data = {"points": [{"x": .2, "y": .3, "p": .8}, {"x": .6, "y": .7, "p": .4}], "futureField": "keep"}
        style = {"color": "ink", "width": .003, "opacity": 1, "futureStyle": "keep"}
        self.db.execute("INSERT INTO pdf_drawings VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                        ("stroke", self.cid, "slides.pdf", 1, "ink", json.dumps(data), json.dumps(style), timestamp, timestamp, None, "preserved"))
        self.db.execute("INSERT INTO annotations VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                        ("highlight", self.cid, "slides.pdf", 1, "yellow", json.dumps([{"x":.1,"y":.2,"width":.2,"height":.05}]),
                         json.dumps({"quote":"한글","prefix":"앞","suffix":"뒤"}), "메모", timestamp, timestamp, None))
        self.db.commit()
        self.exchange = bridge.Exchange(self.root / "exchange")
        self.geometry = [{"cropX": 13, "cropY": 20, "width": 600, "height": 800, "rotation": 90}]

    def tearDown(self):
        self.exchange.db.close(); self.db.close(); self.temporary.cleanup()

    def export(self):
        return bridge.export_desktop(self.dbpath, self.exchange, lambda *_: self.geometry)

    def test_export_is_read_only_and_unchanged_export_is_idempotent(self):
        before = self.db.execute("SELECT * FROM pdf_drawings").fetchall()
        self.export()
        pending = self.exchange.db.execute("SELECT count(*) FROM outbox").fetchone()[0]
        self.export()
        self.assertEqual(pending, self.exchange.db.execute("SELECT count(*) FROM outbox").fetchone()[0])
        self.assertEqual(before, self.db.execute("SELECT * FROM pdf_drawings").fetchall())

    def test_pdf_rotation_roundtrip_preserves_ids_pressure_unknown_fields_and_anchor(self):
        self.export()
        bridge.import_desktop(self.dbpath, self.exchange)
        row = self.db.execute("SELECT data_json,style_json,extra_column FROM pdf_drawings WHERE id='stroke'").fetchone()
        data = json.loads(row[0]); style = json.loads(row[1])
        self.assertAlmostEqual(data["points"][0]["x"], .2)
        self.assertAlmostEqual(data["points"][0]["y"], .3)
        self.assertEqual(data["points"][0]["p"], .8)
        self.assertEqual(data["futureField"], "keep")
        self.assertAlmostEqual(style["width"], .003)
        self.assertEqual(style["futureStyle"], "keep")
        self.assertEqual(row[2], "preserved")
        anchor, comment = self.db.execute("SELECT anchor_json,comment FROM annotations WHERE id='highlight'").fetchone()
        self.assertEqual(json.loads(anchor)["prefix"], "앞"); self.assertEqual(comment, "메모")
        # A repeated roundtrip must remain safe and not enqueue the imported page.
        pending = self.exchange.db.execute("SELECT count(*) FROM outbox").fetchone()[0]
        self.export()
        self.assertEqual(pending, self.exchange.db.execute("SELECT count(*) FROM outbox").fetchone()[0])

    def test_concurrent_desktop_stroke_is_not_silently_deleted(self):
        self.export()
        self.db.execute("UPDATE pdf_drawings SET data_json=? WHERE id='stroke'", ('{"points":[{"x":0.9,"y":0.1,"p":1}]}',)); self.db.commit()
        with self.assertRaisesRegex(ValueError, "changed since export"):
            bridge.import_desktop(self.dbpath, self.exchange)
        self.assertEqual(json.loads(self.db.execute("SELECT data_json FROM pdf_drawings").fetchone()[0])["points"][0]["x"], .9)

    def test_note_update_and_external_edit_conflict(self):
        self.export()
        record = self.exchange.get("note:" + self.noteid)
        record["payload"] = bridge.encoded({"materialID": self.noteid, "markdown": "# iPad edit\n"})
        self.exchange.set_record(bridge.envelope(record)); self.exchange.db.commit()
        bridge.import_desktop(self.dbpath, self.exchange)
        self.assertEqual((self.folder / "note.md").read_text(), "# iPad edit\n")
        (self.folder / "note.md").write_text("# unsaved desktop edit\n")
        with self.assertRaisesRegex(ValueError, "changed since export"):
            bridge.import_desktop(self.dbpath, self.exchange)
        self.assertEqual((self.folder / "note.md").read_text(), "# unsaved desktop edit\n")

    def test_pack_integrity_validation_before_record_mutation(self):
        self.export()
        pack_path = self.root / "course.bandalpack"
        bridge.write_pack(self.exchange, pack_path)
        target = bridge.Exchange(self.root / "imported")
        try:
            bridge.read_pack(target, pack_path)
            self.assertEqual(len(target.records()), len(self.exchange.records()))
            package = json.loads(pack_path.read_bytes()); package["assets"][0]["byteCount"] += 1
            pack_path.write_bytes(bridge.encoded(package))
            before = len(target.records())
            with self.assertRaisesRegex(ValueError, "hash or length"):
                bridge.read_pack(target, pack_path)
            self.assertEqual(len(target.records()), before)
        finally: target.db.close()

    def test_all_rotations_are_invertible(self):
        for rotation in [0, 90, 180, 270]:
            x, y = bridge.rotate_point(.13, .87, rotation)
            a, b = bridge.rotate_point(x, y, rotation, True)
            self.assertAlmostEqual(a, .13); self.assertAlmostEqual(b, .87)

    def test_deleted_ink_tombstones_and_ipad_material_relations_survive_export(self):
        self.export()
        row = self.exchange.get("material:" + self.pdfid)
        material = json.loads(row["payload"])
        material.update(folderID="folder", sourceMaterialID="original", sourcePage=7)
        row["payload"] = bridge.encoded(material); self.exchange.set_record(bridge.envelope(row)); self.exchange.db.commit()
        self.db.execute("UPDATE pdf_drawings SET deleted_at='deleted' WHERE id='stroke'"); self.db.commit()
        self.export()
        payload = json.loads(self.exchange.get(row["id"])["payload"])
        self.assertEqual(payload["sourcePage"], 7); self.assertEqual(payload["folderID"], "folder")
        drawing = self.exchange.records("drawing")[0]
        portable = json.loads(bridge.base64.b64decode(json.loads(drawing["payload"])["data"]))
        self.assertEqual(portable["objects"], [])
        self.assertIn("stroke", portable["deletedObjectIDs"])

    def test_recording_package_assets_roundtrip_and_path_validation(self):
        rid = str(uuid.uuid4()); audio = self.root / "recording.wav"; audio.write_bytes(b"RIFF-test-audio")
        sha = self.exchange.asset(audio)
        payload = {"id":rid,"courseID":self.cid,"fileName":f"Recordings/{rid}.wav", "assetRevision":sha,"byteCount":audio.stat().st_size}
        self.exchange.export_record("recording:" + rid, "recording", payload, {})
        path = self.root / "recording.bandalpack"; bridge.write_pack(self.exchange, path)
        target = bridge.Exchange(self.root / "imported")
        try:
            bridge.read_pack(target, path)
            self.assertEqual((target.assets / sha).read_bytes(), audio.read_bytes())
            rewritten = self.root / "rewritten.bandalpack"; bridge.write_pack(target, rewritten)
            self.assertEqual(json.loads(rewritten.read_bytes())["assets"][0]["fileName"], payload["fileName"])
            package = json.loads(path.read_bytes()); package["assets"][0]["fileName"] = "Recordings/../outside.wav"
            path.write_bytes(bridge.encoded(package))
            with self.assertRaisesRegex(ValueError, "Unsafe recording"):
                bridge.read_pack(target, path)
        finally: target.db.close()

    def test_individually_valid_large_pages_do_not_enqueue_oversized_union(self):
        def drawing(identifier, size):
            page = {"schemaVersion":1, "coordinateSpace":bridge.COORDINATES, "geometry":self.geometry[0],
                    "objects":[{"id":identifier, "kind":"ink", "data":{"futurePayload":"x" * size}}], "highlights":[]}
            wrapper = {"materialID":self.pdfid, "documentRevision":"sha", "page":1,
                       "data":bridge.base64.b64encode(bridge.encoded(page)).decode()}
            payload = bridge.encoded(wrapper)
            self.assertLess(len(payload), 4 * 1024 * 1024)
            return {"id":"drawing:fixture", "kind":"drawing", "payload":bridge.base64.b64encode(payload).decode(),
                    "revision":2, "deleted":False, "formatVersion":1}
        self.assertIsNone(bridge.merge_drawing(drawing("left", 1_600_000), drawing("right", 1_600_000)))
        self.assertIsNotNone(bridge.merge_drawing(drawing("left", 10), drawing("right", 10)))


if __name__ == "__main__": unittest.main()
