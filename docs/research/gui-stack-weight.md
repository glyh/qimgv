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

For reference, the real app, built from master and measured the same way (3 runs each, `qimgv` sampling harness at `/tmp/wf/guistack/qimgv-rss.sh`):

| `qimgv` state | RSS | peak | threads |
|---|---|---|---|
| idle, 2 s settle | **72.1 MB** | 73.6 MB | 6 |
| opened on a folder of **5 000 PNGs**, 4 s settle | **140.8 MB** | 148.0 MB | 14 |

The idle figure is only ~28 MB above a bare Qt window, with the whole image pipeline included. The 5 000-image figure is the one that matters for this question: the app doing its actual job costs **+69 MB over idle** and spawns 8 more threads (the thumbnail worker pool). `QListView` in icon mode is already virtualised and already does not materialise 5 000 delegates — so 140 MB is a *floor* for an equivalent app, not a ceiling.

## What the numbers say

1. **GTK is not lighter than Qt.** GTK4 sits *above* Qt Widgets at rest (61 vs 44 MB) and its dependency closure is 113 libraries versus Qt's 45. GTK3 is the lightest toolkit measured (34/40 MB) but is a dead end on its own trajectory, and swapping to it would still not beat "Qt plus a lean core" by the margin that matters.
2. **Qt Quick is 4× Qt Widgets** (183 vs 44 MB empty). "Keep Qt, drop Widgets for QML" does not pay.
3. **SDL3's 3.75 MB of mapped libraries is a mirage:** it measures 149 MB resident because it renders through software GL (llvmpipe) here. On a real GPU that number moves, but the *decision* does not, because SDL ships no widgets, no IME, no accessibility and no file dialogs — the 100-control settings dialog alone would be hand-built.
4. **The Qt Widgets `5k` figure is bimodal** (66 vs 76 MB across runs). It is the only stack whose number moves with run, which is itself a hint about lazy allocation in the grid — worth knowing when the slice work starts.
5. **Mapped bytes and RSS disagree in both directions**, which is why the earlier `ldd`-based table was not enough. SDL3 maps 3.75 MB and residents 149 MB; GTK4 maps 9.33 MB across 113 libraries and residents 61 MB. Anyone quoting "Qt is 9.86 MB" or "SDL is 3.75 MB" as a footprint is off by an order of magnitude.

## Zig-native candidates

| Candidate | State | Verdict |
|---|---|---|
| `zigzag`, `zigtoolkit` | do not resolve — no repository found, no archive snapshot | cannot be audited; they do not exist as usable projects |
| `zt` (`JonSnowbd/ZT`, 2025-02-26) | `build.zig.zon:2:13: error: expected enum literal` on zig 0.17.0 | does not build on the installed toolchain |
| `capy` (0.4.1, 2025-12-25) | `build.zig.zon:9: error: invalid hash: incomplete` on 0.17.0; links **GTK4** on Linux (`build.zig:107`); `src/list.zig:39` builds every item eagerly | **disqualified twice**: its floor is GTK4's 61 MB, and it has no virtualised list, so 5 000 thumbnails would all exist |
| `dvui` (0.6.0-dev, 2026-11-06) | declares `minimum_zig_version = "0.17.0"`; SDL2/SDL3/raylib backend; has `native_dialogs.zig`, `SDL_EVENT_TEXT_EDITING` (IME), hi-DPI, AccessKit | the only live candidate; **build not confirmed** — `zig build` on 0.17.0 got past manifest parsing (no version error, unlike `capy` and `zt`) and then died in dependency fetch: `invalid HTTP response: HttpConnectionClosing` on `sdl-1.0.12+3.4.18/build.zig.zon:32` (`libxkbcommon`) and `:146` (`fribidi`). That is a network flake, not a toolchain incompatibility, so the honest state is "unproven, not disqualified" — it needs a run with a warm package cache. |

## The feature bar

qimgv's current surface, which a replacement must not lose: one window; a 5 000-thumbnail grid that scrolls smoothly; an image viewport with pan/zoom/fit; menus and context menus; a settings dialog of **241 widgets, ~93 of them interactive**; drag-and-drop; hi-DPI; IME; native file dialogs; dark mode; accessibility.

Against that bar, only `dvui` remains in play. It would mean hand-building the grid's virtualisation (`ScrollContainerWidget` gives a virtual size but the app supplies the visible range itself — see `src/Examples/scrolling.zig`), the menu layer, and all ~93 controls of the settings dialog. The cost of that re-implementation is the real comparison, and it is not a memory comparison at all.

## Verdict

**Under the map's rule (a change must win on time or memory), no toolkit replacement is defensible.** The RSS data confirms, rather than merely leans toward, the `ldd` conclusion. GTK4 costs more at rest than Qt Widgets (61 vs 44 MB) while pulling 113 libraries; GTK3 is 10 MB lighter but is a dead end and buys nothing a Zig core would not; Qt Quick is 4× worse; SDL3 residents 3× *more* than Qt Widgets while shipping none of the widgets qimgv is made of. The Zig-native field offers one candidate still in play (`dvui`), disqualified neither by the toolchain nor by design, but it has no RSS number here and would put the grid's virtualisation, the menu layer and a 93-control settings dialog back on qimgv's own plate.

The decisive number is qimgv's own: **140.8 MB resident on a 5 000-image folder, on Qt Widgets, already virtualised**. Any replacement must beat that *and* reproduce today's feature set; nothing measured comes within 10 MB of the empty-window floor, let alone the working one. So the paying move is the one the map already assumes: **keep Qt as the shell, and make the hot core — decode, scale, thumbnail, cache — a Zig library behind a C ABI**, measured against the baseline in issue 6. A UI rewrite is not a memory or time win; it is a months-long feature regression with a memory bill attached.

The one thing that would reopen this: if software rendering under Xvfb is inflating Qt Quick and SDL3, a real-GPU measurement could move those two rows. It cannot move GTK4 (already above Qt at rest with no GL involved) and it cannot move `dvui`, which is an SDL-shaped stack and would land in the same place.

## Not measured

`dvui` buildability and RSS — the two `zig build` attempts died in dependency fetch (see above), so there is **no dvui RSS number in this document**. Also not measured: any GPU-accelerated stack on real hardware (every number here is software rendering under Xvfb, which is probably why Qt Quick and SDL3 look so heavy); accessibility cost in any candidate; a settings dialog re-implemented in `dvui`; and thumbnail-decode throughput, which lives in issue 6's baseline, not here.
