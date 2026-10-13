#!/usr/bin/env python3
"""Prepare a reviewable exact-projector desktop delta; never writes desktop."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("Desktop integration boundary changed; inspect before staging: " + old[:100])
    return text.replace(old, new)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--desktop", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    backend = here.parent.parent / "DesktopRuntime/backend/dist/backend.js"
    if not backend.is_file(): raise ValueError("Build the backend before staging")
    original = (args.desktop / "src/main/features/ipadSync/runtime.ts").read_text()
    if "BANDAL_DESKTOP_PROJECTOR: projector" in original:
        # Subsequent snapshots update the already reviewed integration instead
        # of inserting a second launcher block into the applied runtime.
        for required in ["const projectorDirectory = app.isPackaged", "const projectionBackend =", "BANDAL_DESKTOP_RUNTIME: process.execPath", "BANDAL_DESKTOP_MODULE_ROOT: app.getAppPath()", "BANDAL_DESKTOP_BACKEND: projectionBackend"]:
            if original.count(required) != 1:
                raise ValueError("Applied projector integration changed; review " + required)
        updated = original
    else:
        updated = replace_once(original, "      const helper = process.env['BANDAL_IPAD_BRIDGE']", """      const projectorDirectory = app.isPackaged
        ? join(process.resourcesPath, 'ipad-bridge')
        : join(app.getAppPath(), 'resources', 'ipad-bridge')
      const projector = join(projectorDirectory, 'projector-host.cjs')
      const projectionBackend = join(projectorDirectory, 'backend.js')
      if (!existsSync(projector) || !existsSync(projectionBackend)) throw new Error('공통 동기화 변환기가 없습니다. 앱 설치 파일을 확인해 주세요.')
      const helper = process.env['BANDAL_IPAD_BRIDGE']""")
        updated = replace_once(updated, "{ windowsHide: true, env: { ...process.env, ...environment } }", """{ windowsHide: true, env: { ...process.env, ...environment,
            BANDAL_DESKTOP_PROJECTOR: projector,
            BANDAL_DESKTOP_RUNTIME: process.execPath,
            BANDAL_DESKTOP_MODULE_ROOT: app.getAppPath(),
            BANDAL_DESKTOP_BACKEND: projectionBackend } }""")
    args.output.mkdir(parents=True, exist_ok=True)
    files = {"src/main/features/ipadSync/runtime.ts": updated.encode(),
             "resources/ipad-bridge/bridge.py": (here / "bridge.py").read_bytes(),
             "resources/ipad-bridge/projector-host.cjs": (here / "projector-host.cjs").read_bytes(),
             "resources/ipad-bridge/backend.js": backend.read_bytes()}
    patch = []
    manifest = []
    for relative, data in files.items():
        target = args.output / relative
        target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        prior = args.desktop / relative
        old = prior.read_bytes() if prior.is_file() else b""
        manifest.append({"path": relative, "sha256": hashlib.sha256(data).hexdigest(), "byteCount": len(data),
                         "previousSHA256": hashlib.sha256(old).hexdigest() if prior.is_file() else None})
        # Generated backend code is a content-addressed copy, not a huge diff.
        if relative.endswith("backend.js"): continue
        patch.extend(difflib.unified_diff(old.decode().splitlines(keepends=True), data.decode().splitlines(keepends=True),
                     fromfile="a/" + relative if prior.is_file() else "/dev/null", tofile="b/" + relative))
    (args.output / "desktop-projector.patch").write_text("".join(patch))
    source_manifest = here.parent.parent / "DesktopRuntime/upstream/manifest.json"
    (args.output / "manifest.json").write_text(json.dumps({"format": "bandal-desktop-projector-stage", "version": 1,
        "sourceSnapshotManifestSHA256": hashlib.sha256(source_manifest.read_bytes()).hexdigest(), "files": manifest,
        "validation": "test-backend --pdf --projector uses Electron's own ABI on temporary copied DB; no production DB test"}, indent=2) + "\n")
    print(f"Staged {len(files)} files and review patch in {args.output}")


if __name__ == "__main__": main()
