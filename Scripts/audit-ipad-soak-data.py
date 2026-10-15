#!/usr/bin/env python3
"""Preserve and audit a finished synthetic iPad soak's TEST library only.

Usage (run only after the harness has finished and the library is quiescent):
  python3 Scripts/audit-ipad-soak-data.py \
    --source-test-library /.../Documents/BandalDesktop-UI-Tests \
    --output-dir /private/tmp/NEW-audit-directory --expected-cycles 100

Exit 0: saved-state checks passed; 1: expected-content mismatch; 2: unsafe
arguments, unstable capture, unknown schema or analysis failure. A successful
saved-state audit does NOT establish test duration, UI responsiveness, physical
Pencil quality, or a successful soak. The caller supplies the expected cycles.

Source SQLite is never opened. Two source byte/metadata passes must agree;
DB/WAL/SHM are preserved together, then copied again for mode=ro SQL analysis.
The preservation tree is hash/metadata checked before and after analysis.
Source read access can update atime; this script never resets source metadata.
No original source path stored inside the DB is opened. Course paths are mapped
only into the preserved test tree. No note body or ink coordinates are printed.

Schema interpretation: notesRepo stores Markdown on disk; pdf_drawings holds
canonical rows; drawing_create_receipts binds an operation ID to immutable
request JSON and a drawing ID; NativePDFJournal removes *.json after ACK.
materials_index is a rebuildable cache and is not used as storage evidence.
"""

import argparse
from collections import Counter
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import sys
import unicodedata
import uuid

TEST_LIBRARY = "BandalDesktop-UI-Tests"
PDF_NAME = "PDF pinch fixture.pdf"
NOTE_NAME = "새 필기.md"
DB_FILES = ("bandal.db", "bandal.db-wal", "bandal.db-shm", "bandal.db-journal")


def now():
    return datetime.now(timezone.utc).isoformat()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def metadata(value):
    return {"device": value.st_dev, "inode": value.st_ino, "size": value.st_size,
            "mode": value.st_mode, "uid": value.st_uid, "gid": value.st_gid,
            "mtime_ns": value.st_mtime_ns, "ctime_ns": value.st_ctime_ns,
            "atime_ns": value.st_atime_ns, "birthtime": getattr(value, "st_birthtime", None)}


def comparable(value):
    # Reads may change atime. Do not write the original just to restore it.
    return {key: item for key, item in value.items() if key != "atime_ns"}


def scan_tree(root, destination=None):
    """Copy/read ordinary nodes only; catch changes during each open and pass."""
    result = {}

    def visit(path):
        relative = path.relative_to(root).as_posix()
        before = path.lstat()
        record = metadata(before)
        target = destination / relative if destination is not None else None
        if stat.S_ISLNK(before.st_mode):
            raise ValueError("Refusing symlink in test library: " + relative)
        if stat.S_ISDIR(before.st_mode):
            record["type"] = "directory"
            if target is not None:
                target.mkdir(exist_ok=False)
            for child in sorted(path.iterdir()):
                visit(child)
        elif stat.S_ISREG(before.st_mode):
            record["type"] = "file"
            digest = hashlib.sha256()
            descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                if comparable(metadata(os.fstat(descriptor))) != comparable(metadata(before)):
                    raise RuntimeError("Source replaced before reading: " + relative)
                output = target.open("xb") if target is not None else None
                try:
                    while True:
                        block = os.read(descriptor, 1024 * 1024)
                        if not block:
                            break
                        digest.update(block)
                        if output is not None:
                            output.write(block)
                    if output is not None:
                        output.flush()
                        os.fsync(output.fileno())
                finally:
                    if output is not None:
                        output.close()
                if comparable(metadata(os.fstat(descriptor))) != comparable(metadata(before)):
                    raise RuntimeError("Source changed while reading: " + relative)
            finally:
                os.close(descriptor)
            record["sha256"] = digest.hexdigest()
        else:
            raise ValueError("Refusing special node in test library: " + relative)
        if comparable(metadata(path.lstat())) != comparable(metadata(before)):
            raise RuntimeError("Source changed during capture: " + relative)
        if target is not None:
            os.chmod(target, stat.S_IMODE(before.st_mode))
            os.utime(target, ns=(before.st_atime_ns, before.st_mtime_ns))
        result[relative] = record

    visit(root)
    return result


