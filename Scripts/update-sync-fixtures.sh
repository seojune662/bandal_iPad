#!/bin/sh
# Copies the desktop's sync-fixtures/ at one commit into Tests/Fixtures/ and records it in SOURCE.
# Usage: Scripts/update-sync-fixtures.sh <desktop commit> [desktop repo, default ~/dev/bandal]
# Files go one by one through git cat-file: macOS tar would turn the AppleDouble
# fixture (01-basic/root/._bandal.json) into metadata instead of a file.
set -eu
commit=$1
desktop=${2:-$HOME/dev/bandal}
fixtures=$(cd "$(dirname "$0")/.." && pwd)/Tests/Fixtures
rm -rf "$fixtures/sync-fixtures"
git -C "$desktop" ls-tree -r --name-only "$commit" sync-fixtures | while IFS= read -r path; do
  mkdir -p "$fixtures/$(dirname "$path")"
  git -C "$desktop" cat-file blob "$commit:$path" > "$fixtures/$path"
done
echo "seojune662/bandal $(git -C "$desktop" rev-parse --short "$commit")" > "$fixtures/sync-fixtures/SOURCE"
