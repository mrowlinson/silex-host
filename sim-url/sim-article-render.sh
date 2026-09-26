#!/bin/bash
# sim-article-render.sh — render corpus articles via real sim News engine.
# For each article slug (Apple ID = corpus <dir>/<slug>.json basename),
# fires applenews://article/<slug> and screenshots. Verdict per shot via
# pixel-variance discriminator vs known-blank reference (see pngvar.swift).
# Usage: Tools/sim-article-render.sh candidates.tsv outdir [start [count]]
# candidates.tsv: slug<TAB>host<TAB>dir<TAB>title (header row skipped)
set -u
UDID="${UDID:-A1E4A805-39CE-46F4-91E3-35A712947CBB}"
CAND="${1:?usage: $0 candidates.tsv outdir [start [count]]}"
OUT="${2:?usage: $0 candidates.tsv outdir [start [count]]}"
START="${3:-1}"
COUNT="${4:-0}"
mkdir -p "$OUT"
i=0; done_n=0
tail -n +2 "$CAND" | while IFS=$'\t' read -r slug host dir title; do
  i=$((i+1))
  if [ "$i" -lt "$START" ]; then continue; fi
  if [ "$COUNT" -gt 0 ] && [ "$done_n" -ge "$COUNT" ]; then break; fi
  echo "[$i] $slug ($host) :: $title"
  if ! xcrun simctl openurl "$UDID" "applenews://article/$slug" >/dev/null 2>&1; then
    echo "  openurl FAILED" >> "$OUT/RESULTS.tsv"
    printf '%s\t%s\t%s\tOPENURL-FAIL\t0\t0\n' "$slug" "$host" "$dir" >> "$OUT/RESULTS.tsv"
    continue
  fi
  sleep 9
  png="$OUT/$slug.png"
  xcrun simctl io "$UDID" screenshot "$png" >/dev/null 2>&1
  PNGVAR="$(dirname "$0")/pngvar"
  [ -x "$PNGVAR" ] || "$(dirname "$0")/build.sh" >&2
  read -r var ncolors < <("$PNGVAR" "$png")
  echo "  var=$var colors=$ncolors bytes=$(stat -f %z "$png")"
  printf '%s\t%s\t%s\tSHOT\t%s\t%s\n' "$slug" "$host" "$dir" "$var" "$ncolors" >> "$OUT/RESULTS.tsv"
  done_n=$((done_n+1))
done
echo "done; results in $OUT/RESULTS.tsv"
