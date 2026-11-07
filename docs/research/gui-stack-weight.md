# GUI stack weight for a Zig qimgv on Linux

Research for <https://github.com/glyh/qimgv/issues/12>. Question: if the UI leaves Qt, is anything actually lighter — or is "keep Qt, own the hot core in Zig" the only answer that pays?

## Method

Each stack was built as the smallest realistic window: one window, a scrollable container of 5 000 items, nothing else. Measured under `Xvfb :99` with a 2 s settle, sampling `/proc/<pid>/status` `VmRSS` (plus `Pss` and `VmHWM`), 8 runs per configuration across two independent sweeps (`/tmp/wf/guistack/results.tsv`, `reverify.tsv`). Harness: `/tmp/wf/guistack/measure.sh`. Machine: Intel Core Ultra 7 258V, 8 cores, 30 GB.

## Resident set (MB, RSS)

| Stack | empty | + 5 000 items | spread |
|---|---|---|---|
| **Qt6 Widgets** | **44.1** | **64.4 – 83.9** (mean 73.0) | bimodal: ~66 and ~76 clusters |
| GTK4 | 61.0 | 64.0 | ±0.2 |
| GTK3 | 33.9 | 40.4 | ±0.2 |
| Qt Quick (QML) | 182.6 | 194.2 | ±0.2 |
| SDL3 | 149.3 | 150.4 | ±0.1 |

For reference, the real app: **`qimgv` built from master = 72.1 MB RSS, 73.6 MB peak, 6 threads** — i.e. only ~28 MB above a bare Qt window, with the whole image pipeline included.

## What the numbers say

1. **GTK is not lighter than Qt.** GTK4 sits *above* Qt Widgets at rest (61 vs 44 MB) and its dependency closure is 113 libraries versus Qt's 45. GTK3 is the lightest toolkit measured (34/40 MB) but is a dead end on its own trajectory, and swapping to it would still not beat "Qt plus a lean core" by the margin that matters.
2. **Qt Quick is 4× Qt Widgets** (183 vs 44 MB empty). "Keep Qt, drop Widgets for QML" does not pay.
3. **SDL3's 3.75 MB of mapped libraries is a mirage:** it measures 149 MB resident because it renders through software GL (llvmpipe) here. On a real GPU that number moves, but the *decision* does not, because SDL ships no widgets, no IME, no accessibility and no file dialogs — the 100-control settings dialog alone would be hand-built.
4. **The Qt Widgets `5k` figure is bimodal** (66 vs 76 MB across runs). It is the only stack whose number moves with run, which is itself a hint about lazy allocation in the grid — worth knowing when the slice work starts.

## Zig-native candidates

| Candidate | State | Verdict |
|---|---|---|
| `zigzag`, `zigtoolkit` | do not resolve — no repository found, no archive snapshot | cannot be audited; they do not exist as usable projects |
| `zt` (`JonSnowbd/ZT`, 2025-02-26) | `build.zig.zon:2:13: error: expected enum literal` on zig 0.17.0 | does not build on the installed toolchain |
| `capy` (0.4.1, 2025-12-25) | `build.zig.zon:9: error: invalid hash: incomplete` on 0.17.0; links **GTK4** on Linux (`build.zig:107`); `src/list.zig:39` builds every item eagerly | **disqualified twice**: its floor is GTK4's 61 MB, and it has no virtualised list, so 5 000 thumbnails would all exist |
| `dvui` (0.6.0-dev, 2026-11-06) | declares `minimum_zig_version = "0.17.0"`; SDL2/SDL3/raylib backend; has `native_dialogs.zig`, `SDL_EVENT_TEXT_EDITING` (IME), hi-DPI, AccessKit | the only live candidate; **build not confirmed** — it was still compiling when the research session ended |

## The feature bar

qimgv's current surface, which a replacement must not lose: one window; a 5 000-thumbnail grid that scrolls smoothly; an image viewport with pan/zoom/fit; menus and context menus; a settings dialog of **241 widgets, ~93 of them interactive**; drag-and-drop; hi-DPI; IME; native file dialogs; dark mode; accessibility.

Against that bar, only `dvui` remains in play, and it would mean hand-building the grid's virtualisation, the menu layer and the settings dialog.

## Verdict

**Under the map's rule (a change must win on time or memory), no toolkit replacement is defensible.** GTK4 costs more at rest than Qt Widgets; GTK3 wins on memory but loses on everything else; Qt Quick is 4× worse; SDL3 is worse than Qt *and* ships nothing; the Zig-native field offers one maybe (`dvui`) that needs a build check and would still require re-implementing the parts qimgv is actually made of.

The paying move is the one the map already assumes: **keep Qt as the shell, and make the hot core — decode, scale, thumbnail, cache — a Zig library behind a C ABI**, measured against the baseline in issue 6.

## Not measured

`dvui` buildability and RSS; any GPU-accelerated stack on real hardware (all numbers here are software rendering under Xvfb); accessibility cost in any candidate; the settings dialog re-implemented in `dvui` as a prototype.
