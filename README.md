# silex-host — render ANF with Apple's real engine, in-process

Renders Apple News Format `article.json` files using the actual Apple layout +
text engine: the system's macCatalyst `Silex.framework` (+ Tangier), hosted in
a minimal CLI. No simulator, no News.app, no network. Offline, batchable,
~10–15 s/article.

```sh
./build.sh                                  # -> ./render (arm64e macabi)
./render article.json out.png               # default 390x844 (@2x PNG)
./render article.json out.png 1024x1366     # custom viewport
./batch.sh <corpus-dir> <list.tsv> <out>    # manifest.tsv + png/ + verdicts
```

`list.tsv`: one `dir<TAB>slug` per line, files at `<corpus-dir>/<dir>/<slug>.json`
(see [examples/list.tsv](examples/list.tsv)). `SILEX_DEBUG=1` enables view-tree
+ blueprint debug logs.

Text and typography render fully. Remote photos/videos/embeds reserve layout
space but stay blank (no image data source is wired — see Limitations).

## How this was found

This tool came out of the ANFRenderer project, which needed real-engine renders
of hundreds of ANF articles to compare against a clean-room renderer — one
hand-picked article is not ground truth. Every app-driven path fought back:

1. **Sim News preview route** (`applenews://preview/<channel>/<id>` with a
   planted `LocalDrafts/<channel>/<id>/article.json`): dead on arrival with a
   fake channel — the flow validates the channel against the sim's channel
   store (`NAArticleUnavailablePreviewChannelMessage`) or sits in a spinner
   shell that issues zero reads. A *real* channel ID (harvested from feed logs)
   does unlock it, but the sim is single-user, stateful, and slow.
2. **Live-URL routes** (`applenews://article/<id>` in-sim, `apple.news/<slug>`
   in macOS News): these render, and at real scale (24/24, 28/30 batches), but
   every pixel is server-backed — you are rendering Apple's live copy, not your
   local file — and both arms are slow, stateful app automation.
3. **News Preview.app** (renders local JSON directly!): EULA-gated on first
   launch and crash-prone under Rosetta on an Apple Silicon host.
4. **In-process hosting** (this repo): macOS ships macCatalyst Silex in
   `/System/iOSSupport` inside the shared cache. Instead of driving an app,
   `dlopen` the framework and assemble the pipeline by hand — `SXDocument` +
   DOM, layout engine + sizer factories, component view engine + view
   factories, `SXTangierController` text flows — then snapshot a windowless
   `CALayer` to PNG. All classes/selectors resolved at runtime
   (`NSClassFromString` / `NSSelectorFromString` / `NSInvocation`); no private
   headers; the engine itself untouched. The only swizzles are harness-side:
   DOM injection into layout tasks, and default-handling of WebKit auth
   challenges so embeds don't abort offline.

First batch: 24/24 corpus articles PASS with a measured blank-vs-render
discriminator (blanks score exactly 0.0000 nonwhite). The tool has since been
used as the bulk ground-truth oracle: fast enough to run hundreds of articles,
exact enough to diff text/layout against.

## Requirements

- Apple Silicon Mac, macOS 15+
- Xcode command-line tools (`xcrun clang` with the macCatalyst SDK)
- Python 3 + Pillow (only for `batch.sh`'s ink discriminator)

## Output

`render` prints one `RESULT … status=OK title=… dom=<n> presented=<n>
bpsize=<WxH>` line per article (plus harmless Tangier teardown assertions on
stderr). `batch.sh` writes `<out>/manifest.tsv`:

```
dir  slug  title  comps  presented  bpsize  png  bytes  nonwhite_frac  verdict
```

`verdict=PASS` iff `status=OK` and nonwhite fraction > 0.005. `comps` is the
DOM component count, `presented` how many produced views — a quick integrity
signal per article.

## Limitations

- Remote resources (photos, videos, embeds) have no data source: layout
  reserves their space, pixels stay blank. Wiring an image store is the single
  biggest upgrade available.
- One fixed viewport per run; no ads, dark mode, or interaction.
- Single article per process; parallelize at the shell level (4 concurrent
  renders is a safe default).
- arm64e macABI only; depends on system Silex behavior, which Apple can change.

## Provenance

Extracted 2026-09-25 from the ANFRenderer project's T4-mac-news lane. This repo
contains only original interop glue — no Apple code, no article content.
Your ANF files never leave the machine.
