#!/usr/bin/env python3
"""mac-news-scale.py — open corpus slugs in macOS News, capture, discriminate.
Usage: mac-news-scale.py <queue.tsv> <outdir> <start> <count>
queue.tsv: dir<TAB>slug per line. Appends manifest rows to outdir/manifest.tsv.
Reads ONLY each article's title from the corpus JSON (selective, no bulk copy).
Env: ANF_CORPUS=<dir of <publisher>/<slug>.json files> (required),
     WINLIST_BIN_DIR=<dir holding the `winlist` binary> (default: this script's dir;
     build with: swiftc winlist.swift -o winlist).
"""
import csv, json, os, re, subprocess, sys, time

CORPUS = os.environ.get("ANF_CORPUS", "")
if not CORPUS:
    sys.exit("set ANF_CORPUS=<corpus dir> (contains <publisher>/<slug>.json)")
BIN = os.environ.get("WINLIST_BIN_DIR",
                     os.path.dirname(os.path.abspath(__file__)))


def news_windows():
    out = subprocess.run([f"{BIN}/winlist"], capture_output=True, text=True).stdout
    wins = {}
    for line in out.splitlines():
        m = re.match(r"(\d+) \| News \| (.*)", line)
        if m:
            wins[int(m.group(1))] = m.group(2)
    return wins


def norm(s):
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


def title_match(ctitle, wtitle):
    c, w = norm(ctitle), norm(wtitle)
    if not c or not w:
        return False
    return c[:30] in w or w[:30] in c or c.split()[:4] == w.split()[:4]


def stats(png):
    from PIL import Image
    import statistics
    im = Image.open(png).convert("L")
    px = list(im.get_flattened_data())
    step = max(1, len(px) // 200000)
    return im.size, round(statistics.mean(px[::step]), 1), round(statistics.stdev(px[::step]), 1)


def main():
    queue, outdir, start, count = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    rows = [l.rstrip("\n").split("\t") for l in open(queue) if l.strip()]
    os.makedirs(f"{outdir}/pngs", exist_ok=True)
    man = open(f"{outdir}/manifest.tsv", "a")
    for idx in range(start, min(start + count, len(rows))):
        d, slug = rows[idx]
        try:
            ctitle = json.load(open(f"{CORPUS}/{d}/{slug}.json")).get("title", "")
        except Exception as e:
            print(f"[{idx}] {slug} CORPUS-READ-FAIL {e}", flush=True)
            continue
        before = news_windows()
        subprocess.run(["open", "-a", "News", f"https://apple.news/{slug}"])
        time.sleep(9)
        after = news_windows()
        new = sorted(set(after) - set(before))
        if not new:
            print(f"[{idx}] {slug} NO-WINDOW", flush=True)
            man.write(f"{idx}\t{d}\t{slug}\tNO-WINDOW\t\t\t\t\n")
            man.flush()
            continue
        wid = new[-1]
        png = f"{outdir}/pngs/{idx:02d}-{slug}.png"
        subprocess.run(["screencapture", f"-l{wid}", "-x", png])
        time.sleep(1)
        try:
            (w, h), mean, stdev = stats(png)
            kb = os.path.getsize(png) // 1024
        except Exception as e:
            print(f"[{idx}] {slug} CAP-FAIL {e}", flush=True)
            continue
        wtitle = after[wid]
        m = "MATCH" if title_match(ctitle, wtitle) else "NOMATCH"
        ok = "PASS" if (m == "MATCH" and stdev > 40 and kb > 100) else "REVIEW"
        print(f"[{idx}] {slug} {ok} {m} {w}x{h} sd={stdev} {kb}KB :: {wtitle[:60]}", flush=True)
        man.write(f"{idx}\t{d}\t{slug}\t{ok}\t{m}\t{w}x{h}\t{stdev}\t{kb}KB\t{wtitle}\n")
        man.flush()
    man.close()


if __name__ == "__main__":
    main()
