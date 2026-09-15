#!/bin/bash
# Upload new_data/<year>/ databases + manifests and new_elections.json to Aliyun OSS.
#
# Usage:
#   OSS_BUCKET=my-bucket ./upload_new_data.sh [year ...]        # default: every year except 2024
#
# Requires ossutil (https://help.aliyun.com/zh/oss/developer-reference/ossutil) already
# configured by you (`ossutil config`), so no credential ever passes through this script.
# The CDN path layout matches new_elections.json: gerrymander/<year>/<CODE>-<year>.db
# and gerrymander/new_elections.json.
#
# Optional: OSS_PREFIX (default "gerrymander"), OSSUTIL (default "ossutil"), DRY_RUN=1.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NEW_DATA="$HERE/new_data"
: "${OSS_BUCKET:?set OSS_BUCKET to the bucket name (e.g. OSS_BUCKET=files-xp-oncology)}"
OSS_PREFIX="${OSS_PREFIX:-gerrymander}"
OSSUTIL="${OSSUTIL:-ossutil}"
DRY_RUN="${DRY_RUN:-0}"

if ! command -v "$OSSUTIL" >/dev/null; then
  echo "ossutil not found: brew install ossutil, then run 'ossutil config'" >&2
  exit 1
fi

years=("$@")
if [ ${#years[@]} -eq 0 ]; then
  for d in "$NEW_DATA"/20[0-2][0-9]; do
    y="$(basename "$d")"
    [ "$y" = "2024" ] && continue
    years+=("$y")
  done
fi

run() {
  if [ "$DRY_RUN" = "1" ]; then echo "+ $*"; else "$@"; fi
}

for y in "${years[@]}"; do
  dir="$NEW_DATA/$y"
  [ -d "$dir" ] || { echo "skip $y: no folder" >&2; continue; }
  echo "== $y"
  # every state db + National db + manifest.json; BUILD_REPORT.md stays local
  for f in "$dir"/*.db "$dir"/manifest.json; do
    run "$OSSUTIL" cp -f "$f" "oss://$OSS_BUCKET/$OSS_PREFIX/$y/$(basename "$f")"
  done
done

echo "== new_elections.json"
run "$OSSUTIL" cp -f "$NEW_DATA/new_elections.json" "oss://$OSS_BUCKET/$OSS_PREFIX/new_elections.json"
echo "done. Verify one URL, e.g. https://files.xp-oncology.cn/$OSS_PREFIX/2016/TX-2016.db"
