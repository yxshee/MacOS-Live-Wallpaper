#!/bin/bash
# Compiles, draws and times every bundled shader scene, and refreshes each
# scene's preview.jpg. Fails if any scene does not compile, draws nothing, or
# costs more than the rule in docs/SHADERS.md allows.
#
# Timings depend on the Mac, so this is for running locally, not in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper"
[ -x "$APP" ] || ./scripts/build-app.sh >/dev/null

python3 scripts/update-notices.py --check

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$APP" --check-scenes --previews "$TMP" | tee "$TMP/report.txt"

status=0
while read -r mark id ms _ _ _ _ _ _ cost _; do
  [ "$mark" = "ok" ] || continue
  if awk -v c="$cost" 'BEGIN { exit !(c > 20) }'; then
    echo "TOO COSTLY  $id: $cost ms of GPU per second (limit 20)" >&2
    status=1
  fi
  [ -f "$TMP/$id.jpg" ] && cp "$TMP/$id.jpg" "Scenes/$id/preview.jpg"
done < "$TMP/report.txt"
exit $status
