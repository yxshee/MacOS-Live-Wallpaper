#!/bin/bash
# Rebuilds the app, then compiles, draws and times every scene in Scenes/.
# Fails if any scene does not compile, draws nothing, or costs more than the
# rule in docs/SHADERS.md allows.
#
#   ./scripts/check-scenes.sh              check; write a preview.jpg for scenes that lack one
#   ./scripts/check-scenes.sh --previews   also redraw every scene's preview.jpg
#
# Timings depend on the Mac, so this is for running locally, not in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

REFRESH=0
for arg in "$@"; do
  case "$arg" in
    --previews) REFRESH=1 ;;
    *) echo "unknown option: $arg (the only option is --previews)" >&2; exit 2 ;;
  esac
done

python3 scripts/update-notices.py --check

# The app reads scenes from its own bundle, so an older build would check
# older scenes: always build first.
./scripts/build-app.sh >/dev/null
APP="build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$APP" --check-scenes --previews "$TMP" | tee "$TMP/report.txt"

status=0
while IFS= read -r line; do
  case "$line" in "ok "*) ;; *) continue ;; esac
  id="$(printf '%s\n' "$line" | awk '{ print $2 }')"
  # The cost is the number in front of "ms/s", wherever the columns fall.
  cost="$(printf '%s\n' "$line" | sed -n 's|.*= *\([0-9.][0-9.]*\) ms/s.*|\1|p')"
  if [ -z "$cost" ]; then
    echo "could not read the cost of $id from: $line" >&2
    status=1
  elif awk -v c="$cost" 'BEGIN { exit !(c + 0 > 20) }'; then
    echo "TOO COSTLY  $id: $cost ms of GPU per second (limit 20)" >&2
    status=1
  fi
  # Scenes from your own Application Support folder are checked too, but only
  # the repository's scenes keep a preview here.
  [ -d "Scenes/$id" ] && [ -f "$TMP/$id.jpg" ] || continue
  if [ "$REFRESH" = 1 ] || [ ! -f "Scenes/$id/preview.jpg" ]; then
    cp "$TMP/$id.jpg" "Scenes/$id/preview.jpg"
  fi
done < "$TMP/report.txt"
exit $status
