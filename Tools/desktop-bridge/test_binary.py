"""Optional smoke test of the shipped executable, without Python on its PATH."""
import os
from pathlib import Path
import subprocess
import unittest
import test_bridge

bridge = test_bridge.bridge


@unittest.skipUnless(os.environ.get("BANDAL_TEST_BRIDGE_BINARY"), "Set BANDAL_TEST_BRIDGE_BINARY to a built helper")
class BinaryTests(unittest.TestCase):
    def test_export_import_with_no_python_runtime_on_path(self):
        fixture = test_bridge.BridgeTests(); fixture.setUp()
        try:
            binary = str(Path(os.environ["BANDAL_TEST_BRIDGE_BINARY"]).resolve())
            sha = bridge.file_hash(fixture.folder / "slides.pdf")
            (fixture.exchange.root / f"geometry-{sha}.json").write_bytes(bridge.encoded(fixture.geometry))
            environment = {**os.environ, "PATH": "/usr/bin:/bin" if os.name != "nt" else os.environ.get("SystemRoot", "C:\\Windows")}
            common = ["--desktop-db", str(fixture.dbpath), "--exchange", str(fixture.exchange.root)]
            package = fixture.root / "fixture.bandalpack"
            subprocess.run([binary, "export", *common, "--pack", str(package)], env=environment, check=True, capture_output=True)
            subprocess.run([binary, "import", *common, "--pack", str(package)], env=environment, check=True, capture_output=True)
            self.assertEqual((fixture.folder / "note.md").read_text(), "# original\n")
            self.assertEqual(fixture.db.execute("SELECT extra_column FROM pdf_drawings WHERE id='stroke'").fetchone()[0], "preserved")
        finally: fixture.tearDown()


if __name__ == "__main__": unittest.main()
