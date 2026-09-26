# mac-news — macOS News.app as the render engine

Two scripts, same idea: corpus slugs are `apple.news` IDs, so open the live
URL in macOS News and capture the window.

## mac-news-scale (fast arm)

```sh
./build.sh   # one-time: builds winlist + mac-news-scale (Swift, no Pillow)
ANF_CORPUS=<corpus-dir> ./mac-news-scale <queue.tsv> <outdir> <start> <count>
```

`queue.tsv`: `dir<TAB>slug` per line. Per row: opens
`https://apple.news/<slug>`, finds the new News window, `screencapture`s it,
then PASS iff the window title matches the corpus title AND the pixels beat
size/ink thresholds (else REVIEW — fail closed, never silent).

## gt-scale-capture.py (identity-proof arm)

```sh
cd news-capture && swift build   # -> .build/debug/news-capture (ScreenCaptureKit full-body capture)
./gt-scale-capture.py --manifest <corpus>/manifest.tsv --count 20 --out <dir> --tools <news-capture-dir>
```

Same capture loop, plus an identity chain: the freshly-cached News
assetstore copy (matched by identifier/title) must agree with your corpus
JSON's title and component count, or the row is IDENT-FAIL. A PASS here is
a discriminated render *proven* to be the same article. Dead, delisted, or
silently edited server copies fail closed instead of poisoning ground truth.

## Caveats

- **Server-backed, both scripts.** Your local bytes are the *query*, not the
  render input. For local-file truth use `silex-host/` or `sim-local/`.
- One News window at a time; ~12–15 s/article serial. macOS News + network.
- `manifest.tsv` (corpus index) columns used: `dir` = col 2, `slug` = col 3.
