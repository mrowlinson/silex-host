#!/bin/bash
# np-render-corpus.sh — EXPERIMENTAL, UNPROVEN end-to-end. Would render
# ARBITRARY local article.json via News Preview.app (host).
#
# Status: News Preview is Intel-only (x86_64) and crashes on the devices queue
# under Rosetta on Apple Silicon; `open -F` dodges one crash path but no full
# run has ever completed. Two gates before this can work: (1) the app must
# survive launch on your machine, (2) its first-launch EULA needs one manual
# Agree click in the license sheet. Until then every run aborts.
#
# Per article: copy ONE json to scratch (never bulk-copy the corpus),
# `open -F` (fresh: dodges the restore-path crash), capture the largest
# NP window, discriminate vs blank (size+ink+variance), manifest row.
# AX is broken under Rosetta (System Events sees no NP windows), so NP is
# relaunched per article (~15s each) instead of Cmd+W.
#
# Usage: np-render-corpus.sh <manifest.tsv> <count> <outdir>
set -u
MANIFEST="$1"; COUNT="$2"; OUT="$3"
CORPUS="$(dirname "$MANIFEST")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINSHOT_BIN="${WINSHOT_BIN:-$SCRIPT_DIR/np-winshot}"
[ -x "$WINSHOT_BIN" ] || { echo "build it first: swiftc -o $SCRIPT_DIR/np-winshot $SCRIPT_DIR/np-winshot.swift"; exit 2; }
mkdir -p "$OUT"
MAN="$OUT/manifest.tsv"
echo -e "n\tdir\tslug\tpng\tpass\tink\tvar\tw\th" > "$MAN"

discriminate() { # $1=png -> "ok|fail ink var w h size"
  python3 - "$1" <<'EOF'
import sys, statistics
from PIL import Image
img = Image.open(sys.argv[1]).convert("L"); w, h = img.size
g = img.resize((200, max(1, int(200*h/w))))
px = list(g.get_flattened_data()) if hasattr(g, "get_flattened_data") else list(g.getdata())
ink = sum(1 for p in px if p < 128)/len(px); var = statistics.pvariance(px)
import os; st = os.path.getsize(sys.argv[1])
ok = "ok" if (st > 50000 and ink > 0.02 and var > 500.0) else "fail"
print(f"{ok} {ink:.4f} {var:.0f} {w} {h} {st}")
EOF
}

# EULA gate probe: launch NP bare, look for the license sheet text via
# window capture + size heuristic (EULA sheet ~= 652x372 untitled).
pkill -x "News Preview" 2>/dev/null; sleep 1
open -F -a "News Preview"; sleep 8
if "$WINSHOT_BIN" list "News Preview" | grep -q .; then
  WID=$("$WINSHOT_BIN" list "News Preview" | head -1 | cut -f1)
  "$WINSHOT_BIN" shot "$WID" "$OUT/_eula-probe.png"
  read -r ok ink var w h st <<<"$(discriminate "$OUT/_eula-probe.png")"
  echo "eula-probe: win=$WID ${w}x${h} ink=$ink var=$var"
  # EULA sheet is text-dense (high ink) at a small fixed size; the bare
  # Devices window is sparse. Owner must verify visually on first run.
fi
echo "If the license sheet is up, have the owner click Agree once, then re-run."
echo "Press ENTER when the EULA is accepted (or Ctrl-C to abort)."; read -r _
pkill -x "News Preview" 2>/dev/null; sleep 1

passes=0; n=0
# Deterministic round-robin order (variety across publishers), no subshell.
ORDER="$OUT/_order.tsv"
python3 - "$MANIFEST" "$((COUNT*2))" > "$ORDER" <<'EOF'
import sys, random
rows = [l.split("\t") for l in open(sys.argv[1]).read().splitlines()[1:]]
by_dir = {}
for c in rows:
    if len(c) >= 3: by_dir.setdefault(c[1], []).append(c[2])
rng = random.Random(7); dirs = sorted(by_dir); rng.shuffle(dirs)
for v in by_dir.values(): rng.shuffle(v)
out, i = [], 0
while len(out) < int(sys.argv[2]):
    added = False
    for d in dirs:
        if i < len(by_dir[d]): out.append(f"{d}\t{by_dir[d][i]}"); added = True
    if not added: break
    i += 1
print("\n".join(out))
EOF
while IFS=$'\t' read -r dir slug; do
  [ "$passes" -ge "$COUNT" ] && break
  n=$((n+1)); src="$CORPUS/$dir/$slug.json"; [ -f "$src" ] || continue
  work="$OUT/_work.json"; cp "$src" "$work"
  open -F -a "News Preview" "$work"; sleep 10
  line=$("$WINSHOT_BIN" list "News Preview" | sort -t' ' -k1,1n | tail -1)
  [ -z "$line" ] && { echo "[$n] $dir/$slug: NO-WINDOW"; pkill -x "News Preview"; sleep 1; continue; }
  WID=$(echo "$line" | cut -f1)
  png="$OUT/np-$(printf %02d $((passes+1)))-$slug.png"
  "$WINSHOT_BIN" shot "$WID" "$png"
  read -r ok ink var w h st <<<"$(discriminate "$png")"
  if [ "$ok" = ok ]; then passes=$((passes+1)); verdict=PASS; else verdict=BLANK-FAIL; fi
  echo "[$n] $dir/$slug: $verdict ink=$ink var=$var ${w}x${h}"
  echo -e "$n\t$dir\t$slug\t$(basename "$png")\t$verdict\t$ink\t$var\t$w\t$h" >> "$MAN"
  rm -f "$work"; pkill -x "News Preview" 2>/dev/null; sleep 1
done < "$ORDER"
echo "NP-SCALE: $passes/$COUNT PASS (see $MAN)"
[ "$passes" -ge "$COUNT" ]
