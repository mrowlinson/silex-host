# sim-url — live-article render in sim News by slug

Fires `applenews://article/<slug>` per row (corpus slug = Apple article ID)
and screenshots. Bodies arrive over the network into memory — nothing is
planted, nothing touches disk.

```sh
./sim-article-render.sh candidates.tsv outdir [start [count]]
```

`candidates.tsv`: `slug<TAB>host<TAB>dir<TAB>title` with a header row
(see `../examples/candidates.tsv`). Writes `outdir/RESULTS.tsv`
(`slug host dir SHOT|OPENURL-FAIL var ncolors`) + one PNG per slug.

## Verdict

`pngvar` (Swift, no dependencies beyond macOS) prints variance +
distinct-color count over a downscaled frame. Build once with
`./build.sh`. Calibrated: blank shell var≈243/colors≈218; renders
var≈2700–12500/colors≈900–8900. Cutoff: var > 1500 AND colors > 500.
Verified bit-near-identical to the former Pillow implementation on 24
renders + blank (max Δvar=1, Δcolors=2, all verdicts agree).
Unknown slugs are ignored by News (no navigation) — they fail closed as
blank, they don't error.

## Caveats

- **Server-backed**: you render Apple's live copy, not your local bytes.
  Pair each row with a title check against your corpus JSON when identity
  matters (see `../mac-news/gt-scale-capture.swift` for that pattern).
- Sim must be booted with News past Welcome (use `../sim-local/` unlock);
  ~9 s settle per article, serial. `UDID` env override.
