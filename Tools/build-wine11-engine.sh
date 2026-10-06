#!/bin/bash
# Assembles a Mythic Engine based on Wine 11 and writes its archive and catalog.
#
#   Tools/build-wine11-engine.sh                      download Gcenx's Wine 11.0_1, verify it, assemble
#   WINE_APP="/path/Wine Stable.app" Tools/build-wine11-engine.sh      use an already extracted copy
#
# Needs: gh (to download), x86_64-w64-mingw32-gcc (to build the Steam browser stand-in; or set WRAPPER_EXE),
#        and Mythic Engine already installed (for its DXVK folder; or set DXVK_DIR).
#
# Output (OUT, default ~/Developer/mythic-engines/wine11): Engine.tar.xz, Engine.tar.xz.sha256 and
# EngineCatalog-custom.plist. The catalog names the archive relatively, so the two travel together; use
# Tools/package-app-with-engine.sh to put them inside Mythic.app as a preinstalled "custom" channel.
set -euo pipefail

OUT="${OUT:-$HOME/Developer/mythic-engines/wine11}"
ENGINE_VERSION="${ENGINE_VERSION:-11.0.1}"          # major.minor.patch, as Properties.plist stores it
WINE_TAG="11.0_1"
WINE_ASSET="wine-stable-11.0_1-osx64.tar.xz"
WINE_SHA256="b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388"
DXVK_DIR="${DXVK_DIR:-$HOME/Library/Application Support/Mythic/Engine/DXVK}"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$OUT" && cd "$OUT"

if [ -z "${WINE_APP:-}" ]; then
  [ -f "$WINE_ASSET" ] || gh release download "$WINE_TAG" --repo Gcenx/macOS_Wine_builds --pattern "$WINE_ASSET" --dir .
  [ "$(shasum -a 256 "$WINE_ASSET" | cut -d' ' -f1)" = "$WINE_SHA256" ] || { echo "checksum mismatch for $WINE_ASSET" >&2; exit 1; }
  rm -rf src && mkdir src && tar -xf "$WINE_ASSET" -C src
  WINE_APP="$OUT/src/Wine Stable.app"
fi

WRAPPER_EXE="${WRAPPER_EXE:-$OUT/steamwebhelper_wrapper.exe}"
if [ ! -f "$WRAPPER_EXE" ]; then
  x86_64-w64-mingw32-gcc -O2 -municode -mwindows -static -o "$WRAPPER_EXE" \
    "$HERE/steam-webhelper-wrapper/steamwebhelper_wrapper.c"
fi

rm -rf Engine && mkdir -p Engine/extras
ditto "$WINE_APP/Contents/Resources/wine" Engine/wine
ln -sfn wine Engine/wine/bin/wine64            # Mythic starts wine64; Wine 11 only ships wine
ditto "$DXVK_DIR" Engine/DXVK
cp "$WRAPPER_EXE" Engine/extras/steamwebhelper_wrapper.exe

IFS=. read -r MAJOR MINOR PATCH <<< "$ENGINE_VERSION"
cat > Engine/Properties.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>version</key>
	<dict>
		<key>build</key><string>0</string>
		<key>major</key><integer>$MAJOR</integer>
		<key>minor</key><integer>$MINOR</integer>
		<key>patch</key><integer>$PATCH</integer>
		<key>preRelease</key><string></string>
	</dict>
</dict>
</plist>
PLIST

# Mythic extracts with `tar -x` straight into its Engine folder: no root directory in the archive.
rm -f Engine.tar.xz
XZ_OPT="-T0 -6" tar -cJf Engine.tar.xz -C Engine .
SHA="$(shasum -a 256 Engine.tar.xz | cut -d' ' -f1)"; echo "$SHA" > Engine.tar.xz.sha256
SIZE="$(stat -f %z Engine.tar.xz)"; NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > EngineCatalog-custom.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>version</key><string>0.1.0</string>
	<key>lastUpdated</key><date>$NOW</date>
	<key>channels</key>
	<array>
		<dict>
			<key>name</key><string>custom</string>
			<key>releases</key>
			<array>
				<dict>
					<key>version</key><string>$ENGINE_VERSION</string>
					<key>releaseDate</key><date>$NOW</date>
					<key>downloadURL</key><string>Engine.tar.xz</string>
					<key>size</key><integer>$SIZE</integer>
					<key>critical</key><false/>
					<key>commitSHA</key><string>gcenx-macOS_Wine_builds-$WINE_TAG</string>
				</dict>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST
plutil -lint EngineCatalog-custom.plist
echo "Engine $ENGINE_VERSION: $OUT/Engine.tar.xz ($SIZE bytes, sha256 $SHA)"
