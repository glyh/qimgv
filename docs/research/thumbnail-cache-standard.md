# Thumbnail cache: the freedesktop standard versus this fork's private PNG directory

Research ticket: *Thumbnail cache: freedesktop Thumbnail Managing Standard versus a private PNG directory*. Sits under the map's `thumbnail` and `cache` subsystems, and against the fog line "Cache eviction and the directory model are suspected of memory growth".

Read date: 2026-11. Paths read, not quoted from READMEs; nothing built or run.

## Question

The map's destination rebuilds `thumbnail` and `cache`. What storage contract should the rebuilt one have — and how much of it is already decided for us by a standard that three other Qt viewers implement and this fork does not?

## What this fork does today

Two files, whole mechanism:

- `components/cache/thumbnailcache.cpp:4` — `cacheDirPath = settings->thumbnailCacheDir();` and `:8` — `thumbnailPath(id) = cacheDirPath + id + ".png"`. A flat directory of PNGs named by an opaque id.
- `components/cache/thumbnailcache.h:30` — one `QMutex`, with the comment "we are still bottlenecked by disk access anyway".
- `components/thumbnailer/thumbnailerrunnable.cpp:103` and `:186` — the thumbnails themselves are done *right*: `QImageReader::setScaledSize()` before `read()`, "resize during read via QImageReader (faster)", with a `manualResize` fallback when the handler does not `supportsOption(Size)`.

So the generation side is already the good path. What is missing is everything around it:

- **No freshness check.** The id is opaque; nothing records the source file's mtime, so a replaced-at-same-name file either serves a stale thumbnail or is only fixed by clearing the cache.
- **No size classes.** One file per image, so the folder grid, the thumbnail strip and any future larger preview either share one resolution or fight over the same path.
- **No eviction.** Nothing in the file removes anything; growth is bounded only by the user finding the setting. (This is the unproven half of the map's fog line: growth is real by construction, its *rate* is still unmeasured.)

## The standard

The **freedesktop Thumbnail Managing Standard** fixes exactly those three things:

- Cache at `$XDG_CACHE_HOME/thumbnails/<size-class>/`, where the classes are `normal` (128), `large` (256), `x-large` (512), `xx-large` (1024).
- File name = **MD5 of the source file's `file://` URI** plus `.png` — so two applications, and the desktop's own file manager, hit the same file.
- The PNG carries **`Thumb::URI`** and **`Thumb::MTime`** as PNG text chunks; a reader regenerates when `MTime` no longer matches, and `Thumb::Size`, `Thumb::Mimetype`, `Thumb::Image::Width`/`Height` are optional extras.
- A thumbnail in a *larger* class may be downscaled to satisfy a smaller request, and the smaller result may be written back.

The payoff is not elegance: it is that **Nautilus/Dolphin/Thunar and the viewer stop decoding the same JPEG twice**, and the cache becomes the OS's to reap.

## Three independent implementations

All three were read; each follows the standard, and each contributes one idea worth having.

**nomacs** — `ImageLounge/src/DkCore/DkCachedThumb.{h,cpp}`, `DkThumbs.{h,cpp}`. The header of `DkCachedThumb` states the design outright: reentrant ("we can construct and load/save thumbs from any thread"), `cleanupAsync()`/`cleanupSync(deleteAll)` for background reaping, and `load()` documented as "the returned image could be larger than needed, but never smaller (to reduce blur)". `:250-310` is the read path: find the cached file, verify freshness, and **if the cached thumb is larger than needed, downscale it and save the smaller one back** (`:308-309`). `:320-333` disables the cache for the rest of the session on a filesystem error rather than retrying per image.

**gwenview** — `lib/thumbnailprovider/thumbnailprovider.cpp`, `thumbnailgenerator.cpp`. Writes the full chunk set (`Thumb::URI`, `Thumb::MTime`, `Thumb::Size`, `Thumb::Mimetype`, `Thumb::Image::Width`, `Thumb::Image::Height`, `Software`) at `thumbnailgenerator.cpp:319-326`; maps its own size enum onto `normal/`, `large/`, `x-large/`, `xx-large/` at `thumbnailprovider.cpp:114-123`; and at `:414-422` does the larger-class-to-smaller-class reuse ("If there is a large-sized thumbnail, generate the small-sized version from it") *copying the text keys across* so the derived file stays valid.

**PhotoQt** — `cplusplus/images/provider/pqc_providerthumb.cpp:177` has an explicit "If files in XDG_CACHE_HOME/thumbnails/ shall be used, then do use them" branch, then writes `Thumb::URI`/`Thumb::MTime`/`Thumb::Mimetype`/`Thumb::Size` at `:264-270`.

**qimgv, and therefore this fork, is the outlier** — and so is qView, pineapple-pictures and lximage-qt, none of which carry an XDG thumbnail path at all.

## What conforming costs

Small, and it is mostly a naming and a metadata change, not an architecture change:

- Replace the opaque `id` with `md5("file://" + canonical path)` and the single flat dir with `<size-class>/` (`thumbnailcache.cpp:8`, one line, plus the class on the path).
- Add `QImage::setText("Thumb::URI"/"Thumb::MTime", ...)` before the PNG write, and a freshness comparison in `readThumbnail` — the only new logic, ~15 lines.
- Keep nomacs' two cheap ideas: *serve a larger class and downscale* (removes a full decode when the user switches views), and *disable the cache for the session on IO error* (removes a per-image retry storm).
- Eviction: hand it to the desktop by using the standard directory, or copy nomacs' `cleanupAsync()`.

## Findings for the map

1. **The cache contract is already written by someone else.** A rebuilt `thumbnail`/`cache` should target the freedesktop layout, not invent one — it is the only choice that makes the fork's cache shared with the desktop and reapable by it. Three Qt viewers implement it; four do not; there is no competing convention in the sample.
2. **This changes nothing about decode cost or RSS**, so it is not on the time-to-first-image critical path either. It is a correctness-and-growth fix: no staleness bug, bounded on disk, and no duplicate work against the file manager.
3. **The `thumbnail` slice should own freshness and classes; the `cache` slice should own eviction.** They are currently one flat directory with neither.
4. **The map's fog line stays half-open.** Growth of this cache is now explicable by construction (no eviction) but its *rate* is still unmeasured, and the standard's sharing means the eventual number is not the fork's alone.

## Not verified

- No measurement of the fork's current cache growth rate, file count, or hit rate — this is a code-reading finding only.
- Whether Qt's PNG handler round-trips arbitrary `tEXt` keys through `QImage::text()` was not tested on 6.12; gwenview and nomacs both do it, so the assumption is well-attested rather than checked here.
- The standard's own current revision was not read from spec text; the layout above is as the three implementations encode it, which is consistent across all three.
- Whether the md5-of-URI naming collides for the same file reached through a symlink or a different mount path — nomacs has a comment at `DkCachedThumb.cpp:219` that "If URIs don't match, the cache doesn't work between programs", which is the same question from the other side.