def differences(first, second):
    return [key for key in sorted(set(first) | set(second))
            if comparable(first.get(key, {})) != comparable(second.get(key, {}))]


def file_inventory(records):
    return {key: {field: value[field] for field in ("type", "size", "sha256")}
            for key, value in records.items() if value["type"] == "file"}


def reject_constant(value):
    raise ValueError("Non-finite JSON constant: " + value)


def strict_json(text):
    return json.loads(text, parse_constant=reject_constant)


def mapped_path(root, parts):
    """Resolve Unicode-equivalent names only inside our preservation tree."""
    current = root
    for part in parts:
        if not part or part in (".", "..") or "/" in part or "\\" in part or "\0" in part:
            raise ValueError("Unsafe stored test path")
        if not current.is_dir():
            return None
        candidates = [p for p in current.iterdir()
                      if unicodedata.normalize("NFC", p.name) == unicodedata.normalize("NFC", part)]
        if not candidates:
            return None
        if len(candidates) != 1 or candidates[0].is_symlink():
            raise ValueError("Ambiguous or linked preserved path")
        current = candidates[0]
    if not current.resolve().is_relative_to(root.resolve()):
        raise ValueError("Stored path escaped preservation tree")
    return current


def mapped_course(root, stored):
    # The stored absolute simulator path may identify an older container or a
    # COPY input. Use its TEST namespace suffix; never open that absolute path.
    if not isinstance(stored, str) or not stored.startswith("/") or "\\" in stored:
        raise ValueError("Unknown stored course folder format")
    parts = stored.split("/")
    if parts.count(TEST_LIBRARY) != 1 or any(part in (".", "..") for part in parts):
        raise ValueError("Course path is not confined to the test namespace")
    suffix = parts[parts.index(TEST_LIBRARY) + 1:]
    if not suffix or suffix[0] != "Courses":
        raise ValueError("Fixture course is not under test Courses")
    return mapped_path(root, suffix)


def check(report, name, actual, expected):
    report["checks"].append({"name": name, "passed": actual == expected,
                             "actual": actual, "expected": expected})


def valid_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value.lower()
    except (ValueError, AttributeError):
        return False


