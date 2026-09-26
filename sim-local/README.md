# sim-local — full-app render of YOUR local file in sim News

Plants `article.json` into the sim News container and fires
`applenews://preview/<REAL-channel>/<id>`. Full app fidelity, including
remote assets over the network.

The gate everything else missed: **the channel must be real.** Fake channels
route to a spinner shell (or "Story Unavailable / The configured preview
channel could not be found"). The default borrows a real channel ID harvested
from feed logs (Scientific American) — the article body rendered is yours;
the masthead will show the borrowed brand.

## Requirements

- Apple Silicon Mac, Xcode with an iOS sim runtime that includes News
- A booted iPhone sim (`UDID` env, default baked in — override for yours)
- Meta's `idb` with companion access (accessibility taps + AX dumps)

## Run

```sh
./sim-news-unlock.sh            # drive News past Welcome (taps Continue;
                                # persists — later runs no-op). Proof PNG out.
./sim-preview-render.sh <article.json> [outdir]   # exit 0 = RENDER
```

Env: `UDID`, `CH` (real channel ID), `WAIT` (settle seconds, default 8),
`BLANKREF` (default: `./blank-ref.png`, auto-captured on first run via a
garbage-ID URL, which routes to the identical blank shell).

## Verdict (two legs, both required)

1. **Pixel**: downscaled candidate vs blank ref (`discriminate`, Swift
   single-file, Foundation+ImageIO only — build once with `./build.sh`) —
   renders read 6–66% nonwhite vs ~0.8% for the shell.
2. **AX title**: ≥2 significant title words + a ScrollArea in the `idb`
   accessibility dump. This leg catches stale renders: when navigation fails
   silently the pixels can be a pixel-identical *previous* article.

## Limitations

- Identifiers containing `/` or `:` don't route, even URL-encoded (whole
  publishers fail closed — fail the row, don't silently pass).
- The sim is single-user: one operator at a time, ~30 s/article serial.
- Atime-proven: only the planted `LocalDrafts/<real-channel>/` copy is read.
