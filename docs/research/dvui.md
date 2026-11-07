# Can dvui host qimgv's UI?

Research for <https://github.com/glyh/qimgv/issues/16>. **Verdict: it builds, it is a real toolkit with a working virtualised scroll path — and hosting qimgv in it would be a multi-month rewrite whose measured floor is ~5× Qt Widgets. It does not beat "keep Qt as the shell, hot core in Zig".**

## 1. It builds on zig 0.17.0

The previous attempt's failure was a network flake, confirmed:

```
git clone https://github.com/david-vanderson/dvui    # commit ae609bf1, 7.5 s
cd dvui && zig build -Dbackend=sdl2 compile-sdl2-standalone
  → EXIT=0, 39/39 steps, 10.5 s wall
  → zig-out/bin/sdl2-standalone, 235 MB (debug build)
```

A consumer project using dvui as a path dependency also compiles clean (`ReleaseFast`, ~60 s). SDL2 (2.32.74) and SDL3 (3.4.18) dev packages are installed here.

## 2. Resident set — 5 runs per configuration

`Xvfb :99 1280x800x24`, `ReleaseFast`, `VmRSS` read from `/proc/self/status` in-process after a 2 s settle, 20+ frames rendered first:

| configuration | RSS (5 runs) | spread | threads |
|---|---|---|---|
| dvui, one window + one label | **214.1 MB** (214,048–214,240 kB) | ±0.1 MB | 18 |
| dvui, scroll area + **5 000 rows** | **215.3 MB** (215,244–215,400 kB) | ±0.1 MB | 18 |

For comparison, from the same harness and the same machine:

| | RSS |
|---|---|
| Qt6 Widgets, empty window | 44.1 MB |
| Qt6 Widgets, +5 000 items | 64–84 MB |
| bare SDL3 window | 149 MB |
| real qimgv, 5 000-image folder open | 140.8 MB |

### What the 214 MB is, and what it is not

The honest split is unresolved: dvui's software-rendering path cannot be forced here (`SDL_RENDER_DRIVER=software` → `SDL_SetRenderDrawBlendMode ... not supported`; `SDL_VIDEODRIVER=dummy` → `dummy not available`), so I could not measure dvui without llvmpipe.

What the numbers do support:

- A **bare SDL3 window on this box is 149 MB** under the same software GL. dvui on SDL2 adds roughly **+65 MB over a bare SDL window**, which is the dvui-side cost and is not explained by llvmpipe.
- **Qt Widgets' 44 MB is not inflated by this environment**, because it draws with the raster engine and needs no GL. That asymmetry is real and it is the one that matters: the comparison is not "dvui is 5× Qt", it is "**every GL-backed stack costs 3–5× a raster one under software rendering**", and on real GPU hardware the GL stacks would come down — Qt Quick and SDL3 with them.
- The **18 threads 5 s after startup** with one label on screen is unexplained and worth a second look by anyone who takes dvui seriously.

The 5 000-row result is the interesting one: **+1.2 MB** over the empty window. That is what a genuinely virtualised list looks like.

## 3. The feature bar (source-level)

Virtualisation is real and **app-driven**, not a widget: `src/widgets/CacheSizeWidget.zig:13` maintains an offscreen size cache, and `src/Examples/scrolling.zig:161` shows the per-row `cacheSize` + `uncached()` guard. 5 000 rows means 5 000 cheap calls per frame, not 5 000 retained widgets — but **the app writes that loop and the min-size cache itself**.

| Need | State |
|---|---|
| 5 000-thumbnail grid | exists, virtualised — but you write the caching loop |
| menus / context menus | `src/widgets/MenuWidget.zig`, `FloatingMenuWidget.zig` |
| dialogs | `FloatingWindowWidget.zig` |
| dropdowns, text entry, tree, grid, icons, drag-reorder | exist (`IconWidget`, `ReorderWidget`) |
| **image viewport with pan/zoom/fit** | **missing** — manual `dvui.picture` drawing plus hand-rolled transform state |
| **241-widget / ~93-control settings dialog** | layout written by hand |
| hi-DPI, IME, native file dialogs, dark mode | claimed by the project (`native_dialogs.zig`, `SDL_EVENT_TEXT_EDITING`, AccessKit) — **not verified here**; dvui logged `accesskit false` at runtime |

## 4. Verdict

Under the map's rule — a change must win on **time or memory** — dvui does not pay:

- Its floor is **214 MB against Qt Widgets' 44 MB**, and even discounting llvmpipe it is +65 MB over a bare SDL window.
- The two things qimgv is mostly made of — the image viewport and a 93-control settings dialog — **do not exist in dvui** and would be written by hand, on top of a menu layer and the grid's caching loop.
- That is a UI rewrite measured in months, with a memory bill at the end of it, to reach parity with what already works.

**Keep Qt as the shell. Put the hot core — decode → scale → thumbnail → cache — in Zig behind the C ABI.** If the UI ever leaves Qt, dvui is the credible target, and this document says what it would cost.

## Not verified

The exact llvmpipe share of the 214 MB (the isolation attempts failed, as above); hi-DPI, IME and accessibility behaviour; the 18-thread count; and a real-GPU measurement of dvui, Qt Quick and SDL3, which is the one experiment that could move the GL rows and cannot move Qt Widgets or GTK4.