def analyze(preserved, analysis, cycles, report):
    analysis.mkdir()
    for name in DB_FILES:
        source = preserved / name
        if source.exists():
            shutil.copy2(source, analysis / name)
    db_path = analysis / "bandal.db"
    if not db_path.is_file():
        raise ValueError("Test database is missing")
    # Never use immutable=1: ignoring a real WAL could falsely report lost data.
    # SQLite may touch SHM in this disposable ANALYSIS copy only.
    with closing(sqlite3.connect(db_path.as_uri() + "?mode=ro", uri=True)) as db:
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA query_only=ON")
        report["sqlite"] = {"openedPath": str(db_path), "mode": "ro", "queryOnly": True}
        check(report, "databaseIntegrity", [row[0] for row in db.execute("PRAGMA integrity_check")], ["ok"])
        columns = {
            "courses": {"id", "folder_path", "deleted_at"},
            "pdf_drawings": {"id", "course_id", "rel_path", "page", "kind", "data_json", "style_json", "deleted_at", "created_at"},
            "drawing_create_receipts": {"operation_id", "drawing_id", "request_json"},
        }
        for table, required in columns.items():
            actual = {row[1] for row in db.execute("PRAGMA table_info(" + table + ")")}
            if not required.issubset(actual):
                raise ValueError("Unknown schema: missing " + table + " columns " + str(sorted(required - actual)))
        fixtures = []
        for course in db.execute("SELECT id,folder_path FROM courses WHERE deleted_at IS NULL"):
            folder = mapped_course(preserved, course["folder_path"])
            pdf = mapped_path(folder, [PDF_NAME]) if folder is not None else None
            if pdf is not None and pdf.is_file():
                fixtures.append((course["id"], folder, pdf))
        if len(fixtures) != 1:
            raise ValueError("Expected exactly one saved synthetic PDF fixture; found " + str(len(fixtures)))
        course, folder, pdf = fixtures[0]
        pdf_hash = sha(pdf.read_bytes())
        rows = [dict(row) for row in db.execute(
            "SELECT * FROM pdf_drawings WHERE course_id=? AND rel_path=?", (course, PDF_NAME))]
        live = [row for row in rows if row["deleted_at"] is None]
        expected = cycles + 1
        ids = [row["id"] for row in live]
        check(report, "activeInkCount", len(live), expected)
        check(report, "deletedDrawingCount", len(rows) - len(live), 0)
        check(report, "drawingIDsUnique", len(set(ids)), len(ids))
        check(report, "drawingIDsValid", all(valid_uuid(value) for value in ids), True)
        check(report, "allDrawingsArePageOneInk", all(row["kind"] == "ink" and row["page"] == 1 for row in live), True)
        by_id = {row["id"]: row for row in rows}
        receipts = []
        mismatches = []
        for raw in db.execute("SELECT operation_id,drawing_id,request_json FROM drawing_create_receipts"):
            request = strict_json(raw["request_json"])
            if not isinstance(request, dict):
                raise ValueError("Invalid receipt request object")
            # Include target requests even if their canonical row is missing;
            # a JOIN alone would hide that damaged/orphaned receipt.
            if not (request.get("courseId") == course and request.get("relPath") == PDF_NAME) and raw["drawing_id"] not in by_id:
                continue
            receipts.append(dict(raw))
            row = by_id.get(raw["drawing_id"])
            matches = row is not None and row["deleted_at"] is None and all([
                request.get("courseId") == course, request.get("relPath") == PDF_NAME,
                request.get("page") == row["page"], request.get("kind") == row["kind"],
                request.get("data") == strict_json(row["data_json"]),
                request.get("style") == strict_json(row["style_json"]),
                request.get("documentRevision") == pdf_hash,
            ])
            if not matches:
                mismatches.append(raw["operation_id"])
        operations = [row["operation_id"] for row in receipts]
        receipt_ids = [row["drawing_id"] for row in receipts]
        check(report, "receiptCount", len(receipts), expected)
        check(report, "receiptCountEqualsActiveInk", len(receipts), len(live))
        check(report, "receiptOperationIDsUnique", len(set(operations)), len(operations))
        check(report, "receiptOperationIDsValid", all(valid_uuid(value) for value in operations), True)
        check(report, "receiptDrawingIDsUnique", len(set(receipt_ids)), len(receipt_ids))
        check(report, "receiptDrawingIDsMatchCanonical", sorted(receipt_ids), sorted(ids))
        check(report, "receiptContentAndPDFRevisionMismatches", mismatches, [])
        report["pdf"] = {"courseID": course, "relativePath": str(pdf.relative_to(preserved)),
                         "sha256": pdf_hash, "activeRows": len(live), "receipts": len(receipts),
                         "drawingIDs": ids, "mutationIDs": operations,
                         "lastCreatedAt": max((row["created_at"] for row in live), default=None)}
        note = mapped_path(folder, [NOTE_NAME])
        if note is None or not note.is_file():
            raise ValueError("Saved synthetic soak Markdown is missing")
        note_bytes = note.read_bytes()
        markers = re.findall(r"(?<![A-Z0-9-])IPAD-SOAK-(?:BEGIN|CYCLE-[0-9]+)(?![A-Z0-9-])", note_bytes.decode("utf-8"))
        counts = Counter(markers)
        expected_markers = {"IPAD-SOAK-BEGIN"} | {"IPAD-SOAK-CYCLE-" + str(index) for index in range(1, cycles + 1)}
        check(report, "missingNoteMarkers", sorted(expected_markers - set(counts)), [])
        check(report, "unexpectedNoteMarkers", sorted(set(counts) - expected_markers), [])
        check(report, "duplicateNoteMarkers", {key: value for key, value in counts.items() if value != 1}, {})
        report["note"] = {"relativePath": str(note.relative_to(preserved)), "bytes": len(note_bytes),
                          "sha256": sha(note_bytes), "beginCount": counts["IPAD-SOAK-BEGIN"],
                          "cycleMarkerCount": sum(value for key, value in counts.items() if "CYCLE-" in key)}
        journal = preserved / "PendingNativePDFInk"
        check(report, "journalDirectoryExists", journal.is_dir(), True)
        entries = sorted(path.name for path in journal.iterdir()) if journal.is_dir() else []
        check(report, "journalEntries", entries, [])
        report["journal"] = {"relativePath": "PendingNativePDFInk", "entries": entries,
                             "boundary": "Disk journal only; does not prove in-memory state at an earlier failure."}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source-test-library", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--expected-cycles", required=True, type=int)
    args = parser.parse_args()
    # Validate the lexical namespace BEFORE resolving or reading any source.
    if args.source_test_library.name != TEST_LIBRARY or "BandalDesktop" in args.source_test_library.parts:
        parser.error("Source must be the isolated BandalDesktop-UI-Tests namespace, never BandalDesktop")
    if args.expected_cycles < 0:
        parser.error("Expected cycles must be nonnegative")
    if args.source_test_library.is_symlink():
        parser.error("Source library cannot be a symlink")
    try:
        source = args.source_test_library.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        parser.error("Source test library cannot be resolved: " + str(error))
    if source.name != TEST_LIBRARY or "BandalDesktop" in source.parts or not source.is_dir():
        parser.error("Resolved source is not an isolated test library")
    output = args.output_dir.resolve()
    if output.exists() or args.output_dir.is_symlink():
        parser.error("Output must be a new, nonexistent directory")
    if output.is_relative_to(source) or source.is_relative_to(output) or "BandalDesktop" in output.parts:
        parser.error("Output must be separate from source and ordinary user libraries")
    if not output.parent.is_dir():
        parser.error("Output parent directory must already exist")
    output.mkdir(mode=0o700)
    preserved = output / TEST_LIBRARY
    report = {"schemaVersion": 1, "startedUTC": now(), "source": str(source), "output": str(output),
              "expectedCycles": args.expected_cycles, "expectedActiveInk": args.expected_cycles + 1,
              "scope": "Saved synthetic test state only; not soak duration, UI, physical Pencil or service acceptance.",
              "sourceSQLiteOpened": False, "preservedSQLiteOpened": False, "sourceWrites": False,
              "checks": [], "status": "error"}
    source_manifest = {"source": str(source), "sourceStable": False, "files": {}}
    before_analysis = None
    exit_code = 2
    try:
        first = scan_tree(source, preserved)
        source_manifest["files"] = first
        second = scan_tree(source)
        changed = differences(first, second)
        source_manifest.update({"sourceStable": not changed, "changedPaths": changed, "completedUTC": now()})
        if changed:
            raise RuntimeError("Source changed during the two-pass capture; no SQL analysis performed")
        before_analysis = scan_tree(preserved)
        if file_inventory(first) != file_inventory(before_analysis):
            raise RuntimeError("Preserved file SHA inventory does not match source capture")
        write_json(output / "preserved-manifest.json", before_analysis)
        report["capture"] = {"stable": True, "fileCount": len(file_inventory(first)),
                             "bytes": sum(value["size"] for value in first.values() if value["type"] == "file")}
        analyze(preserved, output / "analysis", args.expected_cycles, report)
        exit_code = 0 if all(item["passed"] for item in report["checks"]) else 1
        report["status"] = "pass" if exit_code == 0 else "fail"
    except Exception as error:
        report["error"] = type(error).__name__ + ": " + str(error)
    finally:
        if before_analysis is not None:
            try:
                changed = differences(before_analysis, scan_tree(preserved))
                report["preservedChangedPaths"] = changed
                if changed:
                    report["status"] = "error"
                    report["error"] = "Preservation tree changed during analysis"
                    exit_code = 2
            except Exception as error:
                report["status"] = "error"
                report["error"] = "Cannot verify preservation tree: " + str(error)
                exit_code = 2
        report["completedUTC"] = now()
        write_json(output / "source-manifest.json", source_manifest)
        write_json(output / "report.json", report)
        evidence = {name: sha((output / name).read_bytes()) for name in
                    ("source-manifest.json", "preserved-manifest.json", "report.json") if (output / name).is_file()}
        write_json(output / "evidence-sha256.json", evidence)
    print(json.dumps({"status": report["status"], "output": str(output), "capture": report.get("capture"),
                      "activeInk": report.get("pdf", {}).get("activeRows"),
                      "receipts": report.get("pdf", {}).get("receipts"), "note": report.get("note"),
                      "journal": report.get("journal"), "failedChecks": [item for item in report["checks"] if not item["passed"]],
                      "error": report.get("error")}, ensure_ascii=False))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
