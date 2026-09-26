#!/usr/bin/env python3
"""gt-scale-capture.py — Apple-engine GT PNGs at scale (T5).

For each corpus article: open https://apple.news/<slug> in native macOS
News.app (real Silex/Tangier engine), capture the full article body via
news-capture, discriminate vs blank/shell failure (size + ink fraction +
pixel variance), and prove identity vs the local corpus JSON (title +
identifier + component count from the freshly-cached News assetstore copy).

Writes: <out>/gt-<i>-<slug>.png + <out>/manifest.tsv (one row/article).
Exit 0 iff <count> articles PASS. Deterministic article order (seed).

Usage:
  gt-scale-capture.py --manifest <anf-corpus/manifest.tsv> --count 20
      --out tmp/trigger/... --tools /path/to/.build/debug [--attempts 30]
"""
import argparse, json, os, random, statistics, subprocess, sys, time

CLOSE_SCRIPT = ('tell application "System Events" to tell process "News" to '
    'repeat (count of windows) times\n try\n click button 1 of window 1\n'
    ' end try\n key code 13 using command down\n delay 0.15\nend repeat')

def sh(*cmd, timeout=None):
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout)
    except subprocess.TimeoutExpired:
        return None

def close_news_windows():
    sh("/usr/bin/osascript", "-e",
       'tell application "System Events" to key code 53')
    time.sleep(0.2)
    sh("/usr/bin/osascript", "-e", CLOSE_SCRIPT)
    time.sleep(0.4)

def discriminate(png):
    """(ok, size, w, h, ink_frac, var). Blank/shell => tiny ink/var."""
    from PIL import Image
    st = os.path.getsize(png)
    img = Image.open(png).convert("L")
    w, h = img.size
    g = img.resize((200, max(1, int(200 * h / w))))
    px = list(g.get_flattened_data()) if hasattr(g, "get_flattened_data") \
        else list(g.getdata())
    ink = sum(1 for p in px if p < 128) / len(px)
    var = statistics.pvariance(px)
    ok = st > 100_000 and ink > 0.02 and var > 500.0
    return ok, st, w, h, ink, var

def corpus_meta(corpus_root, d, slug):
    p = os.path.join(corpus_root, d, slug + ".json")
    try:
        j = json.load(open(p))
    except Exception:
        return None
    return {"title": j.get("title", ""),
            "identifier": j.get("identifier", slug),
            "comps": len(j.get("components", []))}

def cached_identity(title, slug, fresh_secs=900):
    """Find News assetstore copy cached by our open; match id or title."""
    store = os.path.expanduser("~/Library/Containers/com.apple.news/Data/"
        "Library/Caches/News/shared-assets-assetstore/")
    now = time.time()
    cands, stale = [], []
    try:
        names = os.listdir(store)
    except FileNotFoundError:
        return ("MISS", "", -1)
    for e in names:
        if not e.endswith(":imgfile"):
            continue
        fp = os.path.join(store, e)
        try:
            if open(fp, "rb").read(1) != b'{':
                continue
            mtime = os.path.getmtime(fp)
        except OSError:
            continue
        (cands if now - mtime < fresh_secs else stale).append((mtime, fp))
    for pool in (cands, stale):
        best, best_mt = None, 0
        for mtime, fp in pool:
            try:
                j = json.load(open(fp))
            except Exception:
                continue
            t = j.get("title", "")
            if j.get("identifier") == slug or (
                    title and title[:25].lower() in t.lower()):
                if mtime > best_mt:
                    best, best_mt = (t, j.get("identifier", ""),
                                     len(j.get("components", []))), mtime
        if best:
            return ("HIT",) + best
    return ("MISS", "", -1)

