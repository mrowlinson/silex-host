# news-preview — local-JSON rendering via News Preview.app (EXPERIMENTAL)

> **Status: unproven end-to-end. Included for completeness, not as a working
> path.** News Preview is Intel-only (x86_64): on Apple Silicon it runs
> translated under Rosetta and crashes on the devices queue (the arm64e-only
> CoreSimulator can't load into the translated process). `open -F` dodges one
> crash path; nobody has completed a full run.

The prize, if it ever runs on your machine: the only Apple tool that opens a
local `article.json` directly — arbitrary files, exact bytes, no sim.

## Pieces

- `np-winshot.swift` — window lister + capturer.
  `swiftc -o np-winshot np-winshot.swift`; `np-winshot list <owner>` /
  `np-winshot shot <winid> <out.png>`. Works screen-locked.
- `np-render-corpus.sh <manifest.tsv> <count> <outdir>` — per article: copy
  one JSON to scratch, `open -F` it, capture the largest NP window,
  discriminate vs blank (size + ink + variance), manifest row. Relaunches NP
  per article (~15 s each) because AX is blind under Rosetta. **Stops at the
  first-launch EULA and waits for a manual Agree click** — that binds you to
  Apple's license terms, so it is deliberately not automated.
- `NPNoSim.m` — `DYLD_INSERT_LIBRARIES` shim that no-ops
  `NPSimulatedDeviceManager -setup` (the crash site). Unproven:
  `clang -dynamiclib -framework Foundation -o NPNoSim.dylib NPNoSim.m`, then
  `DYLD_INSERT_LIBRARIES=… open -a "News Preview"`.

If you get a full run green on Intel hardware, the discriminator + manifest
format matches the other methods in this repo — PRs welcome.
