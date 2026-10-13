#!/usr/bin/env python3
"""Stage the second patch after desktop-integration.patch has been applied."""
import argparse
import difflib
from pathlib import Path
from stage_integration import replace_once


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--desktop", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(); here = Path(__file__).resolve().parent
    updates = {
        "src/main/features/ipadSync/runtime.ts": (here / "desktop-src/runtime.ts").read_text(),
        "resources/ipad-bridge/bridge.py": (here / "bridge.py").read_text(),
        "scripts/build-ipad-bridge.mjs": (here / "desktop-src/build-ipad-bridge.mjs").read_text(),
    }
    updates[".gitignore"] = (args.desktop / ".gitignore").read_text().rstrip() + "\nresources/native/ipad-bridge/\n.cache/ipad-bridge/\nresources/ipad-bridge/__pycache__/\n"
    native = (args.desktop / "scripts/build-native.mjs").read_text()
    native = "import ipadBridge from './build-ipad-bridge.mjs'\n" + native
    updates["scripts/build-native.mjs"] = replace_once(native, "  await calendar(context)", "  await ipadBridge(context)\n  await calendar(context)")
    builder = (args.desktop / "electron-builder.yml").read_text()
    builder = replace_once(builder, "  extraResources:\n    - from: resources/native/calendar", "  extraResources:\n    - from: resources/native/ipad-bridge/darwin-${arch}/bandal-ipad-bridge\n      to: ipad-bridge/bandal-ipad-bridge\n    - from: resources/native/calendar")
    builder = replace_once(builder, "  binaries:\n", "  binaries:\n    - Contents/Resources/ipad-bridge/bandal-ipad-bridge\n")
    builder = replace_once(builder, "win:\n  extraResources:\n", "win:\n  extraResources:\n    - from: resources/native/ipad-bridge/win32-${arch}/bandal-ipad-bridge.exe\n      to: ipad-bridge/bandal-ipad-bridge.exe\n")
    updates["electron-builder.yml"] = builder
    workflow = (args.desktop / ".github/workflows/release.yml").read_text()
    helper_job = '''  ipad-bridge:
    name: iPad companion ${{ matrix.platform }}-${{ matrix.arch }}
    needs: verify
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        include:
          - { os: macos-15, platform: darwin, arch: arm64 }
          - { os: macos-15-intel, platform: darwin, arch: x64 }
          - { os: windows-latest, platform: win32, arch: x64 }
    steps:
      - uses: actions/checkout@v7
        with:
          ref: ${{ needs.verify.outputs.tag }}
      - uses: actions/setup-node@v7
        with:
          node-version: ${{ env.NODE_VERSION }}
      - uses: actions/setup-python@v6
        with:
          python-version: '3.13'
      - run: python -m pip install pyinstaller==6.16.0
      - run: node scripts/build-ipad-bridge.mjs ${{ matrix.arch }}
      - uses: actions/upload-artifact@v6
        with:
          name: ipad-bridge-${{ matrix.platform }}-${{ matrix.arch }}
          path: resources/native/ipad-bridge/

'''
    workflow = replace_once(workflow, "  build:\n    name: Build", helper_job + "  build:\n    name: Build")
    workflow = replace_once(workflow, "    needs: [verify, create-release]", "    needs: [verify, create-release, ipad-bridge]")
    workflow = replace_once(workflow, "      # Compiles main/preload/renderer into out/.", '''      - uses: actions/download-artifact@v7
        with:
          pattern: ipad-bridge-*
          merge-multiple: true
          path: resources/native/ipad-bridge/
      - name: Restore companion executable permissions
        if: runner.os == 'macOS'
        run: chmod +x resources/native/ipad-bridge/darwin-*/bandal-ipad-bridge

      # Compiles main/preload/renderer into out/.''')
    updates[".github/workflows/release.yml"] = workflow
    chunks = []
    for relative, updated in updates.items():
        source = args.desktop / relative
        original = source.read_text() if source.exists() else ""
        chunks.extend(difflib.unified_diff(original.splitlines(keepends=True), updated.splitlines(keepends=True),
                      fromfile="a/" + relative if source.exists() else "/dev/null", tofile="b/" + relative))
    args.output.write_text("".join(chunks)); print(f"Staged {len(updates)} files: {args.output}")


if __name__ == "__main__": main()
