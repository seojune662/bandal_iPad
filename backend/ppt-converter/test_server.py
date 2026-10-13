import http.client
import importlib.util
from pathlib import Path
import subprocess
import threading
import unittest
import io
import zipfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("converter", Path(__file__).with_name("server.py"))
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)


class ConverterTests(unittest.TestCase):
    def setUp(self):
        self.converted = []
        def auth(value):
            if value != "Bearer valid": raise module.RequestFailure(401, "Authentication required")
        def convert(data, output):
            self.converted.append((data, output)); return b"PK-pptx fixture" if output == "pptx" else b"%PDF-1.7 fixture"
        self.server = module.http.server.ThreadingHTTPServer(("127.0.0.1", 0), module.handler_for(auth, convert))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()

    def request(self, data=None, headers=None, path="/convert"):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        defaults = {"Content-Type": "application/vnd.ms-powerpoint", "Authorization": "Bearer valid"}
        defaults.update(headers or {})
        connection.request("POST", path, module.OLE_MAGIC + b"ppt" if data is None else data, defaults)
        response = connection.getresponse(); result = response.status, response.read(), dict(response.getheaders())
        connection.close(); return result

    def test_authorized_raw_ppt_returns_uncacheable_pdf(self):
        status, body, headers = self.request()
        self.assertEqual(status, 200); self.assertTrue(body.startswith(b"%PDF-"))
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(len(self.converted), 1)

    def test_invalid_auth_type_magic_size_and_url_never_convert(self):
        self.assertEqual(self.request(headers={"Authorization":"Bearer invalid"})[0], 401)
        self.assertEqual(self.request(headers={"Content-Type":"application/json"})[0], 415)
        self.assertEqual(self.request(data=b"not-a-ppt-document")[0], 415)
        self.assertEqual(self.request(headers={"Content-Length":str(module.MAX_INPUT + 1)})[0], 413)
        self.assertEqual(self.request(path="/convert?url=https://example.com/a.ppt")[0], 404)
        self.assertEqual(self.converted, [])

    def test_normalize_produces_editable_pptx_contract(self):
        status, body, headers = self.request(path="/normalize")
        self.assertEqual(status, 200)
        self.assertTrue(body.startswith(b"PK"))
        self.assertEqual(self.converted[0][1], "pptx")
        self.assertEqual(headers["Content-Type"], "application/vnd.openxmlformats-officedocument.presentationml.presentation")

    def test_pptx_conversion_validates_office_package_and_same_sandbox(self):
        def run(command, **options):
            self.assertIn("pptx:Impress MS PowerPoint 2007 XML", command)
            self.assertIn("--unshare-net", command)
            with zipfile.ZipFile(Path(options["cwd"]) / "document.pptx", "w") as archive:
                archive.writestr("[Content_Types].xml", "<Types/>")
                archive.writestr("ppt/presentation.xml", "<presentation/>")
        with patch.object(module.subprocess, "run", side_effect=run):
            package = module.LibreOfficeConverter()(module.OLE_MAGIC, "pptx")
            with zipfile.ZipFile(io.BytesIO(package)) as archive:
                self.assertIn("ppt/presentation.xml", archive.namelist())
        def invalid(_command, **options):
            (Path(options["cwd"]) / "document.pptx").write_bytes(b"PK-invalid")
        with patch.object(module.subprocess, "run", side_effect=invalid):
            with self.assertRaises(module.RequestFailure) as raised:
                module.LibreOfficeConverter()(module.OLE_MAGIC, "pptx")
            self.assertEqual(raised.exception.status, 422)

    def test_sandbox_command_isolated_no_secrets_and_temp_files_removed(self):
        roots = []
        def run(command, **options):
            self.assertIn("--unshare-net", command); self.assertIn("--unshare-pid", command)
            self.assertNotIn("shell", options)
            self.assertNotIn("SUPABASE_URL", options["env"])
            self.assertEqual(options["timeout"], 120)
            root = Path(options["cwd"]); roots.append(root)
            self.assertEqual((root / "document.ppt").read_bytes(), module.OLE_MAGIC)
            (root / "document.pdf").write_bytes(b"%PDF-1.7 converted")
        with patch.object(module.subprocess, "run", side_effect=run):
            self.assertTrue(module.LibreOfficeConverter()(module.OLE_MAGIC).startswith(b"%PDF-"))
        self.assertTrue(all(not root.exists() for root in roots))

    def test_timeout_and_missing_sandbox_fail_closed(self):
        for failure, status in [(subprocess.TimeoutExpired("sandbox", 120), 504), (FileNotFoundError(), 422)]:
            with patch.object(module.subprocess, "run", side_effect=failure):
                with self.assertRaises(module.RequestFailure) as raised:
                    module.LibreOfficeConverter()(module.OLE_MAGIC)
                self.assertEqual(raised.exception.status, status)

    def test_auth_configuration_rejects_untrusted_schemes(self):
        for url in ["http://project.supabase.co", "https://user:password@project.supabase.co", "https://project.supabase.co?url=other"]:
            with self.assertRaises(ValueError): module.SupabaseAuth(url, "public")


if __name__ == "__main__": unittest.main()
