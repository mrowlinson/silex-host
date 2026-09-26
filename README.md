# Real-engine ANF rendering

Five ways to render Apple News Format with Apple's own engines — built while
looking for ground truth good enough to diff a clean-room renderer against.
This repo started life as just `silex-host/`; it now collects every working
(and one experimental) method, each self-contained with its scripts.

| Method | Input | Fidelity | Speed | Needs |
|---|---|---|---|---|
| [`silex-host/`](silex-host/) | your local file | text-exact; photos blank | ~12 s, offline, parallel | Apple Silicon Mac |
| [`sim-local/`](sim-local/) | your local file | full app incl. remote assets | ~30 s, serial | booted sim + `idb` |
| [`sim-url/`](sim-url/) | live server copy by slug | full app | ~10 s, serial | booted sim |
| [`mac-news/`](mac-news/) | live server copy by slug | full app window | ~15 s, serial | macOS News + network |
| [`news-preview/`](news-preview/) | your local file | — | — | EXPERIMENTAL, unproven |

Rule of thumb: `silex-host` for bulk text/layout truth (hundreds of articles,
offline), `sim-local` when you need full-page pixels of your own bytes,
the URL arms when server-backed truth is acceptable, `news-preview` only if
you're on Intel hardware and feeling lucky.

Every method ships its discriminator (no silent blank-shell passes) and a
manifest format; every row fails closed (`REVIEW`/`FAIL`/`IDENT-FAIL`).

## How this was found

The job was ground truth for hundreds of ANF articles — one hand-picked file
is not a test. Each method below was earned by a dead end:

- The sim `applenews://preview/…` route plants `article.json` in
  `LocalDrafts/<channel>/<id>/` — but only for channels the sim's News store
  knows. Fake channels die in a spinner shell that issues zero reads (which
  is why filesystem tracing "proved" nothing loaded). A *real* channel ID
  unlocks full renders of arbitrary local files → `sim-local/`.
- The sim `applenews://article/<id>` route skips planting entirely and renders
  the live copy → `sim-url/`. Multipeer `onDevicePreview` was fully
  reverse-engineered (message structs, both ends) and then found doubly dead:
  no browse response, and the sim handlers are single-`ret` stubs.
- Corpus slugs turned out to be `apple.news` IDs, so macOS News opens them
  directly; the cached assetstore copy proves each capture is the same
  article → `mac-news/`.
- News Preview.app opens local JSON directly — but it's Intel-only and
  crashes on the devices queue under Rosetta on Apple Silicon, and wants a
  manual EULA click. Kept as an experiment, not a path → `news-preview/`.
- Finally: macOS ships macCatalyst Silex in `/System/iOSSupport`. Instead of
  driving any app, `dlopen` the framework and assemble document → layout →
  views → Tangier text by hand, all selectors resolved at runtime, no private
  headers, engine untouched → `silex-host/`.

## Layout

```
silex-host/    in-process Silex CLI + batch wrapper
sim-local/     sim plant+fire+discriminate (your bytes, full app)
sim-url/       sim live-slug batch renderer + variance discriminator
mac-news/      News.app scale capture + assetstore identity proof + news-capture/
news-preview/  NP pipe pieces (experimental) + crash-dodge shim
examples/      list.tsv, candidates.tsv, manifest-sample.tsv
```

## Notes

- Everything runs locally; article files never leave the machine (URL arms
  fetch Apple's live copies by design).
- This repo contains only original interop glue — no Apple code, no article
  content, no private headers.
- System frameworks move under you: pin baselines per OS/Sim/News version.
