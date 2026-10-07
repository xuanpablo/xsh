#!/usr/bin/env bash
# Fails when the diff against origin/main adds a file over LIMIT bytes.
# Already-committed site assets are fine; only new or modified files count.
set -euo pipefail
limit=1048576
base="$(git merge-base origin/main HEAD)"
status=0
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  size=$(($(wc -c < "$f")))
  if [ "$size" -gt "$limit" ]; then
    echo "::error file=$f::${size} bytes, over the 1 MiB limit"
    status=1
  fi
done < <(git diff --name-only --diff-filter=AC -z "$base" HEAD)
exit $status
