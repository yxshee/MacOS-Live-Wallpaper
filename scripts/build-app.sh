#!/bin/bash
# Builds LiveWallpaper.app into ./build. Nothing outside this folder is touched
# unless you pass --install.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'USAGE'
Usage: scripts/build-app.sh [--universal] [--install]

  (no options)   build ./build/LiveWallpaper.app for this Mac
  --universal    one binary for Apple Silicon and Intel (needs full Xcode)
  --install      also copy the app to ~/Applications and start it,
                 replacing a copy that is already running
USAGE
}

UNIVERSAL=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

FLAGS=(-c release)
if [ "$UNIVERSAL" = 1 ]; then FLAGS+=(--arch arm64 --arch x86_64); fi

swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/LiveWallpaper"

APP="build/LiveWallpaper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LiveWallpaper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The shaders ship as source and are compiled once at launch, so building
# needs only the Swift compiler, not Xcode's separate Metal toolchain.
cp Resources/Shaders.metal "$APP/Contents/Resources/"

# Stamp the version from git when there is one: v1.2.3 tags set the version,
# the commit count is the build number.
if git rev-parse --git-dir >/dev/null 2>&1; then
  if TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null)"; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${TAG#v}" "$APP/Contents/Info.plist"
  fi
  if COUNT="$(git rev-list --count HEAD 2>/dev/null)"; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $COUNT" "$APP/Contents/Info.plist"
  fi
fi

# Ad-hoc signature: enough to run on the Mac that built it.
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/LiveWallpaper"))"

if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Applications/LiveWallpaper.app"
  pkill -x LiveWallpaper 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed and started $DEST"
fi