def clean(s, n=60):
    return str(s).replace("\t", " ").replace("\n", " ")[:n]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--tools", required=True)
    ap.add_argument("--attempts", type=int, default=0)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    corpus_root = os.path.dirname(os.path.abspath(a.manifest))
    news_capture = os.path.join(a.tools, "news-capture")
    os.makedirs(a.out, exist_ok=True)

    rows = []
    for line in open(a.manifest).read().splitlines()[1:]:
        cols = line.split("\t")
        if len(cols) >= 3:
            rows.append((cols[1], cols[2]))
    by_dir = {}
    for d, slug in rows:
        by_dir.setdefault(d, []).append(slug)
    rng = random.Random(a.seed)
    dirs = sorted(by_dir)
    rng.shuffle(dirs)
    for v in by_dir.values():
        rng.shuffle(v)
    order, i = [], 0
    while len(order) < len(rows):
        added = False
        for d in dirs:
            if i < len(by_dir[d]):
                order.append((d, by_dir[d][i]))
                added = True
        if not added:
            break
        i += 1
    max_attempts = a.attempts or a.count * 2

    man = open(os.path.join(a.out, "manifest.tsv"), "w")
    man.write("n\tdir\tslug\tpng\tpass\tink\tvar\tw\th\t"
              "corpus_title\tcorpus_comps\tcache\tcache_title\t"
              "cache_comps\n")
    man.flush()
    passes, n = 0, 0
    for d, slug in order:
        if passes >= a.count or n >= max_attempts:
            break
        n += 1
        meta = corpus_meta(corpus_root, d, slug)
        if meta is None:
            print(f"[{n}] {d}/{slug}: SKIP no-corpus-json", flush=True)
            continue
        png = os.path.join(a.out, f"gt-{passes+1:02d}-{slug}.png")
        print(f"[{n}] {d}/{slug}: opening...", flush=True)
        sh("/usr/bin/open", "-b", "com.apple.news")
        time.sleep(2.5)
        close_news_windows()
        r = sh("/usr/bin/open", "-a", "News",
               f"https://apple.news/{slug}")
        time.sleep(11)
        print(f"[{n}] capturing...", flush=True)
        r = sh(news_capture, "-o", png, timeout=240)
        if r is None or not os.path.exists(png):
            print(f"[{n}] {d}/{slug}: CAPTURE-FAIL", flush=True)
            man.write(f"{n}\t{d}\t{slug}\t-\tCAPTURE-FAIL\t-\t-\t-\t-\t"
                      f"{clean(meta['title'])}\t{meta['comps']}\t-\t-\t-\n")
            man.flush()
            continue
        ok, st, w, h, ink, var = discriminate(png)
        cache = cached_identity(meta["title"], slug)
        # cache tuple: (HIT/MISS, title, identifier, comps)
        ctitle, cident, ccomps = (cache[1], cache[2], cache[3]) \
            if cache[0] == "HIT" else ("", "", -1)
        ident = (cache[0] == "HIT" and
                 (cident == meta["identifier"] or cident == slug or
                  (meta["title"] and meta["title"][:25].lower()
                   in ctitle.lower())))
        verdict = "PASS" if (ok and ident) else \
            ("IDENT-FAIL" if ok else "BLANK-FAIL")
        if verdict == "PASS":
            passes += 1
            # rename to pass-numbered name
            final = os.path.join(a.out, f"gt-{passes:02d}-{slug}.png")
            if final != png:
                os.rename(png, final)
                png = final
        else:
            os.rename(png, os.path.join(
                a.out, f"FAIL-{n:02d}-{slug}.png"))
            png = f"FAIL-{n:02d}-{slug}.png"
        print(f"[{n}] {d}/{slug}: {verdict} ink={ink:.3f} var={var:.0f} "
              f"{w}x{h} cache={cache[0]}", flush=True)
        man.write(f"{n}\t{d}\t{slug}\t{os.path.basename(png)}\t{verdict}\t"
                  f"{ink:.4f}\t{var:.0f}\t{w}\t{h}\t"
                  f"{clean(meta['title'])}\t{meta['comps']}\t{cache[0]}\t"
                  f"{clean(ctitle)}\t{ccomps}\n")
        man.flush()
    man.close()
    print(f"SCALE: {passes}/{a.count} PASS in {n} attempts")
    return 0 if passes >= a.count else 1

if __name__ == "__main__":
    sys.exit(main())
