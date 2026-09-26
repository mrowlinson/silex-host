# silex-host — render Apple News Format with Apple's own engine

`article.json` in, PNG out — laid out and typeset by the real Apple News
rendering stack, with no simulator, no News app, and no network.

```sh
./build.sh                               # -> ./render (Apple Silicon, macCatalyst)
./render article.json out.png            # default 390x844 viewport (@2x PNG)
./render article.json out.png 1024x1366  # custom viewport
./batch.sh <corpus-dir> <list.tsv> <out> # render many; writes manifest.tsv + png/
```

`list.tsv` is one article per line — `<directory><TAB><slug>`, resolved to
`<corpus-dir>/<directory>/<slug>.json` (see
[examples/list.tsv](examples/list.tsv)). `SILEX_DEBUG=1` turns on view-tree
and layout debug logging.

## Why this exists

If you work with Apple News Format — building a renderer, studying layouts,
regression-testing feed output — you need ground truth: *what would Apple
itself draw for this file?* The obvious ways to get it all hurt:

- **Simulator + News app.** The `applenews://preview/…` route validates its
  channel against the device's channel store and silently refuses unknown
  ones; the `applenews://article/…` route works but fetches Apple's live
  server copy, not your local bytes. Either way you're nursing a stateful,
  single-user simulator.
- **macOS News automation.** Works, and scales to dozens of articles — but
  again server-backed, app-bound, and slow.
- **News Preview.app.** The one Apple tool that opens local JSON directly —
  when it doesn't crash, and once you've clicked through its first-launch
  license gate.

`silex-host` sidesteps apps entirely. macOS ships the News layout engine —
macCatalyst `Silex.framework` plus Tangier text — in `/System/iOSSupport`,
inside the shared cache. This tool `dlopen`s it and assembles a render
pipeline by hand: document + DOM, layout engine and sizer factories,
component view engine and view factories, Tangier text flows — then snapshots
a windowless layer to PNG. Every class and selector is resolved at runtime;
there are no private headers and no Apple code in this repo. The engine
itself is untouched — the only patches are harness-side (feeding the DOM
into layout tasks, and default-handling WebKit auth challenges so offline
embeds don't abort).

The result is a hermetic oracle: same bytes in, same pixels out, ~10–15
seconds per article, trivially parallelized at the shell level.

## Output

Each render prints one machine-readable line:

```
RESULT … status=OK title=… dom=<n> presented=<n> bpsize=<WxH>
```

(`dom` = component count, `presented` = views produced — a quick integrity
signal. Harmless Tangier teardown assertions may appear on stderr.)

`batch.sh` renders a whole list and writes `<out>/manifest.tsv`
([sample](examples/manifest-sample.tsv)):

```
dir  slug  title  comps  presented  bpsize  png  bytes  nonwhite_frac  verdict
```

`verdict=PASS` means the render exited OK *and* beat a measured
blank-page discriminator (genuinely blank renders score exactly 0.0000
nonwhite pixels).

## Requirements

- Apple Silicon Mac, macOS 15 or later
- Xcode command-line tools (for `xcrun clang` + the macCatalyst SDK)
- Python 3 + Pillow (only for `batch.sh`'s ink measurement)

## Limitations

- **Remote images, videos, and embeds render blank.** Layout reserves their
  space, but no image data source is wired — text and typography are exact,
  photography is not. This is the single biggest possible upgrade.
- One fixed viewport per run; no ads, dark mode, or interaction.
- One article per process (run several in parallel; 4 concurrent is safe).
- It hosts system frameworks, so output can shift with macOS updates. Pin
  your baselines per OS version.

## Notes

- Everything runs locally; your ANF files never leave the machine.
- This repo contains only original interop glue — no Apple code, no article
  content, no private headers.
