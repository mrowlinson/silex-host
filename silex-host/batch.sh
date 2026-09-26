#!/bin/sh
# batch.sh — render a list of corpus articles via the real Silex engine.
# usage: batch.sh <corpus-dir> <list.tsv: dir<TAB>slug> <out-dir> [WxH]
set -u
D=$(dirname "$0")
CORPUS=$1; LIST=$2; OUT=$3; GEO=${4:-390x844}
mkdir -p "$OUT/png"
MANIFEST="$OUT/manifest.tsv"
printf 'dir\tslug\ttitle\tcomps\tpresented\tbpsize\tpng\tbytes\tnonwhite_frac\tverdict\n' > "$MANIFEST"
pass=0; fail=0
while IFS='	' read -r dir slug _rest; do
  [ -z "$dir" ] && continue
  case "$dir" in \#*) continue;; esac
  js="$CORPUS/$dir/$slug.json"
  png="$OUT/png/$slug.png"
  log=$("$D/render" "$js" "$png" "$GEO" 2>&1 | grep -E 'RESULT|Terminating' | tail -2 | tr '\n' '|')
  verdict=FAIL; title='?'; comps=0; pres=0; bps='?'; nw='0'; bytes=0
  if [ -f "$png" ]; then
    bytes=$(stat -f%z "$png" 2>/dev/null || stat -c%s "$png")
    nw=$(python3 -c "
from PIL import Image
im = Image.open('$png').convert('L')
px = im.load(); w,h = im.size
n=0; tot=0
for y in range(0,h,7):
    for x in range(0,w,7):
        tot+=1
        if px[x,y] < 250: n+=1
print(f'{n/max(tot,1):.4f}')
" 2>/dev/null || echo 0)
  fi
  title=$(echo "$log" | sed -n 's/.*title=//p' | sed 's/|.*//' | cut -c1-80)
  comps=$(echo "$log" | sed -n 's/.*dom=\([0-9]*\).*/\1/p' | head -1)
  pres=$(echo "$log" | sed -n 's/.*presented=\([0-9]*\).*/\1/p' | head -1)
  bps=$(echo "$log" | sed -n 's/.*bpsize=\([0-9x]*\).*/\1/p' | head -1)
  ok=$(echo "$log" | grep -c 'status=OK' || true)
  big=$(python3 -c "print('y' if float('$nw') > 0.005 else 'n')" 2>/dev/null || echo n)
  if [ "$ok" -ge 1 ] && [ "$big" = y ]; then verdict=PASS; pass=$((pass+1)); else fail=$((fail+1)); fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$dir" "$slug" "$title" "$comps" "$pres" "$bps" "$slug.png" "$bytes" "$nw" "$verdict" >> "$MANIFEST"
  echo "$verdict $dir/$slug comps=${comps:-?} pres=${pres:-?} bps=${bps:-?} nw=$nw"
done < "$LIST"
echo "DONE pass=$pass fail=$fail manifest=$MANIFEST"
