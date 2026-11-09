# Renderer frontier: what a QRhi-based Qt viewer does that `QGraphicsScene` cannot

Research ticket: *Renderer frontier: what the QRhi generation of Qt image viewers buys, and what survives into a Qt Widgets shell*. Feeds the map's fog line "Whether `QGraphicsView` (the memory hog, `gui/viewers/imageviewerv2.cpp`) is replaced inside Qt by a leaner renderer".

Read date: 2026-11. Sources pinned by HEAD sha at read time; every path below was read, not quoted from a README.

## Question

`QGraphicsScene` + `QGraphicsPixmapItem` is what this fork paints with, and #8/#11 measured what that costs. What does the generation of Qt viewers that does *not* paint through a scene actually do — and of that, which parts are adoptable inside a Qt Widgets shell without becoming a rewrite of `imageviewerv2.cpp`?

## Method

- Sources fetched as `codeload.github.com/<repo>/tar.gz` tarballs and read in place; GitHub REST only for metadata and sha pins.
- **Nothing was built or run.** No numbers below are mine; where a project reports its own number it is labelled as theirs.
- Four delegated survey subagents all died on a provider quota wall (`429 FreeUsageLimitError`), so everything here is one pass of direct reading. Depth is therefore uneven: rendering paths are read to the file and line, feature claims are not audited.

Pins (HEAD sha, tip date):

