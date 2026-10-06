#!/bin/bash
# Puts the custom engine channel inside a built Mythic.app, so the "Custom" release channel works with nothing
# to download or configure: Mythic finds Contents/Resources/EngineCustom/EngineCatalog-custom.plist and installs
# the archive beside it.
#
#   Tools/package-app-with-engine.sh path/to/Mythic.app [engine output folder from build-wine11-engine.sh]
#
# The archive is a couple of hundred megabytes, which is why it is added to the built app here rather than
# committed to the repository.
set -euo pipefail

APP="${1:?usage: package-app-with-engine.sh Mythic.app [engine folder]}"
OUT="${2:-$HOME/Developer/mythic-engines/wine11}"

for file in Engine.tar.xz EngineCatalog-custom.plist; do
  [ -f "$OUT/$file" ] || { echo "missing $OUT/$file (run Tools/build-wine11-engine.sh first)" >&2; exit 1; }
done

DEST="$APP/Contents/Resources/EngineCustom"
rm -rf "$DEST" && mkdir -p "$DEST"
cp "$OUT/Engine.tar.xz" "$OUT/EngineCatalog-custom.plist" "$DEST/"
echo "Added the custom engine channel to $APP ($(du -sh "$DEST" | cut -f1))"
