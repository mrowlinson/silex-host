# silex-host — in-process Apple Silex renderer (offline, local files)

Renders an ANF `article.json` with the real engine: the system's macCatalyst
`Silex.framework` (+ Tangier text), hosted in a minimal CLI via ObjC runtime
assembly. No sim, no News.app, no network.

```sh
./build.sh                                # -> ./render (arm64e macabi)
./render <article.json> <out.png> [WxH]   # default 390x844 (@2x PNG)
./batch.sh <corpus-dir> <list.tsv> <out>  # manifest.tsv + png/ + verdicts
```

`list.tsv`: `dir<TAB>slug` per line (files at `<corpus>/<dir>/<slug>.json`).
`batch.sh` verdict PASS = exit OK + nonwhite-pixel fraction > 0.005 (measured
blanks score exactly 0.0000). `SILEX_DEBUG=1` enables view-tree + blueprint
logs.

## How it works

`render.m` dlopens Silex from the shared cache and assembles the layout +
view graph by hand (all selectors resolved at runtime, no private headers):

- `SXDocument` + `SXDocumentController` + containers + `SXDOMFactory` DOM
- layout: pipeline + op factory + 24 sizer factories + coordinator
- views: `SXComponentViewEngine` + 24 view factories, presentation-delegate
  stub (vends Tangier controller), top-level + recursive nested presentation
- text: `SXTextLayouter` wired into each `SXTextView`, flow rebuild + canvas
- snapshot: windowless `CALayer renderInContext` to 2x PNG

Workarounds (harness-side, engine untouched): DOM injection into layout tasks,
and default-handling of WebKit auth challenges (embeds would abort offline).

## Limitations

- Remote resources (photos, videos, embeds) have no data source: layout
  reserves space, pixels stay blank. Text/typography is fully rendered.
- Single fixed viewport per run; no ads, dark mode, interaction.
- ~10–15 s/article. Parallelize at the shell level (4 concurrent is safe).