| repo | sha | tip |
|---|---|---|
| `hadoooooouken/Wynpix` (was `qimgv-plus`) | tag `1.3.5`, tree read 2026-11-08 | 2026-11-08 |
| `nomacs/nomacs` | `b67b4d785006` | 2026-11-06 |
| `KDE/gwenview` | `0f4d339577fe` | 2026-11-08 |
| `jurplel/qView` | `b8b993a5e043` | 2026-11-04 |
| `BLumia/pineapple-pictures` | `987bc76c537b` | 2026-11-04 |
| `lxqt/lximage-qt` | `afc8faf529b2` | 2026-11-06 |
| `dheerajshenoy/lektra` | `f4ba3a84d695` | 2026-11-07 |
| `luspi/photoqt` (partial mirror) | `0e9888a75a4b` | 2026-10-30 |
| `easymodo/qimgv` (this fork's base) | `3127a2d211b1` | 2026-01-19 |

## The landscape, by rendering path

| project | ★ | paint path | evidence |
|---|---|---|---|
| **Wynpix** | 10 | `QQuickRhiItem`, hand-written GLSL/HLSL-family shaders via QRhi | `src/gui/quick/render/imagerenderitem.h`, `src/res/shaders/rhi/{image,resample,convert,thumbnail,boxreduce,panorama}.{vert,frag}` |
| nomacs | 3 314 | `QGraphicsView` (`DkViewPort`) + `QtConcurrent` in 12 files | `ImageLounge/src/DkGui/DkViewPort.{h,cpp}` |
| qView | 3 726 | `QGraphicsView` (`QVGraphicsView`) | `src/qvgraphicsview.cpp:493` |
| pineapple-pictures | 561 | `QGraphicsView` (`GraphicsView`) + a second one for the navigator minimap | `app/graphicsview.{h,cpp}`, `app/navigatorview.{h,cpp}` |
| gwenview | 180 (mirror) | `QGraphicsView` + its own `RasterImageView`/`RasterImageItem` | `lib/documentview/rasterimageitem.cpp` |
| lximage-qt | 130 | `QGraphicsView` | `src/`, no renderer module |
| lektra | 345 | `QGraphicsView` + optional `QOpenGLWidget` viewport | `src/GraphicsView.cpp:1365` |
| PhotoQt | 96 (mirror) | Qt Quick scene graph (no custom RHI node found in the mirror) | `cplusplus/`, QML under `qml/` |

**Eight of nine paint through the same `QGraphicsScene` this fork uses.** The renderer frontier is one project, and it is a qimgv fork.

## Wynpix: what it actually changed

Wynpix is `qimgv` with the widget shell removed: `src/components/{loader,cache,thumbnailer,directorymanager,scriptmanager}` still sit where upstream put them (moved under `src/`), and the viewport became a Qt Quick item. Concretely, per `src/gui/quick/render/imagerenderitem.h`'s own header comment:

1. **One item, drawn through QRhi** — premultiplied alpha, **mipmaps**, nearest / bilinear / **trilinear** sampling, over a background colour and a checkerboard. Trilinear-from-mipmaps is the mechanism a `QGraphicsPixmapItem` cannot express: zoom-out stops shimmering without re-running a CPU scaler.
2. **`TileGrid` for images past the GPU texture limit** — split into tiles "instead of falling back to the CPU". This is the answer to >16k-pixel images that is *not* "downscale and lose the pixels".
3. **GPU filter set instead of one `QImage::scaled` filter**: MKS2021 (default), FidelityFX CAS, smart sharpen, bilinear, nearest (`README.md`; the CPU path for batch/resize is an **AVX2-optimised MKS2021**, `src/components/scalingfilter/`).
4. **HDR tone-mapping on the GPU** (BT.2408, Reinhard-Jodie, ACES Filmic, Hable) and **ICC source→display conversion** with a LUT built off-thread (`ColorLutBuilder`); "changing either only re-runs the renderer's conversion pass; the image is not decoded again".
5. **`GraphicsDeviceLossMonitor`** (`src/gui/quick/render/`) — a device-lost/reset path, which is the class of bug a naive `QOpenGLWidget` integration ships without.
6. **Offscreen render tests** — `tests/render/offscreenquick.{h,cpp}`, `tests/render/tst_imagerenderer.cpp`: the renderer is testable headless, which is the thing this fork has no test for at all (map fog: "`qimgv/tests/` is never added to the build").

Its `src/components/` also carries the pieces upstream qimgv lacks and that #38 and the loader decisions want:

- `navigationthrottle/` — defers a step that follows the previous one by less than ~66 ms and emits `settled()` after quiet, so a held arrow key costs one decode instead of N.
- `navigationpreview/` — shows the uncropped thumbnail of the file being stepped to while the real load is deferred, one request in flight.
- `imagepreparer/` — decodes off the GUI thread *for CPU actions* (copy/save/print/edit) and builds the SDR copy of an HDR image, so an action never forces a full decode on the GUI thread.

## What this does and does not buy against this map's numbers

This is the part that decides whether the fog line becomes a slice.

- **It does not move W3's peak RSS.** #11 measured W3 at 884 ms with **85 % in libjpeg** and a **293 MB progressive-JPEG coefficient buffer** that no renderer can remove; #28 measured both qimgv and a no-toolkit viewer at ~478 MB on the same file. A GPU renderer *adds* VRAM on top of the retained `QImage`. Tile-splitting avoids a texture-size limit; it does not make the decoded bitmap smaller.
- **It does not move W1/W4 either.** Those are decoder- and directory-model-bound (#8: 120/260 ms, 1–2 ms per step).
- **What it does move is the class of thing #6 did not put a number on**: frame pacing during a zoom/drag (W2, currently unmeasurable in-app because `QGraphicsView` blits), and scaling *quality* at zoom levels between the fit pixmap and 1:1. Wynpix's `pixmapItem`/`pixmapItemScaled` equivalent is gone: one item, mip-sampled.
- **Note what this fork already has.** `imageviewerv2.h:134` holds **two** items, `pixmapItem` and `pixmapItemScaled`, and `setScaledPixmap()` (`:370`) swaps to the scaled one when the viewport-sized rescale arrives from `Scaler`. So the "two-level bitmap" idea is not missing; the missing part is that the *source* of the scaled copy is always a full-resolution decode, and the rescale is CPU work on every zoom step.

## Adoptability inside a Qt Widgets shell

The fork's decided floor is **Qt 6.8 LTS** (#17), and the local toolchain is Qt 6.12.0. Checked on this box:

```
/usr/include/qt6/QtWidgets/qrhiwidget.h      ← QRhiWidget, Qt Widgets
/usr/include/qt6/QtQuick/qquickrhiitem.h     ← QQuickRhiItem, Qt Quick
/usr/include/qt6/QtGui/6.12.0/QtGui/rhi/qrhi.h
```

So a **`QRhiWidget`** is available without taking Qt Quick (both landed in Qt 6.7). That is the shape that fits this map: replace the `QGraphicsScene` viewport with one `QRhiWidget`, keep the widget shell and every dialog, and implement only what Wynpix's `imagerenderitem` does that is needed — textured quad, mipmap sampling, tiled upload for oversized images. Wynpix's shaders are directly readable as the spec for that.

Cost ordering if this ever becomes a slice:

1. **Mipmap trilinear sampling only** — smallest useful change: kills zoom-out shimmer and the per-step CPU rescale, needs ~one draw call and one samplers/pipeline object. Does not need the GPU filter set, ICC or HDR.
2. **Tile upload** — the answer to >GPU-limit images, but it only pays if such images are in the corpus (#13's W3 is 8736×11648, which is *under* a 16384 texture limit, so W3 would not exercise it).
3. **GPU scaler filters (MKS2021/CAS)** — replaces the OpenCV/`QImage::scaled` path; overlaps ticket *Drop the OpenCV scaler* directly.
4. **ICC + HDR** — orthogonal feature work, and gwenview (`lib/cms`) and Wynpix are both readable references.

## Findings for the map

1. **The renderer is not where this map's numbers live.** Everything measured so far (#8, #11, #28) is decoder- and directory-model-bound; a renderer swap is a *quality and frame-pacing* slice, not a time-to-first-image or RSS slice. The fog line is now specifiable, and the specifiable answer is: **not on the critical path**.
2. **If it is done anyway, the cheapest paying step is mipmap sampling, and `QRhiWidget` is the right container** — it keeps the widget shell, and Qt 6.8 makes it available under the floor already decided.
3. **The highest-value thing to take from Wynpix is not the renderer.** It is three `src/components/` modules this fork has no equivalent of: `navigationthrottle`, `navigationpreview`, `imagepreparer`. All three are plain `QObject`s, none need QRhi, and all three sit on decisions already open — *Decode at display resolution*, *cancellation across the C ABI*, *which slice goes first*.
4. **Wynpix is not in the fork census.** [Upstream forks: what the 41 forks with their own commits already contain](https://github.com/glyh/iv/issues/27) enumerates `GET /repos/easymodo/qimgv/forks`; Wynpix is not a GitHub fork (it is a re-uploaded derivative with GPLv3 and the same tree), so that method structurally cannot see it. The census's largest *rewrite* by far was measured at +834 commits; this one is not in the table at all.

## Not verified

- Whether Wynpix's shader pipeline is actually faster, or correct on fractional DPI — no build, and it is Windows-only (`README.md` badges: Direct3D 11/12, Vulkan).
- Wynpix's claim of GPU-accelerated "MKS2021" (a sharpening upscale kernel) on a *downscale* path was not reasoned through: MKS2021 is a Magic-Kernel-Sharp *resample*, and whether it is the right filter for minification at arbitrary ratios is a question for whoever writes the shader.
- `luspi/photoqt` is a partial mirror (76 `.cpp` at read time vs a full project); its Qt Quick scene-graph claim rests on absence of a custom RHI node in what the mirror carries.
- gwenview's `RasterImageView` and nomacs' `DkViewPort` internals were not read past the class boundaries.
- No frame-pacing measurement exists for any of these, including the fork's own W2.
