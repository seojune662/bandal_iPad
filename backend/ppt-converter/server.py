"""Authenticated legacy PPT conversion. No document URL or filesystem path inputs."""
from __future__ import annotations
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile
import io

MAX_INPUT = 80 * 1024 * 1024
MAX_OUTPUT = 160 * 1024 * 1024
OLE_MAGIC = bytes.fromhex("d0cf11e0a1b11ae1")


class RequestFailure(Exception):
    def __init__(self, status, message):
        self.status = status
        super().__init__(message)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        raise RequestFailure(502, "Authentication redirect rejected")


class SupabaseAuth:
    def __init__(self, url, publishable_key):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError("SUPABASE_URL must be an HTTPS project URL")
        if not publishable_key: raise ValueError("SUPABASE_PUBLISHABLE_KEY is required")
        self.url, self.key = url.rstrip("/") + "/auth/v1/user", publishable_key
        self.opener = urllib.request.build_opener(NoRedirect)

    def __call__(self, authorization):
        if not authorization.startswith("Bearer ") or len(authorization) > 16384:
            raise RequestFailure(401, "Authentication required")
        request = urllib.request.Request(self.url, headers={"Authorization": authorization, "apikey": self.key})
        try:
            with self.opener.open(request, timeout=10) as response:
                data = response.read(65537)
                if len(data) > 65536: raise RequestFailure(502, "Invalid authentication response")
                user = json.loads(data)
                uuid.UUID(user["id"])
        except urllib.error.HTTPError as error:
            raise RequestFailure(401 if error.code in (400, 401, 403) else 502, "Authentication failed") from None
        except (urllib.error.URLError, ValueError, KeyError, socket.timeout):
            raise RequestFailure(502, "Authentication unavailable") from None


class LibreOfficeConverter:
    def __init__(self, executable="/usr/bin/libreoffice", sandbox="/usr/bin/bwrap", timeout=120):
        self.executable, self.sandbox, self.timeout = executable, sandbox, timeout

    def __call__(self, data, output="pdf"):
        if output not in ("pdf", "pptx"): raise RequestFailure(400, "Unsupported output format")
        if not data.startswith(OLE_MAGIC): raise RequestFailure(415, "Expected a legacy .ppt OLE document")
        with tempfile.TemporaryDirectory(prefix="bandal-convert-") as folder:
            root = Path(folder); source = root / "document.ppt"; source.write_bytes(data)
            profile = root / "profile"; profile.mkdir()
            # Disable macros even for a document that masquerades as PowerPoint.
            (profile / "user").mkdir()
            (profile / "user/registrymodifications.xcu").write_text('''<?xml version="1.0"?>
<oor:items xmlns:oor="http://openoffice.org/2001/registry">
<item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
</oor:items>''')
            # A fresh user/PID/network namespace prevents documents from reaching
            # external links, process credentials or another conversion's files.
            # Hosts without unprivileged namespaces fail closed; no unsafe fallback.
            command = [self.sandbox, "--die-with-parent", "--unshare-user", "--unshare-pid", "--unshare-net",
                       "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev",
                       "--tmpfs", "/tmp", "--dir", folder, "--bind", folder, folder, "--chdir", folder,
                       self.executable, "-env:UserInstallation=" + profile.as_uri(), "--headless", "--nologo",
                       "--nodefault", "--norestore", "--convert-to", "pdf:impress_pdf_Export" if output == "pdf" else "pptx:Impress MS PowerPoint 2007 XML", "--outdir", folder, str(source)]
            try:
                subprocess.run(command, check=True, timeout=self.timeout, cwd=folder,
                               env={"PATH": "/usr/bin:/bin", "HOME": folder, "TMPDIR": folder, "LANG": "C.UTF-8"},
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except subprocess.TimeoutExpired:
                raise RequestFailure(504, "Conversion timed out") from None
            except (OSError, subprocess.CalledProcessError):
                raise RequestFailure(422, "Conversion failed or sandbox unavailable") from None
            result = root / ("document." + output)
            if not result.is_file() or result.stat().st_size > MAX_OUTPUT:
                raise RequestFailure(422, "No valid presentation produced")
            payload = result.read_bytes()
            if output == "pdf":
                if not payload.startswith(b"%PDF-"): raise RequestFailure(422, "Invalid converted PDF")
            else:
                try:
                    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
                        required = {"[Content_Types].xml", "ppt/presentation.xml"}
                        if not required.issubset(archive.namelist()): raise ValueError()
                        if any(archive.getinfo(name).file_size > 4 * 1024 * 1024 for name in required): raise ValueError()
                        if sum(entry.file_size for entry in archive.infolist()) > 512 * 1024 * 1024: raise ValueError()
                except (zipfile.BadZipFile, ValueError, KeyError):
                    raise RequestFailure(422, "Invalid converted PPTX") from None
            return payload


def handler_for(authenticate, convert, concurrency=2):
    slots = threading.BoundedSemaphore(concurrency)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def log_message(self, *_args): pass  # Never log tokens, document paths or bodies.

        def reply(self, status, body, content_type="text/plain; charset=utf-8"):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers(); self.wfile.write(body)

        def do_POST(self):
            acquired = False
            try:
                self.connection.settimeout(30)
                if self.path not in ("/convert", "/normalize"): raise RequestFailure(404, "Not found")
                if self.headers.get("Transfer-Encoding"): raise RequestFailure(400, "Content-Length required")
                lengths = self.headers.get_all("Content-Length", [])
                if len(lengths) != 1 or not lengths[0].isdigit(): raise RequestFailure(411, "Content-Length required")
                size = int(lengths[0])
                if size < 8 or size > MAX_INPUT: raise RequestFailure(413, "Input must be at most 80 MiB")
                if self.headers.get_content_type() != "application/vnd.ms-powerpoint": raise RequestFailure(415, "Expected application/vnd.ms-powerpoint")
                acquired = slots.acquire(blocking=False)
                if not acquired: raise RequestFailure(429, "Converter busy; retry later")
                authenticate(self.headers.get("Authorization", ""))
                data = self.rfile.read(size)
                if len(data) != size: raise RequestFailure(400, "Incomplete upload")
                if not data.startswith(OLE_MAGIC): raise RequestFailure(415, "Expected a legacy .ppt OLE document")
                output = "pptx" if self.path == "/normalize" else "pdf"
                self.reply(200, convert(data, output), "application/vnd.openxmlformats-officedocument.presentationml.presentation" if output == "pptx" else "application/pdf")
            except RequestFailure as error:
                self.reply(error.status, str(error).encode())
            except (TimeoutError, socket.timeout):
                self.reply(408, b"Upload timed out")
            except (BrokenPipeError, ConnectionResetError): pass
            except Exception:
                self.reply(500, b"Conversion unavailable")
            finally:
                if acquired: slots.release()

    return Handler


if __name__ == "__main__":
    auth = SupabaseAuth(os.environ["SUPABASE_URL"], os.environ["SUPABASE_PUBLISHABLE_KEY"])
    server = http.server.ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), handler_for(auth, LibreOfficeConverter()))
    server.daemon_threads = True
    server.serve_forever()
