#!/bin/bash
# sim-preview-render.sh — render an arbitrary ANF article.json in sim News
# via the real Apple engine and capture a screenshot.
#
# Recipe (T1-clean-retest w8): plant article.json at
#   Documents/LocalDrafts/<REALCHANNEL>/<identifier>/article.json
# in the sim News container, fire
#   applenews://preview/<REALCHANNEL>/<urlencoded identifier>
# The channel MUST be a real channel known to the sim's News store
# (default: Scientific American, harvested from feed logs); fake channels
# ("testchannel") route to a spinner shell or "Story Unavailable / The
# configured preview channel could not be found."
# (NAArticleUnavailablePreviewChannelMessage, NewsArticles).
#
# Verdict is two-legged: (1) pixel discriminator vs known-blank ref,
# (2) AX tree must contain the article title (catches stale renders when
# navigation fails silently, e.g. slash-bearing identifiers).
# Exit 0 = RENDER (both legs pass); exit 1 otherwise.
#
# Usage: sim-preview-render.sh <article.json> [outdir]
# Env: UDID (default uid851-iphone), CH (default SciAm channel),
#      WAIT (default 8s), BLANKREF (default w3 white-shell ref).
set -u

UDID="${UDID:-A1E4A805-39CE-46F4-91E3-35A712947CBB}"
CH="${CH:-TveHp0EHGTXenwIFMSprU9g}"
WAIT="${WAIT:-8}"
ART="${1:?usage: $0 <article.json> [outdir]}"
OUT="${2:-out}"
TOOLS_DIR0="$(cd "$(dirname "$0")" && pwd)"
BLANKREF="${BLANKREF:-$TOOLS_DIR0/blank-ref.png}"

# No blank ref yet? Capture one first: garbage IDs route to the identical
# blank shell, so this self-calibrates once per sim/News version.
if [ ! -f "$BLANKREF" ]; then
  echo "capturing blank ref via garbage-ID URL -> $BLANKREF"
  xcrun simctl openurl "$UDID" "applenews://preview/$CH/zzz-nope-render-blank" >/dev/null 2>&1 \
    || { echo "RENDER-FAIL: blank-ref openurl failed"; exit 1; }
  sleep "$WAIT"
  xcrun simctl io "$UDID" screenshot "$BLANKREF" >/dev/null 2>&1 \
    || { echo "RENDER-FAIL: blank-ref screenshot failed"; exit 1; }
fi

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
DISCRIMINATE="$TOOLS_DIR/discriminate.py"

ID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('identifier',''))" "$ART")
[ -n "$ID" ] || { echo "RENDER-FAIL: no identifier in $ART"; exit 1; }
TITLE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('title',''))" "$ART")
case "$ID" in
  *"/"*|*":"*) echo "RENDER-FAIL: slash/colon identifier unsupported by URL route: $ID"; exit 1 ;;
esac

NC=$(xcrun simctl get_app_container "$UDID" com.apple.news data 2>/dev/null) \
  || { echo "RENDER-FAIL: no News container on $UDID"; exit 1; }
DEST="$NC/Documents/LocalDrafts/$CH/$ID"
mkdir -p "$OUT" "$DEST"
cp "$ART" "$DEST/article.json"
echo "planted $DEST/article.json"

ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$ID")
xcrun simctl openurl "$UDID" "applenews://preview/$CH/$ENC" \
  || { echo "RENDER-FAIL: openurl failed"; exit 1; }
sleep "$WAIT"
xcrun simctl io "$UDID" screenshot "$OUT/after.png" >/dev/null 2>&1 \
  || { echo "RENDER-FAIL: screenshot failed"; exit 1; }
idb ui describe-all --udid "$UDID" > "$OUT/ax.json" 2>/dev/null \
  || { echo "RENDER-FAIL: AX dump failed"; exit 1; }

# Leg 1: pixel vs blank (downscaled for speed; blank nonwhite ~0.8%).
sips -Z 300 "$OUT/after.png" --out "$OUT/after-small.png" >/dev/null 2>&1
sips -Z 300 "$BLANKREF" --out "$OUT/blank-small.png" >/dev/null 2>&1
PIXEL=$(python3 "$DISCRIMINATE" "$OUT/after-small.png" "$OUT/blank-small.png" 2>&1 | grep -c DISTINCT-RENDER || true)

# Leg 2: AX must contain >=2 significant title words + a ScrollArea.
AXHIT=$(TITLE="$TITLE" python3 -c "
import json, os
ax = json.load(open('$OUT/ax.json'))
labels = ' '.join((x.get('AXLabel') or '') + ' ' + (x.get('AXValue') or '') for x in ax)
title = os.environ['TITLE']
words = [w for w in title.replace(chr(39), ' ').split() if len(w) > 3][:6]
hit = sum(1 for w in words if w[:8] in labels)
scroll = any(x.get('type') == 'ScrollArea' for x in ax)
print('pass' if (hit >= 2 and scroll) else 'fail')
")

echo "pixel_leg=$([ "$PIXEL" -ge 1 ] && echo PASS || echo FAIL) ax_leg=$([ "$AXHIT" = pass ] && echo PASS || echo FAIL) title=$TITLE"
if [ "$PIXEL" -ge 1 ] && [ "$AXHIT" = pass ]; then
  echo "RENDER-PASS: $ID"
  exit 0
else
  echo "RENDER-FAIL: $ID"
  exit 1
fi
